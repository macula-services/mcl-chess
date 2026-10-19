%% @doc end_game_api: the entry point a policy calls.
%%
%% PURE AND TOTAL, the same shape as the other internal desks' APIs, so a policy
%% has one call to make and one result to log.
-module(end_game_api).

-export([handle/1]).

-spec handle(map()) ->
    {ok, non_neg_integer(), [map()], map()} | {error, term()}.
handle(Params) ->
    handled(end_game_v1:new(#{game_id => maps:get(game_id, Params, undefined),
                              outcome => maps:get(outcome, Params, undefined),
                              winner_node_id => maps:get(winner_node_id, Params, <<>>),
                              reason => maps:get(reason, Params, none)})).

handled({ok, Cmd}) -> maybe_end_game:dispatch(Cmd);
handled({error, _} = Error) -> Error.
