%% @doc Handler for `submit_move_v1': a seat holder plays the move it is to play.
%%
%% The rules, in the order they are checked, and which of them leaves evidence:
%%
%% - an archived game is dead (`game_archived') and a game that was never
%%   initiated has no stream to grow (`not_initiated'): neither records
%%   anything, because a caller with no standing must not write to a game
%% - a game that has not started has no turn to take (`not_started'), and a
%%   caller holding no seat is `not_a_player': no turn was taken, so nothing is
%%   recorded
%% - FROM HERE THE CALLER IS IN THE GAME, so every refusal is evidence and is
%%   written, up to the one cap `game_state' keeps: a move after the game ended
%%   (`game_ended'), a move out of turn (`out_of_turn'), and a move the position
%%   does not allow (`illegal_move'/`invalid_move')
%% - the caller can never be the wrong player by payload: the caller IS the
%%   node macula verified, and the colour it holds is read from the seats map
%%
%% A refusal is still a refusal to the caller: `submit_move_api' answers
%% `{error, Reason}' whether the refusal was recorded or not. The event is the
%% evidence, the answer is the answer.
%%
%% `invalid_fen' is the one refusal that is NOT the caller's: it can only come
%% from the position this service recorded, so it is answered and logged and
%% blamed on nobody.
-module(maybe_submit_move).

-export([handle_from_map/2, handle/2, dispatch/1]).

-spec handle_from_map(term(), map()) -> {ok, [map()]} | {error, term()}.
handle_from_map(State, #{command_type := submit_move_v1} = Payload) ->
    handled(State, submit_move_v1:from_map(Payload));
handle_from_map(_State, _) ->
    {error, unknown_command}.

handled(State, {ok, Cmd}) -> handle(State, Cmd);
handled(_State, {error, _} = Error) -> Error.

-spec handle(game_state:t(), submit_move_v1:t()) ->
    {ok, [map()]} | {error, term()}.
handle(State, Cmd) ->
    Caller = submit_move_v1:get_caller(Cmd),
    %% One reading of the service clock for the whole command: the event's
    %% `at_ms', the time charged to the mover and the moment the turn started
    %% are all the same instant, and the event records what was computed.
    At = erlang:system_time(millisecond),
    decided(standing(State), State, Cmd, Caller, At).

standing(State) ->
    checks(game_state:is_archived(State), game_state:is_initiated(State)).

checks(true, _Initiated) -> {error, game_archived};
checks(false, true) -> ok;
checks(false, false) -> {error, not_initiated}.

decided({error, _} = Refusal, _State, _Cmd, _Caller, _At) ->
    Refusal;
decided(ok, State, Cmd, Caller, At) ->
    seated(game_state:is_seated(State, Caller), State, Cmd, Caller, At).

seated(false, _State, _Cmd, _Caller, _At) ->
    {error, not_a_player};
seated(true, State, Cmd, Caller, At) ->
    %% The end is asked before the start, because ending clears STARTED: an
    %% ended game is not "not started", it is over, and that is the refusal a
    %% seat holder who keeps moving is answered with.
    live(game_state:is_ended(State), State, Cmd, Caller, At).

live(true, State, Cmd, Caller, At) ->
    refused(game_ended, State, Cmd, Caller, At);
live(false, State, Cmd, Caller, At) ->
    playing(game_state:is_started(State), State, Cmd, Caller, At).

playing(false, _State, _Cmd, _Caller, _At) ->
    {error, not_started};
playing(true, State, Cmd, Caller, At) ->
    turn(colour_of(State, Caller), State, Cmd, Caller, At).

turn(Colour, State, Cmd, Caller, At) ->
    theirs(its_turn(Colour, State), Colour, State, Cmd, Caller, At).

its_turn(Colour, State) ->
    game_state:colour_wire(Colour) =:= game_state:to_move(State).

theirs(false, _Colour, State, Cmd, Caller, At) ->
    refused(out_of_turn, State, Cmd, Caller, At);
theirs(true, Colour, State, Cmd, Caller, At) ->
    played(Colour, State, Cmd, Caller, At).

played(Colour, State, Cmd, Caller, At) ->
    applied(mcl_chess_rules:apply_move(game_state:position(State),
                                       submit_move_v1:get_move(Cmd)),
            Colour, State, Cmd, Caller, At).

applied({error, invalid_fen}, _Colour, _State, _Cmd, _Caller, _At) ->
    {error, invalid_fen};
applied({error, Reason}, _Colour, State, Cmd, Caller, At) ->
    refused(Reason, State, Cmd, Caller, At);
applied({ok, FenAfter, Hash, Resets}, Colour, State, Cmd, Caller, At) ->
    moved(FenAfter, Hash, Resets, Colour, State, Cmd, Caller, At).

moved(FenAfter, Hash, Resets, Colour, State, Cmd, Caller, At) ->
    Clock = advance_clock(Resets, State),
    History = game_state:advance_hashes(game_state:hash_history(State), Clock, Hash),
    {ok, Event} = move_played_v1:new(#{
        game_id => submit_move_v1:get_game_id(Cmd),
        player_node_id => Caller,
        move => submit_move_v1:get_move(Cmd),
        ply => game_state:ply(State) + 1,
        fen_after => FenAfter,
        position_hash => Hash,
        halfmove_clock => Clock,
        repetitions => game_state:occurrences(History, Hash),
        to_move => game_state:colour_wire(other(Colour)),
        clocks => game_state:charge_turn(State, Colour, At, increment(State)),
        status => game_state:status(State),
        at_ms => At}),
    {ok, [move_played_v1:to_map(Event)]}.

other(white) -> black;
other(black) -> white.

%% The referee's own count: a pawn move or a capture starts it again.
advance_clock(1, _State) -> 0;
advance_clock(0, State) -> game_state:halfmove_clock(State) + 1.

%% THE MOVER'S CLOCK, charged here because the move event is the only place it
%% is written: the turn is over and the mover pays for it. The arithmetic is the
%% state's (`charge_turn'), so a resignation and a move cannot disagree about
%% what a turn costs. The clock instance (WP6) reads this event to schedule the
%% next deadline; it does not re-derive the numbers.
increment(State) ->
    {_Initial, Increment} = game_state:time_control(State),
    Increment.

%% A refusal from a player who is in the game: recorded up to the cap the one
%% counter keeps, answered either way.
refused(Reason, State, Cmd, Caller, At) ->
    capped(Reason, game_state:may_record_refusal(State, Caller),
           State, Cmd, Caller, At).

capped(Reason, false, _State, _Cmd, _Caller, _At) ->
    {error, Reason};
capped(Reason, true, State, Cmd, Caller, At) ->
    {ok, Event} = move_refused_v1:new(#{
        game_id => submit_move_v1:get_game_id(Cmd),
        player_node_id => Caller,
        move => submit_move_v1:get_move(Cmd),
        reason => Reason,
        ply => game_state:ply(State),
        fen_after => game_state:position(State),
        clocks => game_state:clocks(State),
        status => game_state:status(State),
        at_ms => At}),
    {ok, [move_refused_v1:to_map(Event)]}.

%% The colour this caller holds. `is_seated/2' has already established that it
%% holds one, so the two clauses are exhaustive on this path.
colour_of(State, Caller) ->
    held(Caller, game_state:seats(State)).

held(Caller, #{white := Caller}) -> white;
held(Caller, #{black := Caller}) -> black.

%% @doc Play the move and hand the caller the state it produced.
-spec dispatch(submit_move_v1:t()) ->
    {ok, non_neg_integer(), [map()], map()} | {error, term()}.
dispatch(Cmd) ->
    case submit_move_v1:validate(Cmd) of
        ok -> do_dispatch(Cmd);
        {error, Reason} -> {error, Reason}
    end.

do_dispatch(Cmd) ->
    EvoqCmd = evoq_command:new(submit_move_v1, game_aggregate,
                               submit_move_v1:stream_id(Cmd),
                               submit_move_v1:to_map(Cmd),
                               #{timestamp => erlang:system_time(millisecond)}),
    case evoq_command_router:dispatch_with_state(
           EvoqCmd, #{store_id => mcl_chess_store, consistency => eventual}) of
        {ok, Version, Events, State} ->
            {ok, Version, Events, game_state:to_wire(State)};
        {error, _} = Error ->
            Error
    end.
