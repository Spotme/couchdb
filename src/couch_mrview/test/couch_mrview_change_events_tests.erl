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
  DDoc = couch_mrview_test_util:ddoc({changes, seq_indexed_keyseq_indexed}),
  couch_mrview_test_util:save_docs(Db, [DDoc]),
  Db.

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
                    fun should_emit_index_update_event_/1,
                    fun should_emit_index_update_on_delete_event_/1,
                    fun should_emit_index_create_event_/1,
                    fun should_emit_index_delete_event_/1
                ]
            }
        }
    }.

should_emit_index_update_event_(Db) ->
    {ok, Doc} = couch_db:open_doc(Db, <<"1">>, []),
    couch_event:link_listener(
         ?MODULE, changes_view_event, {self(), nil}, [{dbname, couch_db:name(Db)}]
    ),
    {ok, _Rev} = couch_db:update_doc(Db, Doc, []),
    Result = receive
      {updated, _} = Msg ->
          Msg;
      Else ->
          Else
    end,
    ?_assertEqual(updated, Result).

should_emit_index_update_on_delete_event_(Db) ->
    {ok, Doc} = couch_db:open_doc(Db, <<"2">>, []),
    {ok, Rev} = couch_db:update_doc(Db, Doc, []),
    RevStr = couch_doc:rev_to_str(Rev),
    DeletedDoc = couch_doc:from_json_obj({[
        {<<"_id">>, <<"2">>},
        {<<"_rev">>, RevStr},
        {<<"_deleted">>, true}
    ]}),
    couch_event:link_listener(
         ?MODULE, changes_view_event, {self(), nil}, [{dbname, couch_db:name(Db)}]
    ),
    {ok, _Results} = couch_db:update_docs(Db, [DeletedDoc], []),
    Result = receive
      {updated, _} = Msg ->
          Msg;
      Else ->
          Else
    end,
    ?_assertEqual(updated, Result).

should_emit_index_create_event_(Db) ->
    {ok, DDoc} = couch_db:open_doc(Db, <<"_design/bar">>, []),
    {ok, Rev} = couch_db:update_doc(Db, DDoc, []),
    DDoc1 = ddoc_update(Rev),
    couch_event:link_listener(
         ?MODULE, changes_view_event, {self(), nil}, [{dbname, couch_db:name(Db)}]
    ),
    {ok, _Results} = couch_db:update_docs(Db, [DDoc1], []),
    _Res1 = couch_mrview:refresh(couch_db:name(Db), DDoc1),
    Result = receive
      {created, _} = Msg ->
          Msg;
      Else ->
          Else
    end,
    ?_assertEqual(created, Result).

should_emit_index_delete_event_(Db) ->
    {ok, DDoc} = couch_db:open_doc(Db, <<"_design/bar">>, []),
    Res1 = couch_mrview:refresh(couch_db:name(Db), DDoc),
    {ok, Rev} = couch_db:update_doc(Db, DDoc, []),
    couch_event:link_listener(
         ?MODULE, changes_view_event, {self(), nil}, [{dbname, couch_db:name(Db)}]
    ),
    DeletedDDoc = ddoc_delete(Rev),
    Res1 = couch_mrview:refresh(couch_db:name(Db), DeletedDDoc),
    Result = receive
      {deleted, _} = Msg ->
          Msg;
      Else ->
          Else
    end,
    ?_assertEqual(deleted, Result).

changes_view_event(_DbName, Msg, {Parent, _Ref}=St) ->
    case Msg of
        {index_commit, _DDocId} ->
            Parent ! updated,
            {ok, St};
        {index_delete, _DDocId} ->
            Parent ! deleted,
            {ok, St};
        {index_create, _DDocId} ->
            Parent ! created,
            {ok, St};
        Else ->
            Parent ! Else,
            stop
    end.

% Helpers
ddoc_update(Rev) ->
  ViewOpts = [{<<"seq_indexed">>, false},
              {<<"keyseq_indexed">>, false}],
  RevStr = couch_doc:rev_to_str(Rev),
  couch_doc:from_json_obj({[
      {<<"_id">>, <<"_design/bar">>},
      {<<"_rev">>, RevStr},
      {<<"options">>, {ViewOpts}},
      {<<"views">>, {[
          {<<"baz">>, {[
              {
                  <<"map">>,
                  <<"function(doc) {if (doc.val){emit(doc.val.toString(), doc.val);}}">>
              }
          ]}}
      ]}}
  ]}).

ddoc_delete(Rev) ->
    ViewOpts = [{<<"seq_indexed">>, true},
                {<<"keyseq_indexed">>, true}],
    RevStr = couch_doc:rev_to_str(Rev),
    couch_doc:from_json_obj({[
        {<<"_id">>, <<"_design/bar">>},
        {<<"_rev">>, RevStr},
        {<<"_deleted">>, true},
        {<<"options">>, {ViewOpts}},
        {<<"views">>, {[
            {<<"baz">>, {[
                {
                    <<"map">>,
                    <<"function(doc) {emit(doc.val.toString(), doc.val);}">>
                }
            ]}}
        ]}}
    ]}).
