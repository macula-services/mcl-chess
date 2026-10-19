%% @doc archive_game_api: the entry point the retention instance calls.
-module(archive_game_api).

-export([handle/1]).

-spec handle(map()) ->
    {ok, non_neg_integer(), [map()], map()} | {error, term()}.
handle(Params) ->
    handled(archive_game_v1:new(#{game_id => maps:get(game_id, Params, undefined)})).

handled({ok, Cmd}) -> maybe_archive_game:dispatch(Cmd);
handled({error, _} = Error) -> Error.
