-module(couch_key).

-export([get_key/1, get_key/2]).

-define(DNAME, <<"_design/auth_keys">>).

-define(SPOTME3_VIEW_BY_KEY, {[{<<"map">>, <<"
    function(doc) {
        if (doc.auth_keys) {
            for (var i=0; i < doc.auth_keys.length; i++) {
                var key = doc.auth_keys[i];
                emit(key.id, key);
            }
        }
    }">>
}]}).



-include_lib("couch/include/couch_db.hrl").
-include_lib("couch_mrview/include/couch_mrview.hrl").
%-include("couch_key_js.hrl").

get_key(Key) when is_list(Key) ->
    get_key(?l2b(Key));
get_key(Key) ->
    case binary:split(Key, <<",">>) of
        [DbName, Key1] ->
            get_key(DbName, Key1);
        _ ->
            nil
    end.

get_key(DbName, Key) ->
    Options = [{user_ctx, #user_ctx{roles=[<<"_admin">>]}}],
    case couch_db:open_int(DbName, Options) of
        {ok, Db0} ->
            ok = ensure_ddoc_exists(Db0, ?DNAME),
            {ok, Db} = couch_db:reopen(Db0),
            try
                KeyProps = get_key_props(Db, ?DNAME, Key),
                validate_key_props(KeyProps)
            after
                couch_db:close(Db)
            end;
        _ ->
            couch_log:notice("cant't load key: db ~p doesn't exist", [DbName]),
            nil
    end.

%% internal functions

get_key_props(Db, DDoc, Key) ->
    Args = #mrargs{start_key=Key, end_key=Key, limit=1},
    {ok, Acc} = couch_mrview:query_view(Db, DDoc, <<"by_key">>,
        Args, fun view_cb/2, nil),
    Acc.

view_cb({row, Row}, _Acc) ->
    {KeyProps} = couch_util:get_value(value, Row),
    {ok, KeyProps};
view_cb(_Other, Acc) ->
    {ok, Acc}.

validate_key_props(nil) ->
    nil;
validate_key_props(KeyProps) ->
    case couch_util:get_value(<<"_conflicts">>, KeyProps) of
        undefined ->
            KeyProps;
        _ConflictList ->
            throw({unauthorized,
                <<"Key document conflicts must be resolved before the document",
                  " is used for authentication purposes.">>
            })
        end.

ensure_ddoc_exists(Db, DDocId) ->
    case couch_db:open_doc(Db, DDocId) of
        {not_found, _Reason} ->
            {ok, DesignDoc} = keys_design_doc(DDocId),
            {ok, _Rev} =  couch_db:update_doc(Db, DesignDoc, []);
        {ok, Doc} ->
            {Props} = couch_doc:to_json_obj(Doc, []),
            {Views} = couch_util:get_value(<<"views">>, Props),
            case couch_util:get_value(<<"by_key">>, Views) of
                ?SPOTME3_VIEW_BY_KEY ->
                    ok;
                _ ->
                    Views1 = lists:keyreplace(<<"by_key">>, 1, Views,
                                              {<<"by_key">>,
                                               ?SPOTME3_VIEW_BY_KEY}),
                    Props1 = lists:keyreplace(<<"views">>, 1, Props,
                                              {<<"views">>, {Views1}}),
                    NewDoc = couch_doc:from_json_obj({Props1}),
                    {ok, _Rev} = couch_db:update_doc(Db, NewDoc, [])
            end
    end,
    ok.

keys_design_doc(DocId) ->
    DocProps = [
            {<<"_id">>, DocId},
            {<<"language">>,<<"javascript">>},
            {<<"views">>, {[{<<"by_key">>, ?SPOTME3_VIEW_BY_KEY}]}}
    ],
    {ok, couch_doc:from_json_obj({DocProps})}.
