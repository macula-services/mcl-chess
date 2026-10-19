%% @doc initiate_game_api: the entry point, pure and total.
%%
%% Pure, like every entry point here: the game id is minted when the caller
%% does not bring one, and the event echoes it back. Anything that is not a
%% dispatchable command comes back as {error, Reason} without touching the
%% store.
-module(initiate_game_api).

-export([handle/1]).

-spec handle(map()) ->
    {ok, non_neg_integer(), [map()], map()} | {error, term()}.
handle(Params) ->
    handled(initiate_game_v1:new(#{game_id => maps:get(game_id, Params,
                                                        initiate_game_v1:mint_game_id()),
                                   time_control => maps:get(time_control, Params,
                                                            undefined),
                                   seats => maps:get(seats, Params, empty_seats()),
                                   initiator => maps:get(initiator, Params,
                                                         undefined)})).
handled({ok, Cmd}) -> maybe_initiate_game:dispatch(Cmd);
handled({error, _} = Error) -> Error.

empty_seats() ->
    #{white => <<>>, black => <<>>}.
