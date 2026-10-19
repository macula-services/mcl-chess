%% @doc The command that ends a game before it began.
%%
%% A withdraw before the game starts is not an end: the plan is explicit that
%% it produces `game_archived_v1' with reason `withdrawn', because the game
%% never existed as play (mcl-chess#1, section 4). Only the initiator may
%% withdraw, and only while the game has not started.
-module(withdraw_game_v1).

-behaviour(evoq_command).

-export([command_type/0, new/1, to_map/1, validate/1, from_map/1]).
-export([stream_id/1, get_game_id/1, get_caller/1]).

-record(withdraw_game, {
    game_id :: binary(),
    caller  :: binary()
}).

-opaque t() :: #withdraw_game{}.
-export_type([t/0]).

-spec command_type() -> atom().
command_type() -> withdraw_game_v1.

-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{game_id := GameId, caller := Caller}) when is_binary(GameId), is_binary(Caller),
                                                 GameId =/= <<>>, Caller =/= <<>> ->
    {ok, #withdraw_game{game_id = GameId, caller = Caller}};
new(_) ->
    {error, missing_required_fields}.

-spec validate(t()) -> ok | {error, term()}.
validate(#withdraw_game{game_id = GameId}) ->
    reckon_gater_stream_id:validate(GameId).

-spec to_map(t()) -> map().
to_map(#withdraw_game{game_id = GameId, caller = Caller}) ->
    #{command_type => command_type(),
      game_id => GameId,
      caller => Caller}.

-spec from_map(map()) -> {ok, t()} | {error, term()}.
from_map(#{game_id := GameId, caller := Caller}) ->
    new(#{game_id => GameId, caller => Caller});
from_map(_) ->
    {error, missing_required_fields}.

-spec stream_id(t()) -> binary().
stream_id(#withdraw_game{game_id = GameId}) -> GameId.

-spec get_game_id(t()) -> binary().
get_game_id(#withdraw_game{game_id = GameId}) -> GameId.

-spec get_caller(t()) -> binary().
get_caller(#withdraw_game{caller = Caller}) -> Caller.
