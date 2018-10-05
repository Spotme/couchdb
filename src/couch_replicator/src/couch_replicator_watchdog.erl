- module(couch_replicator_watchdog).
- author('Oleksandr Karaberov').
- description('Inspects and restarts stuck replication jobs').
- vsn(8).
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
    job_id = <<>> :: binary(),
    pending_changes = 0 :: non_neg_integer(),
    doc_id = <<>> :: binary(),
    docs_written = 0 :: non_neg_integer(),
    doc_write_failures = 0 :: non_neg_integer(),
    docs_read = 0 :: non_neg_integer(),
    generation = 0 :: non_neg_integer()
}).

-type urepl() :: #unhealthy_repl{}.

-record(watchdog_state, {
    sweep_cycle = 0 :: non_neg_integer(),
    stuck_repls = [] :: [urepl()],
    round = 0 :: non_neg_integer(),
    timer = null :: reference() | null,
    interval = 0 :: non_neg_integer()
}).

-type watchdog_state() :: #watchdog_state{}.

-define(RECORD_INFO(T,R),
    lists:zip(record_info(fields, T), tl(tuple_to_list(R)))).


start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [],  []).


init([])->
    Interval = round_interval(),
    TimerRef = erlang:send_after(Interval, self(), health_check),
    {ok, #watchdog_state{timer = TimerRef, interval = Interval}}.


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
    erlang:cancel_timer(State#watchdog_state.timer),
    Interval = round_interval(),
    TimerRef = erlang:send_after(Interval, self(), health_check),
    Enabled = max_rounds() < kill_threshold(),
    State1 = if Enabled ->
        run_health_check(State#watchdog_state{interval = Interval, timer = TimerRef});
    true ->
        #watchdog_state{interval = Interval, timer = TimerRef}
    end,
    {noreply, State1}.


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
      reload_stuck_repls(get_stuck_repls_ids(UpdState#watchdog_state.stuck_repls)),
      State#watchdog_state{round=0, sweep_cycle=SweepCycle + 1, stuck_repls=[]};
  true -> UpdState#watchdog_state{round = CurrentRound + 1} end.


-spec update_stuck_repls(watchdog_state()) -> watchdog_state().
update_stuck_repls(#watchdog_state{stuck_repls=StRepls}=State) ->
  ReplTasks = [TaskProps || {_, TaskProps} <- ets:tab2list(couch_task_status),
      couch_util:get_value(type, TaskProps) =:= replication
  ],
  PendingRepls = detect_pending_repls(ReplTasks),
  case StRepls of
      [] ->
          State#watchdog_state{stuck_repls=PendingRepls};
      StuckRepls when is_list(StuckRepls) ->
          StuckRepls1 = lists:map(fun(#unhealthy_repl{generation=Generation}=Rpl) ->
              Rpl#unhealthy_repl{generation=Generation + 1} end,
          [R || R <- StuckRepls,
                  case lists:keyfind(R#unhealthy_repl.job_id, #unhealthy_repl.job_id, PendingRepls) of
                      #unhealthy_repl{pending_changes=PChanges,
                                      docs_written= DocsWritten,
                                      docs_read=DocsRead,
                                      doc_write_failures=DocsFailures} ->
                          if PChanges >= R#unhealthy_repl.pending_changes,
                             DocsWritten =:= R#unhealthy_repl.docs_written,
                             DocsRead =:= R#unhealthy_repl.docs_read,
                             DocsFailures =:= R#unhealthy_repl.doc_write_failures -> true;
                          true -> false end;
                      false -> false
                  end
          ]),
          UnhealthyRepls = lists:append(StuckRepls1,
              [URepl || URepl <- PendingRepls,
              not lists:keymember(URepl#unhealthy_repl.job_id, #unhealthy_repl.job_id, StuckRepls1)]),
          couch_log:warning("couch_replicator_watchdog: ~p replication(s) considered unhealthy ~p",
                            [length(UnhealthyRepls), pretty_print_records(UnhealthyRepls)]),
          State#watchdog_state{stuck_repls=UnhealthyRepls}
  end.


-spec detect_pending_repls([any()] | []) -> [urepl()].
detect_pending_repls(Tasks) ->
  lists:map(fun(ReplTask) ->
      #unhealthy_repl{job_id = couch_util:get_value(replication_id, ReplTask, <<>>),
                      pending_changes = couch_util:get_value(changes_pending, ReplTask, 0),
                      doc_id = couch_util:get_value(doc_id, ReplTask, <<>>),
                      doc_write_failures = couch_util:get_value(doc_write_failures, ReplTask, 0),
                      docs_read = couch_util:get_value(docs_read, ReplTask, 0),
                      docs_written = couch_util:get_value(docs_written, ReplTask, 0)}
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


-spec get_stuck_repls_ids([urepl()]) -> [binary()] | [].
get_stuck_repls_ids(Repls) ->
  case Repls of
      StuckRepls when is_list(StuckRepls) ->
          lists:map(fun(#unhealthy_repl{job_id=JobId}) -> JobId end,
              [Repl || Repl <- Repls, Repl#unhealthy_repl.generation =:= max_rounds()]);
      _Else -> []
  end.


-spec reload_stuck_repls([binary()] | []) -> ok.
reload_stuck_repls([]) ->
  ok;
reload_stuck_repls(JobIds) ->
  couch_log:warning("couch_replicator_watchdog: ~p replication(s) got stuck and will be restarted: ~p",
                    [length(JobIds), JobIds]),
  lists:foreach(fun(JobId) -> couch_replicator:restart_job(JobId) end, JobIds),
  ok.


-spec pretty_print_records([urepl()]) -> [any()].
pretty_print_records(Records) ->
    lists:map(fun(R) -> ?RECORD_INFO(unhealthy_repl, R) end, Records).


-spec kill_threshold() -> non_neg_integer().
kill_threshold() -> 999999.


-spec round_interval() -> non_neg_integer().
round_interval() ->
    config:get_integer("replicator_watchdog", "round_interval", 60000).


-spec max_rounds() -> non_neg_integer().
max_rounds() ->
    config:get_integer("replicator_watchdog", "max_rounds", 3).
