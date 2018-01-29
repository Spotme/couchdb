% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License.  You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
% License for the specific language governing permissions and limitations under
% the License.

-module(chttpd_auth).

-export([authenticate/2]).
-export([authorize/2]).

-export([key_authentification_handler/1]).
-export([default_authentication_handler/1]).
-export([cookie_authentication_handler/1]).
-export([party_mode_handler/1]).

-export([handle_session_req/1]).

-include_lib("couch/include/couch_db.hrl").

-define(SERVICE_ID, chttpd_auth).


%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

authenticate(HttpReq, Default) ->
    maybe_handle(authenticate, [HttpReq], Default).

authorize(HttpReq, Default) ->
    maybe_handle(authorize, [HttpReq], Default).


%% ------------------------------------------------------------------
%% Default callbacks
%% ------------------------------------------------------------------

default_authentication_handler(Req) ->
    couch_httpd_auth:default_authentication_handler(Req, chttpd_auth_cache).

cookie_authentication_handler(Req) ->
    couch_httpd_auth:cookie_authentication_handler(Req, chttpd_auth_cache).


key_authentification_handler(Req) ->
      % priority to the query string
      case couch_httpd:qs_value(Req, "auth_key") of
          undefined ->
              XKey = couch_config:get("spotme", "x_auth_key", "X-Auth-Key"),
              case couch_httpd:header_value(Req, XKey) of
                  undefined ->
                      Req;
                  HdrKey ->
                      validate_key(Req, HdrKey)

              end;
          Key ->
              validate_key(Req, Key)
      end.

party_mode_handler(Req) ->
    case config:get("chttpd", "require_valid_user", "false") of
    "true" ->
        throw({unauthorized, <<"Authentication required.">>});
    "false" ->
        case config:get("admins") of
        [] ->
            Req#httpd{user_ctx = ?ADMIN_USER};
        _ ->
            Req#httpd{user_ctx=#user_ctx{}}
        end
    end.

handle_session_req(Req) ->
    couch_httpd_auth:handle_session_req(Req, chttpd_auth_cache).


%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% TODO: add validation against IP & Domain.
validate_key(Req, Key) ->
    case couch_key:get_key(Key) of
        nil ->
            throw({unauthorized, <<"invalid key">>});
        KeyProps ->
            ok = validate_expires(KeyProps),
            Roles = couch_util:get_value(<<"roles">>, KeyProps, []),
            Req#httpd{user_ctx=#user_ctx{name=?l2b(Key), roles=Roles}}
    end.

validate_expires(KeyProps) ->
    case get_value(<<"expires">>, KeyProps) of
        undefined ->
            ok;
        Expires ->
            CurrentTime = get_unix_timestamp(erlang:now()),
            if CurrentTime > Expires ->
                    throw({unauthorized, <<"key expired">>});
                    true -> ok
            end
    end.


get_unix_timestamp({MegaSecs, Secs, _MicroSecs}) ->
    MegaSecs*1000000+Secs.

ensure_exists(DbName) when is_list(DbName) ->
      ensure_exists(list_to_binary(DbName));
ensure_exists(DbName) ->
      Options = [{user_ctx, #user_ctx{roles=[<<"_admin">>]}}],
      case couch_db:open_int(DbName, Options) of
      {ok, Db} ->
          {ok, Db};
      _ ->
          couch_server:create(DbName, Options)
      end.

get_value(Key, List) ->
      get_value(Key, List, undefined).

get_value(Key, List, Default) ->
      case lists:keysearch(Key, 1, List) of
      {value, {Key,Value}} ->
          Value;
      false ->
          Default
      end.

maybe_handle(Func, Args, Default) ->
    Handle = couch_epi:get_handle(?SERVICE_ID),
    case couch_epi:decide(Handle, ?SERVICE_ID, Func, Args, []) of
        no_decision when is_function(Default) ->
            apply(Default, Args);
        no_decision ->
            Default;
        {decided, Result} ->
            Result
    end.
