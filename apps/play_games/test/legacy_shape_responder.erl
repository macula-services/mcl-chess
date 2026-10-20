%% @doc A capability responder written the way mcl-chess 0.7.1 wrote one: every
%% field read as `maps:get(<<"key">>, Payload, Default)', including the caller.
%%
%% It is a fixture, and it stays one, because this is the shape that passed 206
%% tests and then refused every real caller on the live mesh (mcl-chess#10). On
%% this wire no payload looks like that: every text key arrives as `{text, Bin}'
%% and the verified caller arrives under the ATOM key as a raw 32-byte node id,
%% so a bare binary lookup finds neither and the default answers instead.
%%
%% `wire_shape_tests' puts it under `mcl_om_wire_test', where it refuses the way
%% it refused in production. The same fixture lives in mcl-om's suite
%% (`old_style_handler') as the record of the fault the helper was built for.
-module(legacy_shape_responder).

-behaviour(macula_response).

-export([init/1, handle_request/2]).

init([]) ->
    {ok, undefined}.

handle_request(Payload, State) ->
    {reply, answered(Payload), State}.

answered(Payload) when is_map(Payload) ->
    answered_with(maps:get(<<"game_id">>, Payload, undefined),
                  maps:get(<<"caller">>, Payload, <<>>));
answered(_) ->
    #{<<"error">> => {text, <<"invalid_request">>}}.

answered_with(GameId, Caller)
  when is_binary(GameId), GameId =/= <<>>, is_binary(Caller), Caller =/= <<>> ->
    #{<<"game_id">> => {text, GameId}};
answered_with(_GameId, _Caller) ->
    #{<<"error">> => {text, <<"missing_required_fields">>}}.
