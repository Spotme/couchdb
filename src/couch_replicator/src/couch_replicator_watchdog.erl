- module(couch_replicator_watchdog).
- author('Oleksandr Karaberov').
- description('Inspects and restarts stuck replication jobs').
- vsn(7).
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
    pid = null :: pid() | null,
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
  InfoMsg = "[round: ~p] [max_rounds: ~p] [sweep_cycle: ~p] [round_interval: ~p]",
  couch_log:warning("couch_replicator_watchdog: heartbeat " ++ InfoMsg,
                    [CurrentRound, MaxRounds, SweepCycle, round_interval()]),
  UpdState = update_stuck_repls(State),
  if CurrentRound =:= MaxRounds ->
      reload_stuck_repls(get_stuck_repls_pids(UpdState#watchdog_state.stuck_repls)),
      State#watchdog_state{round=0, sweep_cycle=SweepCycle + 1, stuck_repls=[]};
  true -> UpdState#watchdog_state{round = CurrentRound + 1} end.


-spec update_stuck_repls(watchdog_state()) -> watchdog_state().
update_stuck_repls(#watchdog_state{stuck_repls=StRepls}=State) ->
  Tasks = couch_task_status:all(),
  PendingRepls = detect_pending_repls(Tasks),
  case StRepls of
      [] ->
          State#watchdog_state{stuck_repls=PendingRepls};
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
          State#watchdog_state{stuck_repls=UnhealthyRepls}
  end.


-spec detect_pending_repls([any()] | []) -> [urepl()].
detect_pending_repls(Tasks) ->
  lists:map(fun(ReplTask) ->
      #unhealthy_repl{pid = pidify(couch_util:get_value(pid, ReplTask)),
                      pending_changes = couch_util:get_value(changes_pending, ReplTask, 0),
                      doc_id = couch_util:get_value(doc_id, ReplTask, <<>>),
                      source = couch_util:get_value(source, ReplTask, <<>>)}
      end, lists:filter(fun(Task) ->
              IsRcouch = is_source_rcouch(Task),
              if IsRcouch ->
                  is_rcouch_repl_pending(Task);
              true ->
                  case lists:keyfind(changes_pending, 1, Task) of
                      {changes_pending, Pending} when is_number(Pending), Pending > 0 ->
                          true;
                      _Else ->
                          false
                  end
              end
  end, Tasks)).


-spec is_rcouch_repl_pending(any()) -> boolean().
is_rcouch_repl_pending(Task) ->
  CurSeq = couch_util:get_value(checkpointed_source_seq, Task, 0),
  SourceSeq = couch_util:get_value(source_seq, Task, 0),
  ThroughSeq = couch_util:get_value(through_seq, Task, 0),
  PendingChanges = couch_util:get_value(changes_pending, Task, 0),
  % Task stats reporting seems to be broken for CouchDB2 <--> Couch1.3 (rcouch)
  % replications https://github.com/apache/couchdb/issues/976#issuecomment-344310226
  % therefore another more versbose method is required to check for pending changes
  if ThroughSeq =/= 0, SourceSeq =/= 0, PendingChanges =/= 0, PendingChanges =/= CurSeq,
  PendingChanges =/= SourceSeq, PendingChanges =/= ThroughSeq -> true;
  true -> false end.


-spec is_source_rcouch(any()) -> boolean().
is_source_rcouch(Task) ->
  case couch_util:get_value(checkpointed_source_seq, Task, 0) of
      CurSorceSeq when is_number(CurSorceSeq), CurSorceSeq =/= 0 ->
          true;
      CurSorceSeq when is_binary(CurSorceSeq) ->
          case string:str(binary_to_list(CurSorceSeq), "-") of
              Ind when Ind =/= 0 -> false;
              _Ind -> true
          end;
      _Else ->
          false
  end.


-spec get_stuck_repls_pids([urepl()]) -> [pid()] | [].
get_stuck_repls_pids(Repls) ->
  case Repls of
      StuckRepls when is_list(StuckRepls) ->
          lists:map(fun(#unhealthy_repl{pid=Pid}) -> Pid end,
              [Repl || Repl <- Repls, Repl#unhealthy_repl.generation =:= max_rounds()]);
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


-spec round_interval() -> non_neg_integer().
round_interval() ->
    config:get_integer("replicator_watchdog", "round_interval", 60000).


-spec max_rounds() -> non_neg_integer().
max_rounds() ->
    config:get_integer("replicator_watchdog", "max_rounds", 5).
