%% @doc flag_clock_api: the entry point the game's clock instance calls.
%%
%% PURE AND TOTAL, the same shape as the other desks' APIs: the instance builds
%% the command from its own state, and this is the one call it makes.
-module(flag_clock_api).

-export([handle/1]).

-spec handle(map()) ->
    {ok, non_neg_integer(), [map()], map()} | {error, term()}.
handle(Params) ->
    handled(flag_clock_v1:new(#{game_id => maps:get(game_id, Params, undefined),
                                player_node_id =>
                                    maps:get(player_node_id, Params, undefined)})).

handled({ok, Cmd}) -> maybe_flag_clock:dispatch(Cmd);
handled({error, _} = Error) -> Error.
