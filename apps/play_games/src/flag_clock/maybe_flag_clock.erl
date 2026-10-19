%% @doc Handler for `flag_clock_v1': a clock that ran out ends the game.
%%
%% The rules, in the order they are checked. The first four are the same
%% standing checks every desk makes, and none of them records anything: a
%% cmd from a game that is dead, unstarted or over is a stale deadline, not a
%% player's conduct.
%%
%% - archived (`game_archived'), never initiated (`not_initiated'): refused
%% - over (`game_ended') or not started (`not_started'): refused
%% - a player who holds no seat is `not_a_player', and it is not that player's
%%   turn (`not_the_flagged_turn'): a deadline belongs to the side to move, so a
%%   stale message that names the other colour is refused rather than recorded
%% - flagged already (`already_flagged'): the same player is not flagged twice
%% - their clock is not out (`clock_not_expired'): the deadline fired before the
%%   move that bought time was folded, and the move wins
%%
%% The flag records ONE event and the policy that follows it ends the game
%% (`on_clock_flagged_v1_maybe_end_game', then `end_game_v1'). The crash window
%% that opens between the two is closed inside the game's clock instance, which
%% catches up on a flag with no end when it is rebuilt (see `game_clock_pm').
%%
%% The flag does NOT decide the outcome: `end_game_v1' asks the rules about the
%% position before it forfeits, so a game left `started' by a crash between a
%% mating move and the end policy's dispatch ends as a checkmate rather than as
%% a loss on time.
-module(maybe_flag_clock).

-export([handle_from_map/2, handle/2, dispatch/1]).

-spec handle_from_map(term(), map()) -> {ok, [map()]} | {error, term()}.
handle_from_map(State, #{command_type := flag_clock_v1} = Payload) ->
    handled(State, flag_clock_v1:from_map(Payload));
handle_from_map(_State, _) ->
    {error, unknown_command}.

handled(State, {ok, Cmd}) -> handle(State, Cmd);
handled(_State, {error, _} = Error) -> Error.

-spec handle(game_state:t(), flag_clock_v1:t()) -> {ok, [map()]} | {error, term()}.
handle(State, Cmd) ->
    %% One reading of the service clock for the whole command: the flag's
    %% `at_ms', the clock it charges and the moment the game ended are the same
    %% instant, and both events record it.
    At = erlang:system_time(millisecond),
    decided(standing(State), State, Cmd, At).

standing(State) ->
    checks(game_state:is_archived(State), game_state:is_initiated(State)).

checks(true, _Initiated) -> {error, game_archived};
checks(false, true) -> ok;
checks(false, false) -> {error, not_initiated}.

decided({error, _} = Refusal, _State, _Cmd, _At) ->
    Refusal;
decided(ok, State, Cmd, At) ->
    unended(game_state:is_ended(State), State, Cmd, At).

%% Ended before started: ending clears STARTED, so asking the start first would
%% answer "not started" to a game that is over.
unended(true, _State, _Cmd, _At) ->
    {error, game_ended};
unended(false, State, Cmd, At) ->
    playing(game_state:is_started(State), State, Cmd, At).

playing(false, _State, _Cmd, _At) ->
    {error, not_started};
playing(true, State, Cmd, At) ->
    seated(game_state:colour_of(State, flag_clock_v1:get_player_node_id(Cmd)),
           State, Cmd, At).

seated(undefined, _State, _Cmd, _At) ->
    {error, not_a_player};
seated(Colour, State, Cmd, At) ->
    theirs(its_turn(Colour, State), Colour, State, Cmd, At).

its_turn(Colour, State) ->
    game_state:colour_wire(Colour) =:= game_state:to_move(State).

theirs(false, _Colour, _State, _Cmd, _At) ->
    {error, not_the_flagged_turn};
theirs(true, Colour, State, Cmd, At) ->
    twice(flagged_already(State, Cmd), Colour, State, Cmd, At).

flagged_already(State, Cmd) ->
    game_state:flagged_node_id(State) =:= flag_clock_v1:get_player_node_id(Cmd).

twice(true, _Colour, _State, _Cmd, _At) ->
    {error, already_flagged};
twice(false, Colour, State, Cmd, At) ->
    out(game_state:expired(State, Colour, At), Colour, State, Cmd, At).

out(false, _Colour, _State, _Cmd, _At) ->
    {error, clock_not_expired};
out(true, _Colour, State, Cmd, At) ->
    events(State, Cmd, At).

%% The flagged player's clock is at zero and the opponent's is what it was,
%% because a clock that is not running is not charged.
events(State, Cmd, At) ->
    Player = flag_clock_v1:get_player_node_id(Cmd),
    Clocks = game_state:charge_turn(State, game_state:colour_of(State, Player), At, 0),
    {ok, Flag} = clock_flagged_v1:new(#{
        game_id => flag_clock_v1:get_game_id(Cmd),
        player_node_id => Player,
        clocks => Clocks,
        status => game_state:status(State),
        at_ms => At}),
    {ok, [clock_flagged_v1:to_map(Flag)]}.

%% @doc Flag the player and hand the caller the state it produced.
-spec dispatch(flag_clock_v1:t()) ->
    {ok, non_neg_integer(), [map()], map()} | {error, term()}.
dispatch(Cmd) ->
    case flag_clock_v1:validate(Cmd) of
        ok -> do_dispatch(Cmd);
        {error, Reason} -> {error, Reason}
    end.

do_dispatch(Cmd) ->
    EvoqCmd = evoq_command:new(flag_clock_v1, game_aggregate,
                               flag_clock_v1:stream_id(Cmd),
                               flag_clock_v1:to_map(Cmd),
                               #{timestamp => erlang:system_time(millisecond)}),
    case evoq_command_router:dispatch_with_state(
           EvoqCmd, #{store_id => mcl_chess_store, consistency => eventual}) of
        {ok, Version, Events, State} ->
            {ok, Version, Events, game_state:to_wire(State)};
        {error, _} = Error ->
            Error
    end.
