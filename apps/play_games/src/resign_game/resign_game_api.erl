%% @doc resign_game_api: the entry point, pure and total.
%%
%% A resignation is never a recorded refusal, so there is nothing to unwrap: the
%% desk's result is the caller's answer.
-module(resign_game_api).

-export([handle/1]).

-spec handle(map()) ->
    {ok, non_neg_integer(), [map()], map()} | {error, term()}.
handle(Params) ->
    handled(resign_game_v1:new(#{game_id => maps:get(game_id, Params, undefined),
                                 caller => maps:get(caller, Params, undefined)})).

handled({ok, Cmd}) -> maybe_resign_game:dispatch(Cmd);
handled({error, _} = Error) -> Error.
