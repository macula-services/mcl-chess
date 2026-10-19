%% @doc The recorded refusal: a claim on a taken or full seat.
%%
%% This is the ONE class of refusal that is written to the stream. It is how
%% matchmaking observes demand (mcl-chess#1, section 3.2), and the count is
%% bounded by claimants, not by spam, which is what keeps a stranger from
%% growing a game's stream. Every refusal with no standing (a game that does
%% not exist, an archived game, a malformed colour) is answered on the wire
%% and records nothing at all.
%%
%% The seats map is carried UNCHANGED beside the reason, so the event says
%% what the claimant wanted and what was actually there.
-module(seat_refused_v1).

-behaviour(evoq_event).

-export([event_type/0, new/1, to_map/1, from_map/1]).
-export([get_game_id/1, get_player_node_id/1, get_color/1, get_reason/1,
         get_seats/1, get_status/1]).

-record(seat_refused, {
    game_id        :: binary(),
    player_node_id :: binary(),
    color          :: binary(),
    %% `seat_taken' or `game_full'.
    reason         :: atom(),
    seats          :: map(),
    status         :: non_neg_integer(),
    at_ms          :: non_neg_integer()
}).

-opaque t() :: #seat_refused{}.
-export_type([t/0]).

-spec event_type() -> binary().
event_type() -> <<"seat_refused_v1">>.

-spec new(map()) -> {ok, t()} | {error, term()}.
new(#{game_id := GameId, player_node_id := NodeId, color := Color,
      reason := Reason, seats := Seats, status := Status} = Params)
        when is_binary(GameId), is_binary(NodeId), is_binary(Color),
             is_atom(Reason), is_map(Seats) ->
    {ok, #seat_refused{game_id = GameId,
                       player_node_id = NodeId,
                       color = Color,
                       reason = Reason,
                       seats = Seats,
                       status = Status,
                       at_ms = maps:get(at_ms, Params,
                                        erlang:system_time(millisecond))}};
new(_) ->
    {error, missing_required_fields}.

-spec to_map(t()) -> map().
to_map(#seat_refused{} = Event) ->
    #{event_type => event_type(),
      game_id => Event#seat_refused.game_id,
      player_node_id => Event#seat_refused.player_node_id,
      color => Event#seat_refused.color,
      reason => Event#seat_refused.reason,
      seats => Event#seat_refused.seats,
      status => Event#seat_refused.status,
      at_ms => Event#seat_refused.at_ms}.

-spec from_map(map()) -> {ok, t()} | {error, term()}.
from_map(#{game_id := GameId, player_node_id := NodeId, color := Color,
           reason := Reason, seats := Seats, status := Status} = Map) ->
    {ok, #seat_refused{game_id = GameId,
                       player_node_id = NodeId,
                       color = Color,
                       reason = Reason,
                       seats = Seats,
                       status = Status,
                       at_ms = maps:get(at_ms, Map, 0)}};
from_map(_) ->
    {error, missing_required_fields}.

-spec get_game_id(t()) -> binary().
get_game_id(#seat_refused{game_id = GameId}) -> GameId.

-spec get_player_node_id(t()) -> binary().
get_player_node_id(#seat_refused{player_node_id = NodeId}) -> NodeId.

-spec get_color(t()) -> binary().
get_color(#seat_refused{color = Color}) -> Color.

-spec get_reason(t()) -> atom().
get_reason(#seat_refused{reason = Reason}) -> Reason.

-spec get_seats(t()) -> map().
get_seats(#seat_refused{seats = Seats}) -> Seats.

-spec get_status(t()) -> non_neg_integer().
get_status(#seat_refused{status = Status}) -> Status.
