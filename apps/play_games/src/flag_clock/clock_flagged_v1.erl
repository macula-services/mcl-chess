%% @doc The flag event: this player's clock ran out.
%%
%% It is a fact about the clock, not a move: the position and the ply stand, and
%% the flagged player's clock is at zero. The game ends in the SAME command
%% (`maybe_flag_clock' appends `game_ended_v1' after this event), for the same
%% reason the second claim appends the start: a crash cannot be allowed between
%% "the clock ran out" and "the game is over", because nothing else in the
%% system would ever look at that game again.
%%
%% Both the flag and the end are published, and the flag comes first: a consumer
%% that reads the pair knows the game was lost on time, not merely that it ended
%% with a forfeit.
-module(clock_flagged_v1).

-behaviour(evoq_event).

-export([event_type/0, new/1, to_map/1, from_map/1]).
-export([get_game_id/1, get_player_node_id/1, get_clocks/1, get_status/1]).

-record(clock_flagged, {
    game_id        :: binary(),
    player_node_id :: binary(),
    clocks         :: map(),
    status         :: non_neg_integer(),
    at_ms          :: non_neg_integer()
}).

-opaque t() :: #clock_flagged{}.
-export_type([t/0]).

-spec event_type() -> binary().
event_type() -> <<"clock_flagged_v1">>.

-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{game_id := GameId, player_node_id := NodeId, clocks := Clocks,
      status := Status} = Params)
        when is_binary(GameId), is_binary(NodeId), NodeId =/= <<>>,
             is_map(Clocks) ->
    {ok, #clock_flagged{game_id = GameId,
                        player_node_id = NodeId,
                        clocks = Clocks,
                        status = Status,
                        at_ms = maps:get(at_ms, Params,
                                         erlang:system_time(millisecond))}};
new(_) ->
    {error, missing_required_fields}.

-spec to_map(t()) -> map().
to_map(#clock_flagged{} = Event) ->
    #{event_type => event_type(),
      game_id => Event#clock_flagged.game_id,
      player_node_id => Event#clock_flagged.player_node_id,
      clocks => Event#clock_flagged.clocks,
      status => Event#clock_flagged.status,
      at_ms => Event#clock_flagged.at_ms}.

-spec from_map(map()) -> {ok, t()} | {error, term()}.
from_map(#{game_id := GameId, player_node_id := NodeId, clocks := Clocks,
           status := Status} = Map) ->
    {ok, #clock_flagged{game_id = GameId,
                        player_node_id = NodeId,
                        clocks = Clocks,
                        status = Status,
                        at_ms = maps:get(at_ms, Map, 0)}};
from_map(_) ->
    {error, missing_required_fields}.

-spec get_game_id(t()) -> binary().
get_game_id(#clock_flagged{game_id = GameId}) -> GameId.

-spec get_player_node_id(t()) -> binary().
get_player_node_id(#clock_flagged{player_node_id = NodeId}) -> NodeId.

-spec get_clocks(t()) -> map().
get_clocks(#clock_flagged{clocks = Clocks}) -> Clocks.

-spec get_status(t()) -> non_neg_integer().
get_status(#clock_flagged{status = Status}) -> Status.
