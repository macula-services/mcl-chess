%% @doc The command that starts a game: INTERNAL, never served on the wire.
%%
%% It is dispatched by `on_seat_claimed_v1_maybe_start_game' when the second
%% seat is claimed, so a game starts itself and a pair of agents needs no extra
%% round trip. There is no responder and no capability for it: a caller that
%% could start a game would be a caller that could start one with an empty
%% seat, which the guard here refuses anyway.
-module(start_game_v1).

-behaviour(evoq_command).

-export([command_type/0, new/1, to_map/1, validate/1, from_map/1]).
-export([stream_id/1, get_game_id/1]).

-record(start_game, {
    game_id :: binary()
}).

-opaque t() :: #start_game{}.
-export_type([t/0]).

-spec command_type() -> atom().
command_type() -> start_game_v1.

-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{game_id := GameId}) when is_binary(GameId), GameId =/= <<>> ->
    {ok, #start_game{game_id = GameId}};
new(_) ->
    {error, missing_required_fields}.

-spec validate(t() | map()) -> ok | {error, term()}.
validate(#start_game{game_id = GameId}) ->
    reckon_gater_stream_id:validate(GameId);
%% TWO SHAPES, ONE RULE: the desk validates the command it built, and evoq's
%% own router validates the payload it was handed when a process manager
%% dispatches this command (`evoq_command:validate/1' calls
%% `{command_type}:validate(Payload)', so it arrives as the map). Both carry the
%% same game id, and the stream contract is the only thing either checks.
validate(#{game_id := GameId}) ->
    reckon_gater_stream_id:validate(GameId).

-spec to_map(t()) -> map().
to_map(#start_game{game_id = GameId}) ->
    #{command_type => command_type(), game_id => GameId}.

-spec from_map(map()) -> {ok, t()} | {error, term()}.
from_map(#{game_id := GameId}) ->
    new(#{game_id => GameId});
from_map(_) ->
    {error, missing_required_fields}.

-spec stream_id(t()) -> binary().
stream_id(#start_game{game_id = GameId}) -> GameId.

-spec get_game_id(t()) -> binary().
get_game_id(#start_game{game_id = GameId}) -> GameId.
