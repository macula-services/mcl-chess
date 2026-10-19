%% @doc The seat event: a colour now belongs to a node that asked for it.
%%
%% It carries the seats map AFTER the claim, so a projection or a replay reads
%% one event and never a read model. The holder is always the node macula
%% verified on the call: a seat is claimed by the claimer itself, never by a
%% body that names somebody else.
-module(seat_claimed_v1).

-behaviour(evoq_event).

-export([event_type/0, new/1, to_map/1, from_map/1]).
-export([get_game_id/1, get_player_node_id/1, get_color/1, get_seats/1,
         get_status/1]).

-record(seat_claimed, {
    game_id        :: binary(),
    player_node_id :: binary(),
    %% <<"w">> or <<"b">>, the same text the wire and `to_move' use.
    color          :: binary(),
    seats          :: map(),
    status         :: non_neg_integer(),
    at_ms          :: non_neg_integer()
}).

-opaque t() :: #seat_claimed{}.
-export_type([t/0]).

-spec event_type() -> binary().
event_type() -> <<"seat_claimed_v1">>.

-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{game_id := GameId, player_node_id := NodeId, color := Color,
      seats := Seats, status := Status} = Params)
        when is_binary(GameId), is_binary(NodeId), is_binary(Color),
             is_map(Seats) ->
    {ok, #seat_claimed{game_id = GameId,
                       player_node_id = NodeId,
                       color = Color,
                       seats = Seats,
                       status = Status,
                       at_ms = maps:get(at_ms, Params,
                                        erlang:system_time(millisecond))}};
new(_) ->
    {error, missing_required_fields}.

-spec to_map(t()) -> map().
to_map(#seat_claimed{} = Event) ->
    #{event_type => event_type(),
      game_id => Event#seat_claimed.game_id,
      player_node_id => Event#seat_claimed.player_node_id,
      color => Event#seat_claimed.color,
      seats => Event#seat_claimed.seats,
      status => Event#seat_claimed.status,
      at_ms => Event#seat_claimed.at_ms}.

-spec from_map(map()) -> {ok, t()} | {error, term()}.
from_map(#{game_id := GameId, player_node_id := NodeId, color := Color,
           seats := Seats, status := Status} = Map) ->
    {ok, #seat_claimed{game_id = GameId,
                       player_node_id = NodeId,
                       color = Color,
                       seats = Seats,
                       status = Status,
                       at_ms = maps:get(at_ms, Map, 0)}};
from_map(_) ->
    {error, missing_required_fields}.

-spec get_game_id(t()) -> binary().
get_game_id(#seat_claimed{game_id = GameId}) -> GameId.

-spec get_player_node_id(t()) -> binary().
get_player_node_id(#seat_claimed{player_node_id = NodeId}) -> NodeId.

-spec get_color(t()) -> binary().
get_color(#seat_claimed{color = Color}) -> Color.

-spec get_seats(t()) -> map().
get_seats(#seat_claimed{seats = Seats}) -> Seats.

-spec get_status(t()) -> non_neg_integer().
get_status(#seat_claimed{status = Status}) -> Status.
