%% @doc The command that flags a player whose clock ran out: INTERNAL, never
%% served on the wire.
%%
%% It is dispatched by the game's clock instance when the deadline it scheduled
%% fires (WP6), so no caller can flag anybody: the service never pokes an agent,
%% the clock decides on its own. The command names the player the deadline was
%% for, and the desk re-derives everything else from the aggregate: whether it
%% is still that player's turn, whether their clock really is out at the moment
%% the flag is recorded, and whether they have been flagged already.
-module(flag_clock_v1).

-behaviour(evoq_command).

-export([command_type/0, new/1, to_map/1, validate/1, from_map/1]).
-export([stream_id/1, get_game_id/1, get_player_node_id/1]).

-record(flag_clock, {
    game_id        :: binary(),
    player_node_id :: binary()
}).

-opaque t() :: #flag_clock{}.
-export_type([t/0]).

-spec command_type() -> atom().
command_type() -> flag_clock_v1.

-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{game_id := GameId, player_node_id := NodeId}) when is_binary(GameId),
                                                         is_binary(NodeId),
                                                         GameId =/= <<>>,
                                                         NodeId =/= <<>> ->
    {ok, #flag_clock{game_id = GameId, player_node_id = NodeId}};
new(_) ->
    {error, missing_required_fields}.

-spec validate(t() | map()) -> ok | {error, term()}.
validate(#flag_clock{game_id = GameId}) ->
    reckon_gater_stream_id:validate(GameId);
%% TWO SHAPES, ONE RULE: the desk validates the command it built, and evoq's
%% own router validates the payload it was handed when a process manager
%% dispatches this command (`evoq_command:validate/1' calls
%% `{command_type}:validate(Payload)', so it arrives as the map). Both carry the
%% same game id, and the stream contract is the only thing either checks.
validate(#{game_id := GameId}) ->
    reckon_gater_stream_id:validate(GameId).

-spec to_map(t()) -> map().
to_map(#flag_clock{} = Cmd) ->
    #{command_type => command_type(),
      game_id => Cmd#flag_clock.game_id,
      player_node_id => Cmd#flag_clock.player_node_id}.

-spec from_map(map()) -> {ok, t()} | {error, term()}.
from_map(#{game_id := GameId, player_node_id := NodeId}) ->
    new(#{game_id => GameId, player_node_id => NodeId});
from_map(_) ->
    {error, missing_required_fields}.

-spec stream_id(t()) -> binary().
stream_id(#flag_clock{game_id = GameId}) -> GameId.

-spec get_game_id(t()) -> binary().
get_game_id(#flag_clock{game_id = GameId}) -> GameId.

-spec get_player_node_id(t()) -> binary().
get_player_node_id(#flag_clock{player_node_id = NodeId}) -> NodeId.
