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
-export([position/1, to_move/1, ply/1, clocks/1, halfmove_clock/1]).
-export([position_hash/1, hash_history/1, repetition_count/1]).
-export([advance_hashes/3, occurrences/2, at_ms/1, charge_turn/4]).
-export([remaining_ms/3, expired/3, flagged_node_id/1]).
-export([repetition_draw/0]).
-export([outcome/1, winner_node_id/1, end_reason/1]).
-export([seat/2, is_seated/2, both_seats_filled/1, colour_of/2]).
-export([colour_key/1, colour_wire/1]).
-export([record_refusal/2, refusal_count/2, may_record_refusal/2,
         max_recorded_refusals/0]).
-export([is_archived/1, is_initiated/1, is_started/1, is_ended/1, is_unstarted/1]).
-export([to_wire/1]).

%% The cap on recorded refusals per player per game, settled at the Design Gate
%% (answer 5, N = 10). It exists because a recorded refusal is evidence, and
%% evidence a stranger can write without bound is a way to grow somebody else's
%% stream. One definition, shared by `seat_refused_v1' and `move_refused_v1'.
-define(MAX_RECORDED_REFUSALS, 10).

%% The number of times a position must have occurred for the automatic draw
%% (mcl-chess#4). One definition: the move event records the count, the end
%% policy compares against this, and the 50 move and threefold draws stay v2
%% claims. The 75 move rule's 150 halfmoves are the rules engine's, because it
%% is the engine that judges the position.
-define(FIVEFOLD_REPETITION, 5).

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
%% A recorded refusal is evidence on the stream: it changes no game state, and
%% it is counted, because the count is what bounds the evidence.
apply_event(State, #{event_type := <<"seat_refused_v1">>} = Event) ->
    record_refusal(State, maps:get(player_node_id, event_data(Event)));
apply_event(State, #{event_type := <<"game_started_v1">>} = Event) ->
    Data = event_data(Event),
    State#game_state{
        seats = (State#game_state.seats)#{white => maps:get(white_node_id, Data),
                                         black => maps:get(black_node_id, Data)},
        position = maps:get(position, Data),
        to_move = maps:get(to_move, Data),
        ply = maps:get(ply, Data),
        clocks = maps:get(clocks, Data),
        %% The counter starts at zero and the repetition history at the start
        %% position, which is a position the game can return to.
        halfmove_clock = 0,
        hashes = [maps:get(position_hash, Data)],
        status = maps:get(status, Data),
        at_ms = maps:get(at_ms, Data, State#game_state.at_ms)};
%% A played move is the only event that advances the position, the counter and
%% the repetition history. The counter is the event's own value rather than an
%% increment here: the desk computed it, and a replay must fold the same one.
apply_event(State, #{event_type := <<"move_played_v1">>} = Event) ->
    Data = event_data(Event),
    Hash = maps:get(position_hash, Data),
    State#game_state{
        position = maps:get(fen_after, Data),
        to_move = maps:get(to_move, Data),
        ply = maps:get(ply, Data),
        clocks = maps:get(clocks, Data),
        halfmove_clock = maps:get(halfmove_clock, Data),
        hashes = advance_hashes(State#game_state.hashes,
                                maps:get(halfmove_clock, Data), Hash),
        status = maps:get(status, Data),
        at_ms = maps:get(at_ms, Data, State#game_state.at_ms)};
%% A move refusal is the same evidence class as a seat refusal: nothing about
%% the game changes, and the count is what bounds it. `at_ms' is deliberately
%% left alone, so the turn in progress keeps the moment it began and a refused
%% move cannot shorten the mover's clock.
apply_event(State, #{event_type := <<"move_refused_v1">>} = Event) ->
    record_refusal(State, maps:get(player_node_id, event_data(Event)));
%% A flagged clock is a fact about the clock, not a move: the position and the
%% ply stand, the flagged player's clock is at zero, and the game is about to
%% end in the same command.
apply_event(State, #{event_type := <<"clock_flagged_v1">>} = Event) ->
    Data = event_data(Event),
    State#game_state{
        clocks = maps:get(clocks, Data, State#game_state.clocks),
        status = maps:get(status, Data, State#game_state.status),
        flagged_node_id = maps:get(player_node_id, Data, <<>>),
        at_ms = maps:get(at_ms, Data, State#game_state.at_ms)};
apply_event(State, #{event_type := <<"game_ended_v1">>} = Event) ->
    Data = event_data(Event),
    State#game_state{
        position = maps:get(fen_after, Data, State#game_state.position),
        ply = maps:get(ply, Data, State#game_state.ply),
        clocks = maps:get(clocks, Data, State#game_state.clocks),
        status = maps:get(status, Data),
        outcome = maps:get(outcome, Data),
        winner_node_id = maps:get(winner_node_id, Data, <<>>),
        end_reason = maps:get(reason, Data),
        at_ms = maps:get(at_ms, Data, State#game_state.at_ms)};
apply_event(State, #{event_type := <<"game_archived_v1">>} = Event) ->
    Data = event_data(Event),
    State#game_state{status = maps:get(status, Data),
                     at_ms = maps:get(at_ms, Data, State#game_state.at_ms)};
apply_event(State, _Event) ->
    State.

%% @doc The clocks after this player's turn ends at `At'.
%%
%% The turn began at the state's own `at_ms' (the last event that changed the
%% game), so the elapsed time is deducible from the record rather than read from
%% a wall clock. `ExtraMs' is what the turn earned: the time control's increment
%% when a move completed, and 0 when the turn ended without one (a resignation),
%% because an increment is paid for a move.
%%
%% A player whose time ran out is recorded at zero rather than gaining an
%% increment for a turn that had already flagged.
-spec charge_turn(t(), white | black, non_neg_integer(), non_neg_integer()) -> map().
charge_turn(State, Colour, At, ExtraMs) ->
    Clocks = clocks(State),
    charged(remaining_ms(State, Colour, At), ExtraMs, Clocks, Colour).

%% @doc What is left on this player's clock at `At', which may be negative.
%%
%% The turn began at the state's own `at_ms' (the last event that changed the
%% game), so the elapsed time is deducible from the record rather than read from
%% a wall clock. One definition, because two callers need the same number: the
%% charge a turn pays, and the check that refuses a move played on a clock that
%% has already run out (the clock flag's counterpart, mcl-chess#2 WP6).
-spec remaining_ms(t(), white | black, non_neg_integer()) -> integer().
remaining_ms(State, Colour, At) ->
    maps:get(Colour, clocks(State)) - elapsed(State, At).

%% @doc Whether this player's clock has run out at `At'. Zero is out: a turn
%% that has used exactly its last millisecond has nothing left to play with.
-spec expired(t(), white | black, non_neg_integer()) -> boolean().
expired(State, Colour, At) ->
    remaining_ms(State, Colour, At) =< 0.

elapsed(State, At) ->
    max(0, At - at_ms(State)).

charged(Left, _ExtraMs, Clocks, Colour) when Left =< 0 ->
    Clocks#{Colour => 0};
charged(Left, ExtraMs, Clocks, Colour) ->
    Clocks#{Colour => Left + ExtraMs}.

%% @doc The repetition history after a move.
%%
%% An irreversible move (a pawn move or a capture, the same moves that reset
%% the counter) makes every earlier position unreachable, so the history starts
%% again from this one: fivefold repetition can never look past it. One
%% definition, used by the fold and by the move desk that writes the event.
-spec advance_hashes([non_neg_integer()], non_neg_integer(), non_neg_integer()) ->
          [non_neg_integer()].
advance_hashes(_History, 0, Hash) -> [Hash];
advance_hashes(History, _HalfmoveClock, Hash) -> [Hash | History].

%% @doc How many times this hash occurs in a history.
-spec occurrences([non_neg_integer()], non_neg_integer()) -> non_neg_integer().
occurrences(History, Hash) -> length([H || H <- History, H =:= Hash]).

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
      halfmove_clock => State#game_state.halfmove_clock,
      hashes => State#game_state.hashes,
      status => State#game_state.status,
      outcome => State#game_state.outcome,
      winner_node_id => State#game_state.winner_node_id,
      end_reason => State#game_state.end_reason,
      initiator_node_id => State#game_state.initiator_node_id,
      flagged_node_id => State#game_state.flagged_node_id,
      refusals => State#game_state.refusals,
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
        halfmove_clock = maps:get(halfmove_clock, Map, 0),
        hashes = maps:get(hashes, Map, []),
        status = maps:get(status, Map),
        outcome = maps:get(outcome, Map, none),
        winner_node_id = maps:get(winner_node_id, Map, <<>>),
        end_reason = maps:get(end_reason, Map, none),
        initiator_node_id = maps:get(initiator_node_id, Map, <<>>),
        %% Defaulted for the same reason as `refusals': a snapshot written
        %% before the clock existed still restores, and a state that forgot a
        %% flag would let the same player be flagged twice.
        flagged_node_id = maps:get(flagged_node_id, Map, <<>>),
        %% Defaulted, so a snapshot written before this field existed still
        %% restores: an aggregate that forgot the count would start recording
        %% again from zero.
        refusals = maps:get(refusals, Map, #{}),
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
      <<"halfmove_clock">> => State#game_state.halfmove_clock,
      <<"repetitions">> => repetition_count(State),
      <<"outcome">> => atom_to_binary(State#game_state.outcome, utf8),
      <<"winner">> => State#game_state.winner_node_id,
      <<"end_reason">> => atom_to_binary(State#game_state.end_reason, utf8),
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

-spec at_ms(t()) -> non_neg_integer().
at_ms(#game_state{at_ms = At}) -> At.

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

%% @doc The referee's own halfmove count: the FEN's field cannot carry the
%% number the 75 move rule needs.
-spec halfmove_clock(t()) -> non_neg_integer().
halfmove_clock(#game_state{halfmove_clock = Clock}) -> Clock.

%% @doc The hash of the position the game stands in now, or 0 before the game
%% started and no position has been recorded.
-spec position_hash(t()) -> non_neg_integer().
position_hash(#game_state{hashes = []}) -> 0;
position_hash(#game_state{hashes = [Hash | _]}) -> Hash.

%% @doc Every position hash recorded since the last irreversible move, newest
%% first. Trimmed rather than grown for the length of a game.
-spec hash_history(t()) -> [non_neg_integer()].
hash_history(#game_state{hashes = Hashes}) -> Hashes.

%% @doc How many times the current position has occurred. Five is the
%% automatic draw (mcl-chess#4); three stays a v2 claim.
-spec repetition_count(t()) -> non_neg_integer().
repetition_count(#game_state{} = State) ->
    occurrences(hash_history(State), position_hash(State)).

-spec outcome(t()) -> none | winner | draw | forfeit | abandoned.
outcome(#game_state{outcome = Outcome}) -> Outcome.

-spec winner_node_id(t()) -> binary().
winner_node_id(#game_state{winner_node_id = Winner}) -> Winner.

-spec end_reason(t()) -> atom().
end_reason(#game_state{end_reason = Reason}) -> Reason.

%% @doc The player whose clock ran out, or the empty binary when none did.
-spec flagged_node_id(t()) -> binary().
flagged_node_id(#game_state{flagged_node_id = NodeId}) -> NodeId.

%% @doc How many occurrences of one position end a game automatically: the
%% fivefold draw, the one automatic draw the rules engine cannot see because it
%% is not a function of one position.
-spec repetition_draw() -> non_neg_integer().
repetition_draw() -> ?FIVEFOLD_REPETITION.

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

%% @doc The colour this node holds, or `undefined' when it holds none. One
%% definition, used by every desk that has to know which side its caller is on.
-spec colour_of(t(), binary()) -> white | black | undefined.
colour_of(#game_state{seats = Seats}, NodeId) ->
    held(NodeId, Seats).

held(Caller, #{white := Caller}) -> white;
held(Caller, #{black := Caller}) -> black;
held(_Caller, _Seats) -> undefined.

%% @doc The wire's colour text (`<<"w">>'/`<<"b">>') as the aggregate's key.
-spec colour_key(binary()) -> white | black | invalid.
colour_key(<<"w">>) -> white;
colour_key(<<"b">>) -> black;
colour_key(_) -> invalid.

%% @doc The aggregate's colour key as the wire's text.
-spec colour_wire(white | black) -> binary().
colour_wire(white) -> <<"w">>;
colour_wire(black) -> <<"b">>.

%% @doc Count one recorded refusal by this player.
-spec record_refusal(t(), binary()) -> t().
record_refusal(#game_state{refusals = Refusals} = State, NodeId) ->
    State#game_state{refusals = Refusals#{NodeId => refusal_count(State, NodeId) + 1}}.

%% @doc How many refusals by this player this game has recorded.
-spec refusal_count(t(), binary()) -> non_neg_integer().
refusal_count(#game_state{refusals = Refusals}, NodeId) ->
    maps:get(NodeId, Refusals, 0).

%% @doc Whether another refusal by this player is still worth recording. Past
%% the cap the caller is refused exactly as before, and nothing is written:
%% the answer does not change, only the evidence, which is what keeps one
%% stranger from growing a game's stream for as long as it lives.
-spec may_record_refusal(t(), binary()) -> boolean().
may_record_refusal(State, NodeId) ->
    refusal_count(State, NodeId) < max_recorded_refusals().

-spec max_recorded_refusals() -> non_neg_integer().
max_recorded_refusals() -> ?MAX_RECORDED_REFUSALS.

-spec is_archived(t()) -> boolean().
is_archived(#game_state{status = Status}) -> evoq_bit_flags:has(Status, ?GAME_ARCHIVED).

-spec is_initiated(t()) -> boolean().
is_initiated(#game_state{status = Status}) ->
    evoq_bit_flags:has(Status, ?GAME_INITIATED).

-spec is_started(t()) -> boolean().
is_started(#game_state{status = Status}) -> evoq_bit_flags:has(Status, ?GAME_STARTED).

-spec is_ended(t()) -> boolean().
is_ended(#game_state{status = Status}) -> evoq_bit_flags:has(Status, ?GAME_ENDED).

-spec is_unstarted(t()) -> boolean().
is_unstarted(State) -> not is_started(State).

%% @private A stored envelope carries its business fields under `data'; a
%% freshly executed event carries them inline.
event_data(#{data := Data}) when is_map(Data) -> Data;
event_data(Event) -> Event.
