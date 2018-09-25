- module(couch_replicator_watchdog).
- author('Oleksandr Karaberov').
- description('Inspects and restarts stuck replication jobs').
- vsn(5).
- export([
    start_link/0
]).
- export([
   init/1,
   terminate/2,
   handle_info/2,
   handle_call/3,
   code_change/3,
   handle_cast/2
]).
- behavior(gen_server).


-record(unhealthy_repl, {
    pid = null :: pid() | atom(),
    pending_changes = 0 :: non_neg_integer(),
    doc_id = <<>> :: binary(),
    source = <<>> :: binary(),
    generation = 0 :: non_neg_integer()
}).

-type urepl() :: #unhealthy_repl{}.

-record(watchdog_state, {
    sweep_cycle = 0 :: non_neg_integer(),
    stuck_repls = [] :: [urepl()],
    round = 0 :: non_neg_integer()
}).

-type watchdog_state() :: #watchdog_state{}.

-define(RECORD_INFO(T,R),
    lists:zip(record_info(fields, T), tl(tuple_to_list(R)))).


start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [],  []).


init([])->
    timer:send_interval(round_interval(), health_check),
    {ok, #watchdog_state{}}.


handle_cast({cluster, unstable}, State) ->
    {noreply, State};


handle_cast({cluster, stable}, State) ->
    {noreply, State};


handle_cast(Msg, State) ->
    {stop, {error, unexpected_message, Msg}, State}.


handle_call({updated, _Id, _Rep, _Filter}, _From, State) ->
    {reply, ok, State}.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


handle_info(health_check, #watchdog_state{}=State)->
    Enabled = max_rounds() < kill_threshold(),
    DocState = if Enabled ->
        run_health_check(State);
    true ->
        #watchdog_state{}
    end,
    {noreply, DocState}.


terminate(_Reason, _State) ->
    ok.


-spec run_health_check(watchdog_state()) -> watchdog_state().
run_health_check(#watchdog_state{round=CurrentRound,sweep_cycle=SweepCycle}=State) ->
  MaxRounds = max_rounds(),
  Info = case ignore_infra() of
      true -> "[round: ~p] [max_rounds: ~p] [sweep_cycle: ~p] [round_interval: ~p] [ignore euinfra]";
      false -> "[round: ~p] [max_rounds: ~p] [sweep_cycle: ~p] [round_interval: ~p]"
  end,
  couch_log:warning("couch_replicator_watchdog: heartbeat " ++ Info,
                    [CurrentRound, MaxRounds, SweepCycle, round_interval()]),
  case CurrentRound of
      Value when Value < MaxRounds ->
          update_stuck_repls_queue(State);
      Value when Value =:= MaxRounds ->
          reload_stuck_repls(get_stuck_repls_pids(State#watchdog_state.stuck_repls)),
          State#watchdog_state{round=0, sweep_cycle=SweepCycle + 1, stuck_repls=[]};
      _Else ->
          State
  end.


-spec update_stuck_repls_queue(watchdog_state()) -> watchdog_state().
update_stuck_repls_queue(#watchdog_state{round=Round, stuck_repls=StRepls}=State) ->
  Tasks = couch_task_status:all(),
  PendingRepls = detect_pending_repls(Tasks),
  case StRepls of
      [] ->
          State#watchdog_state{stuck_repls=PendingRepls, round=Round + 1};
      StuckRepls when is_list(StuckRepls) ->
          StuckRepls1 = lists:map(fun(#unhealthy_repl{generation=Generation}=Rpl) ->
              Rpl#unhealthy_repl{generation=Generation + 1} end,
          [R || R <- StuckRepls,
                  case lists:keyfind(R#unhealthy_repl.pid, #unhealthy_repl.pid, PendingRepls) of
                      #unhealthy_repl{pending_changes=PChanges} ->
                          if PChanges < R#unhealthy_repl.pending_changes -> false;
                          true -> true end;
                      false -> false
                  end
          ]),
          UnhealthyRepls = lists:append(StuckRepls1,
              [URepl || URepl <- PendingRepls,
              not lists:keymember(URepl#unhealthy_repl.pid, #unhealthy_repl.pid, StuckRepls1)]),
          couch_log:warning("couch_replicator_watchdog: ~p replication(s) considered unhealthy ~p",
                            [length(UnhealthyRepls), pretty_print_records(UnhealthyRepls)]),
          State#watchdog_state{stuck_repls=UnhealthyRepls, round=Round + 1};
      _Else ->
          State#watchdog_state{round=Round + 1}
  end.


-spec detect_pending_repls([any()] | []) -> [urepl()].
detect_pending_repls(Tasks) ->
  lists:map(fun(ReplTask) ->
      #unhealthy_repl{pid = pidify(couch_util:get_value(pid, ReplTask)),
                      pending_changes = couch_util:get_value(changes_pending, ReplTask, 0),
                      doc_id = couch_util:get_value(doc_id, ReplTask, <<>>),
                      source = couch_util:get_value(source, ReplTask, <<>>)}
      end, lists:filter(fun(Task) ->
              SkipInfraRepls = maybe_ignore_infra_repls(Task),
              case lists:keyfind(changes_pending, 1, Task) of
                  {changes_pending, Pending} when is_number(Pending),
                                             Pending > 0,
                                             not SkipInfraRepls -> true;
                  _Else -> false
              end
  end, Tasks)).


-spec maybe_ignore_infra_repls([any()]) -> boolean().
maybe_ignore_infra_repls(Task) ->
  IgnoreInfra = ignore_infra(),
  if IgnoreInfra  ->
    case lists:keyfind(doc_id, 1, Task) of
        {doc_id, DocId} ->
            case string:str(binary_to_list(DocId), "euinfra") of
                Ind when Ind =/= 0 -> true;
                _Ind -> false
            end;
        _Else -> false
    end;
  true -> false end.


-spec get_stuck_repls_pids([urepl()]) -> [pid()] | [].
get_stuck_repls_pids(Repls) ->
  case Repls of
      StuckRepls when is_list(StuckRepls) ->
          lists:map(fun(#unhealthy_repl{pid=Pid}) -> Pid end,
              [Repl || Repl <- Repls, Repl#unhealthy_repl.generation =:= max_rounds() - 1]);
      _Else -> []
  end.


-spec reload_stuck_repls([pid()] | []) -> ok.
reload_stuck_repls([]) ->
  ok;
reload_stuck_repls(Pids) ->
  couch_log:warning("couch_replicator_watchdog: ~p replication(s) got stuck and will be restarted: ~p",
                    [length(Pids), Pids]),
  lists:foreach(fun(P) ->
      P ! couch_replicator_watchdog_wake,
      timer:sleep(restart_jitter()) end, Pids),
  ok.


-spec pidify(any()) -> pid().
pidify(Pid) ->
  case Pid of
      P when is_list(P) ->
          list_to_pid(P);
      P when is_binary(P) ->
          list_to_pid(binary_to_list(P));
      P when is_pid(P) ->
          P;
      _Else ->
          null
  end.


-spec pretty_print_records([urepl()]) -> [any()].
pretty_print_records(Records) ->
    lists:map(fun(R) -> ?RECORD_INFO(unhealthy_repl, R) end, Records).


-spec restart_jitter() -> non_neg_integer().
restart_jitter() -> 500.


-spec kill_threshold() -> non_neg_integer().
kill_threshold() -> 999999.


-spec ignore_infra() -> boolean().
ignore_infra() ->
  config:get_boolean("replicator_watchdog", "ignore_infra_repls", false).


-spec round_interval() -> non_neg_integer().
round_interval() ->
    config:get_integer("replicator_watchdog", "round_interval", 60000).


-spec max_rounds() -> non_neg_integer().
max_rounds() ->
    config:get_integer("replicator_watchdog", "max_rounds", 5).
