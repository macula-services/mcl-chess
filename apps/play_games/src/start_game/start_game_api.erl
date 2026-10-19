%% @doc start_game_api: the entry point the seats-full policy calls.
%%
%% PURE AND TOTAL, the same shape as the other desks' APIs, so the policy has
%% one call to make and one result to log.
-module(start_game_api).

-export([handle/1]).

-spec handle(map()) ->
    {ok, non_neg_integer(), [map()], map()} | {error, term()}.
handle(Params) ->
    handled(start_game_v1:new(#{game_id => maps:get(game_id, Params, undefined)})).

handled({ok, Cmd}) -> maybe_start_game:dispatch(Cmd);
handled({error, _} = Error) -> Error.
