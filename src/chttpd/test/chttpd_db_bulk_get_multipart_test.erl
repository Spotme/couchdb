-module(chttpd_db_bulk_get_multipart_test).

-include_lib("couch/include/couch_eunit.hrl").
-include_lib("couch/include/couch_db.hrl").

-define(TIMEOUT, 3000).


setup() ->
    mock(config),
    mock(chttpd),
    mock(couch_epi),
    mock(couch_httpd),
    mock(couch_stats),
    mock(fabric),
    mock(mochireq),
    Pid = spawn_accumulator(),
    Pid.


teardown(Pid) ->
    ok = stop_accumulator(Pid),
    meck:unload(config),
    meck:unload(chttpd),
    meck:unload(couch_epi),
    meck:unload(couch_httpd),
    meck:unload(couch_stats),
    meck:unload(fabric),
    meck:unload(mochireq).


bulk_get_test_() ->
    {
        "/db/_bulk_get tests",
        {
            foreach, fun setup/0, fun teardown/1,
            [
                fun should_require_docs_field/1,
                fun should_not_accept_specific_query_params/1,
                fun should_return_empty_results_on_no_docs/1,
                fun should_get_doc_with_all_revs/1,
                fun should_validate_doc_with_bad_id/1,
                fun should_validate_doc_with_bad_rev/1,
                fun should_validate_missing_doc/1,
                fun should_validate_bad_atts_since/1,
                fun should_include_attachments_when_atts_since_specified/1
            ]
        }
    }.


should_require_docs_field(_) ->
    Req = fake_request({[{}]}),
    ?_assertThrow({bad_request, _}, chttpd_db:db_req(Req, nil)).


should_not_accept_specific_query_params(_) ->
    Req = fake_request({[{<<"docs">>, []}]}),
    lists:map(fun (Param) ->
        {Param, ?_assertThrow({bad_request, _},
                              begin
                                  ok = meck:expect(chttpd, qs,
                                                   fun(_) -> [{Param, ""}] end),
                                  chttpd_db:db_req(Req, nil)
                              end)}
    end, ["rev", "open_revs", "atts_since", "w", "new_edits"]).


should_return_empty_results_on_no_docs(Pid) ->
    Req = fake_request({[{<<"docs">>, []}]}),
    chttpd_db:db_req(Req, nil),
    Results = get_results_from_response(Pid),
    ?_assertEqual([], Results).


should_get_doc_with_all_revs(Pid) ->
    DocId = <<"docudoc">>,
    Req = fake_request(DocId),

    DocRevA = #doc{id = DocId, body = {[{<<"_rev">>, <<"1-ABC">>}]}},
    DocRevB = #doc{id = DocId, body = {[{<<"_rev">>, <<"1-CDE">>}]}},

    mock_open_revs(all, {ok, [{ok, DocRevA}, {ok, DocRevB}]}),
    chttpd_db:db_req(Req, nil),

    [Hd|Rest] = get_results_from_response(Pid),
    ?assertEqual(<<"\r\n---">>, binary:part(Hd, {0, 5})),

    ?_assertEqual(2, length(Rest)).


should_validate_doc_with_bad_id(Pid) ->
    DocId = <<"_docudoc">>,

    Req = fake_request(DocId),
    chttpd_db:db_req(Req, nil),

    [Hd|Rest] = get_results_from_response(Pid),
    ?assertEqual(<<"\r\n---">>, binary:part(Hd, {0, 5})),

    ?_assertEqual(1, length(Rest)).


should_validate_doc_with_bad_rev(Pid) ->
    DocId = <<"docudoc">>,
    Rev = <<"revorev">>,

    Req = fake_request(DocId, Rev),
    chttpd_db:db_req(Req, nil),

    [Hd|Rest] = get_results_from_response(Pid),
    ?assertEqual(<<"\r\n---">>, binary:part(Hd, {0, 5})),

    ?_assertEqual(1, length(Rest)).


should_validate_missing_doc(Pid) ->
    DocId = <<"docudoc">>,
    Rev = <<"1-revorev">>,

    Req = fake_request(DocId, Rev),
    mock_open_revs([{1,<<"revorev">>}], {ok, []}),
    chttpd_db:db_req(Req, nil),

    [Hd|Rest] = get_results_from_response(Pid),
    ?assertEqual(<<"\r\n---">>, binary:part(Hd, {0, 5})),

    ?_assertEqual(1, length(Rest)).


should_validate_bad_atts_since(Pid) ->
    DocId = <<"docudoc">>,
    Rev = <<"1-revorev">>,

    Req = fake_request(DocId, Rev, <<"badattsince">>),
    mock_open_revs([{1,<<"revorev">>}], {ok, []}),
    chttpd_db:db_req(Req, nil),

    [Hd|Rest] = get_results_from_response(Pid),
    ?assertEqual(<<"\r\n---">>, binary:part(Hd, {0, 5})),

    ?_assertEqual(1, length(Rest)).


should_include_attachments_when_atts_since_specified(_) ->
    DocId = <<"docudoc">>,
    Rev = <<"1-revorev">>,

    Req = fake_request(DocId, Rev, [<<"1-abc">>]),
    mock_open_revs([{1,<<"revorev">>}], {ok, []}),
    chttpd_db:db_req(Req, nil),

    ?_assert(meck:called(fabric, open_revs,
                         [nil, DocId, [{1, <<"revorev">>}],
                          [{atts_since, [{1, <<"abc">>}]}, attachments]])).

%% helpers

fake_request(Payload) when is_tuple(Payload) ->
    #httpd{method='POST', path_parts=[<<"db">>, <<"_bulk_get">>],
           mochi_req=mochireq, req_body=Payload};
fake_request(DocId) when is_binary(DocId) ->
    fake_request({[{<<"docs">>, [{[{<<"id">>, DocId}]}]}]}).

fake_request(DocId, Rev) ->
    fake_request({[{<<"docs">>, [{[{<<"id">>, DocId}, {<<"rev">>, Rev}]}]}]}).

fake_request(DocId, Rev, AttsSince) ->
    fake_request({[{<<"docs">>, [{[{<<"id">>, DocId},
                                   {<<"rev">>, Rev},
                                   {<<"atts_since">>, AttsSince}]}]}]}).


mock_open_revs(RevsReq0, RevsResp) ->
    ok = meck:expect(fabric, open_revs,
                     fun(_, _, RevsReq1, _) ->
                         ?assertEqual(RevsReq0, RevsReq1),
                         RevsResp
                     end).


mock(mochireq) ->
    ok = meck:new(mochireq, [non_strict]),
    ok = meck:expect(mochireq, parse_qs, fun() -> [] end),
    ok = meck:expect(mochireq, accepts_content_type, fun("multipart/related") -> true;
                                                        (_) -> false end),
    ok;
mock(couch_httpd) ->
    ok = meck:new(couch_httpd, [passthrough]),
    ok = meck:expect(couch_httpd, validate_ctype, fun(_, _) -> ok end),
    ok = meck:expect(couch_httpd, start_chunked_response, fun(_, _, _) -> {ok, nil} end),
    ok = meck:expect(couch_httpd, last_chunk, fun(_) -> {ok, nil} end),
    ok = meck:expect(couch_httpd, send_chunk, fun send_chunk/2),
    ok;
mock(chttpd) ->
    ok = meck:new(chttpd, [passthrough]),
    ok = meck:expect(chttpd, start_json_response, fun(_, _) -> {ok, nil} end),
    ok = meck:expect(chttpd, end_json_response, fun(_) -> ok end),
    ok = meck:expect(chttpd, send_chunk, fun send_chunk/2),
    ok = meck:expect(chttpd, json_body_obj, fun (#httpd{req_body=Body}) -> Body end),
    ok;
mock(couch_epi) ->
    ok = meck:new(couch_epi, [passthrough]),
    ok = meck:expect(couch_epi, any, fun(_, _, _, _, _) -> false end),
    ok;
mock(couch_stats) ->
    ok = meck:new(couch_stats, [passthrough]),
    ok = meck:expect(couch_stats, increment_counter, fun(_) -> ok end),
    ok = meck:expect(couch_stats, increment_counter, fun(_, _) -> ok end),
    ok = meck:expect(couch_stats, decrement_counter, fun(_) -> ok end),
    ok = meck:expect(couch_stats, decrement_counter, fun(_, _) -> ok end),
    ok = meck:expect(couch_stats, update_histogram, fun(_, _) -> ok end),
    ok = meck:expect(couch_stats, update_gauge, fun(_, _) -> ok end),
    ok;
mock(fabric) ->
    ok = meck:new(fabric, [passthrough]),
    ok;
mock(config) ->
    ok = meck:new(config, [passthrough]),
    ok = meck:expect(config, get, fun(_, _, Default) -> Default end),
    ok.


spawn_accumulator() ->
    Parent = self(),
    Pid = spawn(fun() -> accumulator_loop(Parent, []) end),
    erlang:put(chunks_gather, Pid),
    Pid.

accumulator_loop(Parent, Acc) ->
    receive
        {stop, Ref} ->
            Parent ! {ok, Ref};
        {get, Ref} ->
            Parent ! {ok, Ref, Acc},
            accumulator_loop(Parent, Acc);
        {put, Ref, Chunk} ->
            Parent ! {ok, Ref},
            accumulator_loop(Parent, [Chunk|Acc])
    end.

stop_accumulator(Pid) ->
    Ref = make_ref(),
    Pid ! {stop, Ref},
    receive
        {ok, Ref} ->
            ok
    after ?TIMEOUT ->
        throw({timeout, <<"process stop timeout">>})
    end.


send_chunk(_, []) ->
    {ok, nil};
send_chunk(_Req, [H|T]=Chunk) when is_list(Chunk) ->
    send_chunk(_Req, H),
    send_chunk(_Req, T);
send_chunk(_, Chunk) ->
    Worker = erlang:get(chunks_gather),
    Ref = make_ref(),
    Worker ! {put, Ref, Chunk},
    receive
        {ok, Ref} -> {ok, nil}
    after ?TIMEOUT ->
        throw({timeout, <<"send chunk timeout">>})
    end.


get_response(Pid) ->
    Ref = make_ref(),
    Pid ! {get, Ref},
    receive
        {ok, Ref, Acc} ->
            Acc
    after ?TIMEOUT ->
        throw({timeout, <<"get response timeout">>})
    end.


get_results_from_response(Pid) ->
    get_response(Pid).
