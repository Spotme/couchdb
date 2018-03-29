-module(couch_mrview_chttpd_changes_tests).


-include_lib("couch/include/couch_eunit.hrl").
-include_lib("couch/include/couch_db.hrl").


init_db(DbName, Type) ->
    ok = fabric:create_db(DbName, [?ADMIN_CTX]),
    DDoc = couch_mrview_test_util:ddoc(Type),
    ?LOG_INFO(["creating that fucking ddoc~p~n", DDoc] ),
    {ok, _} = fabric:update_docs(DbName, [DDoc], [DDoc]),
    Docs = couch_mrview_test_util:make_docs(Type, 10),
    {ok, _} = fabric:update_docs(DbName, Docs, []),
    {ok, DbName}.

setup() ->
  {ok, Db} = init_db(?tempdb(), map),
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
                    fun normal_changes/1
                ]
            }
        }
    }.
normal_changes({Db, HostUrl}) ->
    DbName = binary_to_list(Db),
    Url = HostUrl ++ "/" ++ DbName ++ "/_changes?filter=_view&view=bar/baz",
    {ok, Status, _Headers, BinBody} = test_request:get(Url, []),
    ?LOG_INFO(["got changes ~p~n", BinBody] ),
    ?_assertEqual(Status, 200).

get_host() ->
    Addr = config:get("httpd", "bind_address", "127.0.0.1"),
    Port = integer_to_list(mochiweb_socket_server:get(chttpd, port)),
    "http://" ++ Addr ++ ":" ++ Port.
