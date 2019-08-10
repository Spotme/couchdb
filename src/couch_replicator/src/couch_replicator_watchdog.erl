- module(couch_replicator_watchdog).
- author('Oleksandr Karaberov').
- description('Inspects and restarts stuck replication jobs').
- vsn(10).

- export([
   init/1,
   start_link/0,
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
    crashed_repls = [] :: [binary()],
    round = 0 :: non_neg_integer(),
    timer = null :: reference() | null,
    interval = 0 :: non_neg_integer()
}).

-type watchdog_state() :: #watchdog_state{}.


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
run_health_check(#watchdog_state{round=CurrentRound,sweep_cycle=SweepCycle}=State0) ->
  MaxRounds = max_rounds(),
  InfoMsg = "[round: ~p] [max_rounds: ~p] [sweep_cycle: ~p] [round_interval: ~p]",
  couch_log:info("couch_replicator_watchdog: heartbeat " ++ InfoMsg,
                    [CurrentRound, MaxRounds, SweepCycle, round_interval()]),
  State1 = update_stuck_repls(State0),
  maybe_reload_crashed_repls(),
  if CurrentRound =:= MaxRounds ->
      reload_stuck_repls(get_stuck_repls(State1#watchdog_state.stuck_repls)),
      State0#watchdog_state{round=0,
                            sweep_cycle=SweepCycle + 1,
                            stuck_repls=[],
                            crashed_repls=[]};
  true ->
      State1#watchdog_state{round = CurrentRound + 1} end.


-spec filter_crashed_repls([any()] | []) -> [any()] | [].
filter_crashed_repls([]) ->
    [];
filter_crashed_repls(Jobs) ->
    lists:filtermap(fun({Job}) ->
        History = couch_util:get_value(history, Job, []),
        if History =/= [] ->
            {JobRecord} = hd(History),
            case couch_util:get_value(type, JobRecord) of
                crashed ->
                    {true, {couch_util:get_value(id, Job), couch_util:get_value(doc_id, Job)}};
                _Else ->
                    false
            end;
        true -> false end
    end, Jobs).


maybe_reload_crashed_repls() ->
    ReplJobsToReload = filter_crashed_repls(couch_replicator_scheduler:jobs()),
    CrashedReplsN = length(ReplJobsToReload),
    if CrashedReplsN > 0 ->
        couch_log:alert("couch_replicator_watchdog: ~p replication(s) in the crashed state will be restarted",
            [CrashedReplsN]),
        couch_stats:increment_counter([couch_replicator, watchdog, restart_crashed], CrashedReplsN),
        lists:foreach(fun({JobId, DocId}) ->
            couch_log:warning("couch_replicator_watchdog: restarting ~p crashed replication with id: ~p", 
                [DocId, JobId]),
            couch_replicator:restart_job(JobId)
        end, ReplJobsToReload);
    true -> ok end.


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
                case lists:keyfind(changes_pending, 1, Task) of
                    {changes_pending, Pending} when is_number(Pending), Pending > 0 ->
                        true;
                    _Else ->
                        false
                end
  end, Tasks)).


-spec get_stuck_repls([urepl()]) -> [binary()] | [].
get_stuck_repls(Repls) ->
  case Repls of
      StuckRepls when is_list(StuckRepls) ->
          lists:map(fun(#unhealthy_repl{job_id=JobId, doc_id=DocId}) -> {JobId, DocId} end,
              [Repl || Repl <- Repls, Repl#unhealthy_repl.generation =:= max_rounds()]);
      _Else -> []
  end.


-spec reload_stuck_repls([{_, _}] | [{_, _}|{_, _}] | []) -> ok.
reload_stuck_repls([]) ->
  ok;
reload_stuck_repls(Jobs) ->
  StuckReplsN = length(Jobs),
  couch_log:alert("couch_replicator_watchdog: ~p replication(s) got stuck and will be restarted",[StuckReplsN]),
  couch_stats:increment_counter([couch_replicator, watchdog, restart_stalled], StuckReplsN),
  lists:foreach(fun({JobId, DocId}) ->
      couch_log:warning("couch_replicator_watchdog: restarting ~p replication with id: ~p", [DocId, JobId]),  
      couch_replicator:restart_job(JobId) 
  end, Jobs),
  ok.


-spec kill_threshold() -> non_neg_integer().
kill_threshold() -> 999999.


-spec round_interval() -> non_neg_integer().
round_interval() ->
    config:get_integer("replicator_watchdog", "round_interval", 60000).


-spec max_rounds() -> non_neg_integer().
max_rounds() ->
    config:get_integer("replicator_watchdog", "max_rounds", 3).