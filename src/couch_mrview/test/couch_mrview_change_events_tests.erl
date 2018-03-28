% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_mrview_change_events_tests).

-include_lib("couch/include/couch_eunit.hrl").
-include_lib("couch/include/couch_db.hrl").

-export([changes_view_event/3]).

setup() ->
  {ok, Db} = couch_mrview_test_util:init_db(?tempdb(), map),
  Db.
    % {ok, Db} = couch_mrview_test_util:new_db(?tempdb(), map),
    % _Doc = couch_mrview_test_util:doc(1),
    % Db.

teardown(Db) ->
    couch_db:close(Db),
    couch_server:delete(couch_db:name(Db), [?ADMIN_CTX]),
    ok.

changes_index_events_test_() ->
    {
        "changes index events tests",
        {
            setup,
            fun test_util:start_couch/0, fun test_util:stop_couch/1,
            {
                foreach,
                fun setup/0, fun teardown/1,
                [
                    fun should_emit_event_/1
                ]
            }
        }
    }.

should_emit_event_(Db) ->
  Doc = couch_mrview_test_util:doc(12),
  Ref = make_ref(),
  couch_event:link_listener(
       ?MODULE, changes_view_event, {self(), Ref}, [{dbname, couch_db:name(Db)}]
  ),
  {ok, _Rev} = couch_db:update_doc(Db, Doc, []),
  Result = receive
    {updated, _} = Msg ->
      Msg
  end,
  ?_assertEqual(Msg, {updated, Ref}).

changes_view_event(_DbName, Msg, {Parent, Ref}) ->
    case Msg of
        {index_commit, _DDocId} ->
            Parent ! updated;
        {index_delete, _DDocId} ->
            Parent ! deleted;
        _ ->
            ok
    end,
    {ok, {Parent, Ref}}.


test_normal_changes(Db) ->
    Result = run_query(Db, []),
    Expect = {ok, 11, [
                {{2, 1, <<"1">>}, 1},
                {{3, 10, <<"10">>}, 10},
                {{4, 2, <<"2">>}, 2},
                {{5, 3, <<"3">>}, 3},
                {{6, 4, <<"4">>}, 4},
                {{7, 5, <<"5">>}, 5},
                {{8, 6, <<"6">>}, 6},
                {{9, 7, <<"7">>}, 7},
                {{10, 8, <<"8">>}, 8},
                {{11, 9, <<"9">>}, 9}
    ]},
    ?_assertEqual(Result, Expect).


save_doc(Db, Id) ->
    Doc = couch_mrview_test_util:doc(Id),
    {ok, _Rev} = couch_db:update_doc(Db, Doc, []),
    {ok, _} =  couch_db:ensure_full_commit(Db),
    couch_db:reopen(Db).

run_query(Db, Opts) ->
    run_query(Db, Opts, true).

run_query(Db, Opts, Refresh) ->
    Fun = fun
        (stop, {LastSeq, Acc}) ->
            {ok, LastSeq, Acc};
        (heartbeat, Acc) ->
            {ok, [heartbeat | Acc]};
        (Event, Acc) ->
            {ok, [Event | Acc]}
    end,
    case Refresh of
        true ->
            couch_mrview:refresh(Db, <<"_design/bar">>);
        false ->
            ok
    end,
    {ok, LastSeq, R} = couch_mrview_changes:handle_changes(Db, <<"_design/bar">>,
                                                  <<"baz">>, Fun, [], Opts),
    {ok, LastSeq, lists:reverse(R)}.
