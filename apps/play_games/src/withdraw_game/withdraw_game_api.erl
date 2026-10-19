%% @doc withdraw_game_api: the entry point, pure and total.
-module(withdraw_game_api).

-export([handle/1]).

-spec handle(map()) ->
    {ok, non_neg_integer(), [map()], map()} | {error, term()}.
handle(Params) ->
    handled(withdraw_game_v1:new(#{game_id => maps:get(game_id, Params, undefined),
                                   caller => maps:get(caller, Params, undefined)})).

handled({ok, Cmd}) -> maybe_withdraw_game:dispatch(Cmd);
handled({error, _} = Error) -> Error.
