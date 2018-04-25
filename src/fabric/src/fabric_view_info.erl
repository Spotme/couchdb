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

-module(fabric_view_info).

-export([go/3]).

-include_lib("fabric/include/fabric.hrl").
-include_lib("mem3/include/mem3.hrl").
-include_lib("couch/include/couch_db.hrl").

go(DbName, GroupId, VName) when is_binary(GroupId) ->
    {ok, DDoc} = fabric:open_doc(DbName, GroupId, [?ADMIN_CTX]),
    go(DbName, DDoc, VName);

go(DbName, #doc{id=DDocId}, VName) ->
    Shards = mem3:shards(DbName),
    Ushards = mem3:ushards(DbName),
    Workers = fabric_util:submit_jobs(Shards, view_info, [DDocId, VName]),
    RexiMon = fabric_util:create_monitors(Shards),
    Acc = acc_init(Workers, Ushards),
    try fabric_util:recv(Workers, #shard.ref, fun handle_message/3, Acc) of
    {timeout, {WorkersDict, _, _}} ->
        DefunctWorkers = fabric_util:remove_done_workers(WorkersDict, nil),
        fabric_util:log_timeout(DefunctWorkers, "view_info"),
        {error, timeout};
    Else ->
        Else
    after
        rexi_monitor:stop(RexiMon)
    end.

handle_message({rexi_DOWN, _, {_,NodeRef},_}, _Shard,
        {Counters, Acc, Ushards}) ->
    case fabric_util:remove_down_workers(Counters, NodeRef) of
    {ok, NewCounters} ->
        {ok, {NewCounters, Acc, Ushards}};
    error ->
        {error, {nodedown, <<"progress not possible">>}}
    end;

handle_message({rexi_EXIT, Reason}, Shard, {Counters, Acc, Ushards}) ->
    NewCounters = lists:keydelete(Shard, #shard.ref, Counters),
    case fabric_view:is_progress_possible(NewCounters) of
    true ->
        {ok, {NewCounters, Acc, Ushards}};
    false ->
        {error, Reason}
    end;

handle_message({ok, Info}, Shard, {Counters0, Acc, Ushards}) ->
    case fabric_dict:lookup_element(Shard, Counters0) of
    undefined ->
        % already heard from other node in this range
        {ok, {Counters0, Acc, Ushards}};
    nil ->
        NewAcc = append_result(Info, Shard, Acc, Ushards),
        Counters1 = fabric_dict:store(Shard, ok, Counters0),
        Counters = fabric_view:remove_overlapping_shards(Shard, Counters1),
        case is_complete(Counters) of
        false ->
            {ok, {Counters, NewAcc, Ushards}};
        true ->
            Infos = get_infos(NewAcc),
            Results = merge_results(Infos),
            {stop, Results}
        end
    end;
handle_message(_, _, Acc) ->
    {ok, Acc}.

acc_init(Workers, Ushards) ->
    Set = sets:from_list([{Id, N} || #shard{name = Id, node = N} <- Ushards]),
    {fabric_dict:init(Workers, nil), dict:new(), Set}.

is_complete(Counters) ->
    not fabric_dict:any(nil, Counters).

append_result(Info, #shard{name = Name, node = Node}, Acc, Ushards) ->
    IsPreferred = sets:is_element({Name, Node}, Ushards),
    dict:append(Name, {Node, IsPreferred, Info}, Acc).

get_infos(Acc) ->
    Values = [V || {_, V} <- dict:to_list(Acc)],
    lists:flatten([Info || {_Node, _Pref, Info} <- lists:flatten(Values)]).

merge_results(Info) ->
    Dict = lists:foldl(fun({K,V},D0) -> orddict:append(K,V,D0) end,
        orddict:new(), Info),
    orddict:fold(fun
        (seq_indexed, X, Acc) ->
            [{seq_indexed, lists:sum(X)} | Acc];
        (update_seq, X, Acc) ->
            [{update_seq, lists:sum(X)} | Acc];
        (purge_seq, X, Acc) ->
            [{purge_seq, lists:sum(X)} | Acc];
        (total_rows, X, Acc) ->
            [{total_rows, lists:sum(X)} | Acc];
        (total_seqs, X, Acc) ->
            [{total_seqs, lists:sum(X)} | Acc];
        (_, _, Acc) ->
            Acc
    end, [], Dict).

merge_object(Objects) ->
    Dict = lists:foldl(fun({Props}, D) ->
        lists:foldl(fun({K,V},D0) -> orddict:append(K,V,D0) end, D, Props)
    end, orddict:new(), Objects),
    orddict:fold(fun
        (Key, X, Acc) ->
            [{Key, lists:sum(X)} | Acc]
    end, [], Dict).
