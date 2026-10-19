%% @doc The command that archives an ended game: INTERNAL, never on the wire.
%%
%% It is dispatched by the retention instance that waited out the window after
%% `game_ended_v1' (WP6), so no caller can archive a game: the death slice is
%% the service's own housekeeping, and a game that is gone too early is a game
%% nobody can review.
-module(archive_game_v1).

-behaviour(evoq_command).

-export([command_type/0, new/1, to_map/1, validate/1, from_map/1]).
-export([stream_id/1, get_game_id/1]).

-record(archive_game, {
    game_id :: binary()
}).

-opaque t() :: #archive_game{}.
-export_type([t/0]).

-spec command_type() -> atom().
command_type() -> archive_game_v1.

-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{game_id := GameId}) when is_binary(GameId), GameId =/= <<>> ->
    {ok, #archive_game{game_id = GameId}};
new(_) ->
    {error, missing_required_fields}.

-spec validate(t() | map()) -> ok | {error, term()}.
validate(#archive_game{game_id = GameId}) ->
    reckon_gater_stream_id:validate(GameId);
%% TWO SHAPES, ONE RULE: the desk validates the command it built, and evoq's
%% own router validates the payload it was handed when a process manager
%% dispatches this command (`evoq_command:validate/1' calls
%% `{command_type}:validate(Payload)', so it arrives as the map). Both carry the
%% same game id, and the stream contract is the only thing either checks.
validate(#{game_id := GameId}) ->
    reckon_gater_stream_id:validate(GameId).

-spec to_map(t()) -> map().
to_map(#archive_game{} = Cmd) ->
    #{command_type => command_type(), game_id => Cmd#archive_game.game_id}.

-spec from_map(map()) -> {ok, t()} | {error, term()}.
from_map(#{game_id := GameId}) ->
    new(#{game_id => GameId});
from_map(_) ->
    {error, missing_required_fields}.

-spec stream_id(t()) -> binary().
stream_id(#archive_game{game_id = GameId}) -> GameId.

-spec get_game_id(t()) -> binary().
get_game_id(#archive_game{game_id = GameId}) -> GameId.
