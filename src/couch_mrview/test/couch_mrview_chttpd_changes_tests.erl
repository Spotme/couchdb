-module(couch_mrview_chttpd_changes_tests).


-include_lib("couch/include/couch_eunit.hrl").
-include_lib("couch/include/couch_db.hrl").


init_db(DbName, Type) ->
    ok = fabric:create_db(DbName, [?ADMIN_CTX]),
    DDoc = couch_mrview_test_util:ddoc(Type),
    {ok, _} = fabric:update_docs(DbName, [DDoc], [?ADMIN_CTX]),
    Docs = couch_mrview_test_util:make_docs(Type, 10),
    {ok, _} = fabric:update_docs(DbName, Docs, [?ADMIN_CTX]),
    {ok, DbName}.

setup() ->
  {ok, Db} = init_db(?tempdb(), {cluster_changes, seq_indexed}),
  {Db, get_host()}.

teardown({Db, _}) ->
    fabric:delete_db(Db, [?ADMIN_CTX]).

view_chage_test_() ->
    {
        "changes index events tests",
        {   
            setup,
            fun chttpd_test_util:start_couch/0, fun chttpd_test_util:stop_couch/1,
            {
                foreach,
                fun setup/0, fun teardown/1,
                [
                    fun normal_changes/1,
                    fun change_with_key/1
                ]
            }
        }
    }.
normal_changes({Db, HostUrl}) ->
    DbName = binary_to_list(Db),
    Url = HostUrl ++ "/" ++ DbName ++ "/_changes?feed=normal&filter=_view&view=bar/baz",
     {ok, 200, _Headers, BinBody} = test_request:get(Url, []),
    {Json} = jiffy:decode(BinBody),
    Changes = proplists:get_value(<<"results">>, Json, []),
    Ids = lists:sort([proplists:get_value(<<"id">>, Change) || {Change} <- Changes]),
    Expected = lists:sort([ list_to_binary(integer_to_list(Id)) || Id <- lists:seq(1, 10)]) ,
    ?_assertEqual(Expected, Ids).

change_with_key({Db, HostUrl}) ->
    DbName = binary_to_list(Db),
    Url = HostUrl ++ "/" ++ DbName ++ "/_changes?feed=normal&filter=_view&view=bar/baz&key=\"3\"",
    {ok, 200, _Headers, BinBody} = test_request:get(Url, []),
    {Json} = jiffy:decode(BinBody),
    Changes = proplists:get_value(<<"results">>, Json, []),
    Ids = lists:sort([proplists:get_value(<<"id">>, Change) || {Change} <- Changes]),
    Expected = [<<"3">>] ,
    ?_assertEqual(Expected, Ids).

get_host() ->
    Addr = config:get("httpd", "bind_address", "127.0.0.1"),
    Port = integer_to_list(mochiweb_socket_server:get(chttpd, port)),
    "http://" ++ Addr ++ ":" ++ Port.
