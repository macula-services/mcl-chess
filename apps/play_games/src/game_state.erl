%% @doc The Game aggregate's state: the record, its fold, its wire shape.
%%
%% The state module is the only module that sees the record. It remembers
%% what the later events need to echo (the time control, the seats, the
%% initiator), so each event stays self-contained for its projection.
%%
%% Every event carries the FULL state it produced, which is what lets a
%% projection or a replay interpret one event with no second stream
%% (philosophy/DDD.md). So the fold here is a straight assignment of what the
%% event says, not a re-derivation of it.
-module(game_state).

-behaviour(evoq_state).

-include("game_state.hrl").
-include("game_status.hrl").

-export([new/1, apply_event/2, to_map/1, from_map/1]).
-export([game_id/1, status/1, initiator_node_id/1, seats/1, time_control/1]).
-export([position/1, to_move/1, ply/1, clocks/1]).
-export([seat/2, is_seated/2, both_seats_filled/1]).
-export([colour_key/1, colour_wire/1]).
-export([is_archived/1, is_initiated/1, is_started/1, is_unstarted/1]).
-export([to_wire/1]).

-opaque t() :: #game_state{}.
-export_type([t/0]).

-spec new(binary()) -> t().
new(GameId) ->
    #game_state{game_id = GameId}.

%% @doc Fold one event.
%%
%% evoq hands apply/2 TWO SHAPES for the same event: the raw event right
%% after execute/2 (business fields inline), and the stored envelope on
%% reload (business fields under `data'). Read tolerantly.
-spec apply_event(t(), map()) -> t().
apply_event(State, #{event_type := <<"game_initiated_v1">>} = Event) ->
    Data = event_data(Event),
    State#game_state{
        protocol = maps:get(protocol, Data, <<"chess">>),
        time_control = maps:get(time_control, Data),
        seats = maps:get(seats, Data, State#game_state.seats),
        position = maps:get(position, Data, State#game_state.position),
        to_move = maps:get(to_move, Data, State#game_state.to_move),
        ply = maps:get(ply, Data, 0),
        clocks = maps:get(clocks, Data, State#game_state.clocks),
        status = maps:get(status, Data),
        initiator_node_id = maps:get(initiator_node_id, Data, <<>>),
        at_ms = maps:get(at_ms, Data, 0)};
apply_event(State, #{event_type := <<"seat_claimed_v1">>} = Event) ->
    Data = event_data(Event),
    State#game_state{seats = maps:get(seats, Data),
                     status = maps:get(status, Data),
                     at_ms = maps:get(at_ms, Data, State#game_state.at_ms)};
%% A recorded refusal is evidence on the stream and changes no state: the event
%% carries the seats unchanged, and the fold says so rather than re-deriving it.
apply_event(State, #{event_type := <<"seat_refused_v1">>}) ->
    State;
apply_event(State, #{event_type := <<"game_started_v1">>} = Event) ->
    Data = event_data(Event),
    State#game_state{
        seats = (State#game_state.seats)#{white => maps:get(white_node_id, Data),
                                         black => maps:get(black_node_id, Data)},
        position = maps:get(position, Data),
        to_move = maps:get(to_move, Data),
        ply = maps:get(ply, Data),
        clocks = maps:get(clocks, Data),
        status = maps:get(status, Data),
        at_ms = maps:get(at_ms, Data, State#game_state.at_ms)};
apply_event(State, #{event_type := <<"game_archived_v1">>} = Event) ->
    Data = event_data(Event),
    State#game_state{status = maps:get(status, Data),
                     at_ms = maps:get(at_ms, Data, State#game_state.at_ms)};
apply_event(State, _Event) ->
    State.

-spec to_map(t()) -> map().
to_map(#game_state{} = State) ->
    #{game_id => State#game_state.game_id,
      protocol => State#game_state.protocol,
      time_control => State#game_state.time_control,
      seats => State#game_state.seats,
      position => State#game_state.position,
      to_move => State#game_state.to_move,
      ply => State#game_state.ply,
      clocks => State#game_state.clocks,
      status => State#game_state.status,
      initiator_node_id => State#game_state.initiator_node_id,
      at_ms => State#game_state.at_ms}.

-spec from_map(map()) -> {ok, t()} | {error, term()}.
from_map(#{game_id := GameId} = Map) ->
    {ok, #game_state{
        game_id = GameId,
        protocol = maps:get(protocol, Map, <<"chess">>),
        time_control = maps:get(time_control, Map),
        seats = maps:get(seats, Map),
        position = maps:get(position, Map),
        to_move = maps:get(to_move, Map),
        ply = maps:get(ply, Map),
        clocks = maps:get(clocks, Map),
        status = maps:get(status, Map),
        initiator_node_id = maps:get(initiator_node_id, Map, <<>>),
        at_ms = maps:get(at_ms, Map, 0)}};
from_map(_) ->
    {error, missing_game_id}.

%% @doc What a caller sees. Binary keys and 1/0 flags, because it goes on the
%% wire: the mesh encodes no booleans and no atom keys.
-spec to_wire(t()) -> map().
to_wire(#game_state{} = State) ->
    {Initial, Increment} = State#game_state.time_control,
    #{<<"game_id">> => State#game_state.game_id,
      <<"protocol">> => State#game_state.protocol,
      <<"status">> => State#game_state.status,
      <<"status_label">> => game_status:to_string(State#game_state.status),
      <<"time_control">> => #{<<"initial_ms">> => Initial,
                              <<"increment_ms">> => Increment},
      <<"seats">> => to_wire_seats(State#game_state.seats),
      <<"position">> => State#game_state.position,
      <<"to_move">> => State#game_state.to_move,
      <<"ply">> => State#game_state.ply,
      <<"clocks">> => to_wire_clocks(State#game_state.clocks),
      <<"initiator">> => State#game_state.initiator_node_id,
      <<"at_ms">> => State#game_state.at_ms}.

to_wire_seats(Seats) ->
    maps:fold(fun(Color, NodeId, Acc) ->
                      Acc#{colour(Color) => NodeId}
              end, #{}, Seats).

to_wire_clocks(Clocks) ->
    maps:fold(fun(Color, Ms, Acc) -> Acc#{colour(Color) => Ms} end, #{}, Clocks).

colour(white) -> <<"white">>;
colour(black) -> <<"black">>.

-spec game_id(t()) -> binary().
game_id(#game_state{game_id = GameId}) -> GameId.

-spec status(t()) -> non_neg_integer().
status(#game_state{status = Status}) -> Status.

-spec initiator_node_id(t()) -> binary().
initiator_node_id(#game_state{initiator_node_id = Id}) -> Id.

-spec seats(t()) -> map().
seats(#game_state{seats = Seats}) -> Seats.

-spec time_control(t()) -> {non_neg_integer(), non_neg_integer()}.
time_control(#game_state{time_control = TimeControl}) -> TimeControl.

-spec position(t()) -> binary().
position(#game_state{position = Position}) -> Position.

-spec to_move(t()) -> binary().
to_move(#game_state{to_move = ToMove}) -> ToMove.

-spec ply(t()) -> non_neg_integer().
ply(#game_state{ply = Ply}) -> Ply.

-spec clocks(t()) -> map().
clocks(#game_state{clocks = Clocks}) -> Clocks.

%% @doc The node holding this colour, or an empty binary when the seat is free.
-spec seat(t(), white | black) -> binary().
seat(#game_state{seats = Seats}, Colour) ->
    maps:get(Colour, Seats, <<>>).

%% @doc Whether this node holds a seat, either one. A node gets one seat, never
%% two: two seats are two consenting agents.
-spec is_seated(t(), binary()) -> boolean().
is_seated(#game_state{seats = Seats}, NodeId) ->
    lists:member(NodeId, maps:values(Seats)).

%% @doc Whether both colours are taken, which is what starts a game.
-spec both_seats_filled(t()) -> boolean().
both_seats_filled(#game_state{seats = Seats}) ->
    not lists:member(<<>>, maps:values(Seats)).

%% @doc The wire's colour text (`<<"w">>'/`<<"b">>') as the aggregate's key.
-spec colour_key(binary()) -> white | black | invalid.
colour_key(<<"w">>) -> white;
colour_key(<<"b">>) -> black;
colour_key(_) -> invalid.

%% @doc The aggregate's colour key as the wire's text.
-spec colour_wire(white | black) -> binary().
colour_wire(white) -> <<"w">>;
colour_wire(black) -> <<"b">>.

-spec is_archived(t()) -> boolean().
is_archived(#game_state{status = Status}) -> evoq_bit_flags:has(Status, ?GAME_ARCHIVED).

-spec is_initiated(t()) -> boolean().
is_initiated(#game_state{status = Status}) ->
    evoq_bit_flags:has(Status, ?GAME_INITIATED).

-spec is_started(t()) -> boolean().
is_started(#game_state{status = Status}) -> evoq_bit_flags:has(Status, ?GAME_STARTED).

-spec is_unstarted(t()) -> boolean().
is_unstarted(State) -> not is_started(State).

%% @private A stored envelope carries its business fields under `data'; a
%% freshly executed event carries them inline.
event_data(#{data := Data}) when is_map(Data) -> Data;
event_data(Event) -> Event.
