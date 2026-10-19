%% @doc Handler for `resign_game_v1': a seat holder forfeits, and the game ends.
%%
%% The slices are a strict order (mcl-chess#1): an end needs a started game, so
%% a resign on a game nobody started is refused (`not_started'), and a game ends
%% once, so a second end is `already_ended' rather than a rewritten outcome.
%%
%% NOTHING HERE IS RECORDED AS EVIDENCE, unlike a refused move. A resignation
%% is a lawful act, and the refusals around it (no seat, nothing to resign, the
%% game already over) say nothing about anybody's conduct. The one recorded
%% refusal class in this division is an attempt to move that the rules forbid.
-module(maybe_resign_game).

-export([handle_from_map/2, handle/2, dispatch/1]).

-spec handle_from_map(term(), map()) -> {ok, [map()]} | {error, term()}.
handle_from_map(State, #{command_type := resign_game_v1} = Payload) ->
    handled(State, resign_game_v1:from_map(Payload));
handle_from_map(_State, _) ->
    {error, unknown_command}.

handled(State, {ok, Cmd}) -> handle(State, Cmd);
handled(_State, {error, _} = Error) -> Error.

-spec handle(game_state:t(), resign_game_v1:t()) ->
    {ok, [map()]} | {error, term()}.
handle(State, Cmd) ->
    Caller = resign_game_v1:get_caller(Cmd),
    decided(standing(State), State, Cmd, Caller).

standing(State) ->
    checks(game_state:is_archived(State), game_state:is_initiated(State)).

checks(true, _Initiated) -> {error, game_archived};
checks(false, true) -> ok;
checks(false, false) -> {error, not_initiated}.

decided({error, _} = Refusal, _State, _Cmd, _Caller) ->
    Refusal;
decided(ok, State, Cmd, Caller) ->
    unended(game_state:is_ended(State), State, Cmd, Caller).

%% Ended before started: ending clears STARTED, so asking the start first would
%% answer "not started" to a game that is over, and the caller who ended it
%% would read that as a fault in the referee.
unended(true, _State, _Cmd, _Caller) ->
    {error, already_ended};
unended(false, State, Cmd, Caller) ->
    playing(game_state:is_started(State), State, Cmd, Caller).

playing(false, _State, _Cmd, _Caller) ->
    {error, not_started};
playing(true, State, Cmd, Caller) ->
    seated(game_state:is_seated(State, Caller), State, Cmd, Caller).

seated(false, _State, _Cmd, _Caller) ->
    {error, not_a_player};
seated(true, State, Cmd, Caller) ->
    events(State, Cmd, Caller).

events(State, Cmd, Caller) ->
    Colour = colour_of(State, Caller),
    {ok, Event} = game_ended_v1:new(#{
        game_id => resign_game_v1:get_game_id(Cmd),
        outcome => forfeit,
        winner_node_id => game_state:seat(State, other(Colour)),
        reason => resignation,
        fen_after => game_state:position(State),
        ply => game_state:ply(State),
        %% The resigner's clock is charged to the moment of resignation and the
        %% increment is not paid, because no move was made.
        clocks => game_state:charge_turn(State, Colour,
                                         erlang:system_time(millisecond), 0),
        status => game_status:ended_from(game_state:status(State))}),
    {ok, [game_ended_v1:to_map(Event)]}.

other(white) -> black;
other(black) -> white.

%% The colour this caller holds. `is_seated/2' has already established that it
%% holds one, so the two clauses are exhaustive on this path.
colour_of(State, Caller) ->
    held(Caller, game_state:seats(State)).

held(Caller, #{white := Caller}) -> white;
held(Caller, #{black := Caller}) -> black.

%% @doc Resign and hand the caller the state it produced.
-spec dispatch(resign_game_v1:t()) ->
    {ok, non_neg_integer(), [map()], map()} | {error, term()}.
dispatch(Cmd) ->
    case resign_game_v1:validate(Cmd) of
        ok -> do_dispatch(Cmd);
        {error, Reason} -> {error, Reason}
    end.

do_dispatch(Cmd) ->
    EvoqCmd = evoq_command:new(resign_game_v1, game_aggregate,
                               resign_game_v1:stream_id(Cmd),
                               resign_game_v1:to_map(Cmd),
                               #{timestamp => erlang:system_time(millisecond)}),
    case evoq_command_router:dispatch_with_state(
           EvoqCmd, #{store_id => mcl_chess_store, consistency => eventual}) of
        {ok, Version, Events, State} ->
            {ok, Version, Events, game_state:to_wire(State)};
        {error, _} = Error ->
            Error
    end.
