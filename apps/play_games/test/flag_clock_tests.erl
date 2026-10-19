%% @doc The flag slice, and the end it leads to: a clock that ran out.
%%
%% The desks are pinned against a state built by hand rather than against a live
%% clock: a test that sleeps for a second to watch a clock run out is a test that
%% fails on a busy machine, and what has to be right here is arithmetic on the
%% events' own `at_ms', not the wall clock. The timer that dispatches the flag is
%% pinned in `game_clock_pm_tests', and the whole chain - timer, flag, policy,
%% end, projection, fact - in the facade's `clock_and_retention_tests'.
%%
%% What this pins: the flag records who ran out and the clocks, and nothing else
%% (the end is a policy's command, not part of the flag); the end that follows a
%% flag re-judges the position, so a live position is a loss on time and the mate
%% a crash left unrecorded is a checkmate; and every stale or unlawful deadline is
%% refused without recording anything.
-module(flag_clock_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("reckon_gater/include/reckon_gater_types.hrl").

-define(ALICE, <<"a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90">>).
-define(BOB, <<"b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1">>).
-define(CAROL, <<"c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2">>).
-define(GAME, <<"game-01a155d187887b2d9828309b42952c86">>).
-define(START, <<"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1">>).
%% Fool's mate: black has mated, and it is white (the mated side) to move.
-define(FOOLS_MATE, <<"rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3">>).
%% White to move, holding a queen; black has a bare king and cannot mate (FIDE 6.9).
-define(QUEEN_AGAINST_A_BARE_KING, <<"7k/8/8/8/8/8/6Q1/6K1 w - - 0 1">>).
%% White to move, a pawn against black's lone knight: black can mate with white's
%% own pawn blocking a flight square, so a flag here is a loss.
-define(KNIGHT_AGAINST_A_PAWN, <<"4kn2/8/8/8/8/8/4P3/4K3 w - - 0 1">>).

desk_test_() ->
    [{timeout, 30, fun a_flag_records_who_ran_out/0},
     {timeout, 30, fun the_flag_is_one_event_and_the_end_is_another/0},
     {timeout, 30, fun a_flag_ends_a_live_game_as_a_forfeit/0},
     {timeout, 30, fun a_flag_on_a_mated_game_ends_as_a_checkmate/0},
     {timeout, 30, fun a_flag_against_an_opponent_who_cannot_mate_is_a_draw/0},
     {timeout, 30, fun a_lone_minor_piece_still_wins_when_it_has_a_blocker/0},
     {timeout, 30, fun only_a_flag_is_re_judged/0},
     {timeout, 30, fun a_flag_refuses_a_clock_that_has_not_run_out/0},
     {timeout, 30, fun a_flag_refuses_the_wrong_turn/0},
     {timeout, 30, fun a_flag_refuses_a_stranger/0},
     {timeout, 30, fun a_flag_refuses_a_game_that_never_started/0},
     {timeout, 30, fun a_flag_refuses_a_game_that_has_ended/0},
     {timeout, 30, fun a_flag_refuses_a_game_that_is_archived/0},
     {timeout, 30, fun the_same_player_is_not_flagged_twice/0}].

a_flag_records_who_ran_out() ->
    %% White's clock ran out 2 s into a 1 s control: the flagged player's clock
    %% is at zero, the opponent's is untouched, and the game is still `started'
    %% - the flag is a fact about the clock, not the end.
    State = started(now_ms() - 2000, #{white => 1000, black => 60000}),
    {ok, [Flag]} = flag(State, ?ALICE),
    ?assertEqual(<<"clock_flagged_v1">>, maps:get(event_type, Flag)),
    ?assertEqual(?ALICE, maps:get(player_node_id, Flag)),
    ?assertEqual(#{white => 0, black => 60000}, maps:get(clocks, Flag)),
    ?assertEqual(5, maps:get(status, Flag)),
    ?assert(is_integer(maps:get(at_ms, Flag))).

the_flag_is_one_event_and_the_end_is_another() ->
    %% The end is `on_clock_flagged_v1_maybe_end_game' dispatching end_game_v1:
    %% two commands, so the record shows the flag and the end separately and a
    %% reader can tell a loss on time from any other forfeit.
    State = started(now_ms() - 2000, #{white => 1000, black => 1000}),
    {ok, [Flag]} = flag(State, ?ALICE),
    ?assertEqual(<<"clock_flagged_v1">>, maps:get(event_type, Flag)),
    ?assertEqual(1, length(element(2, flag(State, ?ALICE)))).

a_flag_ends_a_live_game_as_a_forfeit() ->
    %% What the policy's end command produces on a game whose clock ran out: the
    %% flagged player lost on time, and the opponent is named from the record.
    State = flagged(started(now_ms() - 2000, #{white => 1000, black => 1000})),
    {ok, [Ended]} = end_flag(State),
    ?assertEqual(<<"game_ended_v1">>, maps:get(event_type, Ended)),
    ?assertEqual(forfeit, maps:get(outcome, Ended)),
    ?assertEqual(clock_flag, maps:get(reason, Ended)),
    ?assertEqual(?BOB, maps:get(winner_node_id, Ended)),
    %% Ending clears STARTED and sets ENDED, exactly as every other end does.
    ?assertEqual(9, maps:get(status, Ended)),
    %% The position stands: a flag is not a move.
    ?assertEqual(?START, maps:get(fen_after, Ended)),
    ?assertEqual(0, maps:get(ply, Ended)).

a_flag_on_a_mated_game_ends_as_a_checkmate() ->
    %% THE MATE A CRASH LEFT UNRECORDED. A game left `started' by a crash between
    %% a mating move and the end policy's dispatch reaches the end through the
    %% flag, and the position outranks a loss on time: forfeiting it would record
    %% the wrong reason for the whole game.
    State = flagged(mated(now_ms() - 2000)),
    {ok, [Ended]} = end_flag(State),
    ?assertEqual(winner, maps:get(outcome, Ended)),
    ?assertEqual(checkmate, maps:get(reason, Ended)),
    ?assertEqual(?BOB, maps:get(winner_node_id, Ended)).

%% FIDE 6.9 (mcl-chess#6): a flag is only a loss when the side that would be
%% credited with the win can mate at all. White's clock ran out holding a queen
%% and black has a bare king, so black cannot checkmate by any series of legal
%% moves and the game is drawn. The queen belongs to the side that ran out and
%% does not help it.
a_flag_against_an_opponent_who_cannot_mate_is_a_draw() ->
    State = flagged(started_in(?QUEEN_AGAINST_A_BARE_KING, now_ms() - 2000)),
    {ok, [Ended]} = end_flag(State),
    ?assertEqual(<<"game_ended_v1">>, maps:get(event_type, Ended)),
    ?assertEqual(draw, maps:get(outcome, Ended)),
    ?assertEqual(clock_flag_insufficient_material, maps:get(reason, Ended)),
    ?assertEqual(<<>>, maps:get(winner_node_id, Ended)),
    %% An end is an end whatever the outcome: STARTED cleared, ENDED set.
    ?assertEqual(9, maps:get(status, Ended)).

%% The other half of 6.9: "any possible series of legal moves" counts the flagged
%% player's own moves, so black's lone knight can mate once white's pawn is there
%% to block a flight square. That flag stands as a loss.
a_lone_minor_piece_still_wins_when_it_has_a_blocker() ->
    State = flagged(started_in(?KNIGHT_AGAINST_A_PAWN, now_ms() - 2000)),
    {ok, [Ended]} = end_flag(State),
    ?assertEqual(forfeit, maps:get(outcome, Ended)),
    ?assertEqual(clock_flag, maps:get(reason, Ended)),
    ?assertEqual(?BOB, maps:get(winner_node_id, Ended)).

only_a_flag_is_re_judged() ->
    %% A resignation in a decided position keeps its own reason: what happened
    %% first is what the record says.
    State = mated(now_ms() - 2000),
    {ok, [Ended]} = end_with(State, #{outcome => forfeit, winner_node_id => ?BOB,
                                      reason => resignation}),
    ?assertEqual(resignation, maps:get(reason, Ended)),
    ?assertEqual(?BOB, maps:get(winner_node_id, Ended)).

a_flag_refuses_a_clock_that_has_not_run_out() ->
    %% The deadline fired a moment before the move that bought time was folded:
    %% the move wins, and nothing is recorded.
    State = started(now_ms(), #{white => 60000, black => 60000}),
    ?assertEqual({error, clock_not_expired}, flag(State, ?ALICE)).

a_flag_refuses_the_wrong_turn() ->
    %% It is white's turn, so a deadline naming black is stale by one move.
    State = started(now_ms() - 2000, #{white => 1000, black => 1000}),
    ?assertEqual({error, not_the_flagged_turn}, flag(State, ?BOB)).

a_flag_refuses_a_stranger() ->
    State = started(now_ms() - 2000, #{white => 1000, black => 1000}),
    ?assertEqual({error, not_a_player}, flag(State, ?CAROL)).

a_flag_refuses_a_game_that_never_started() ->
    State = seated(now_ms() - 2000),
    ?assertEqual({error, not_started}, flag(State, ?ALICE)).

a_flag_refuses_a_game_that_has_ended() ->
    State = game_state:apply_event(mated(now_ms() - 2000), ended_event(now_ms())),
    ?assertEqual({error, game_ended}, flag(State, ?ALICE)).

a_flag_refuses_a_game_that_is_archived() ->
    State = game_state:apply_event(mated(now_ms() - 2000), archived_event()),
    ?assertEqual({error, game_archived}, flag(State, ?ALICE)).

the_same_player_is_not_flagged_twice() ->
    %% The flag's own clocks cannot tell the two apart: an about-to-flag player
    %% is already at zero. The state remembers who was flagged.
    State = game_state:apply_event(mated(now_ms() - 2000), flagged_event(now_ms())),
    ?assertEqual({error, already_flagged}, flag(State, ?ALICE)).

%%====================================================================
%% Helpers
%%====================================================================

flag(State, NodeId) ->
    {ok, Cmd} = flag_clock_v1:new(#{game_id => ?GAME, player_node_id => NodeId}),
    maybe_flag_clock:handle(State, Cmd).

%% The policy's command, on a state where the flag is already recorded: a
%% forfeit with no winner, which is what `on_clock_flagged_v1_maybe_end_game'
%% sends.
end_flag(State) ->
    end_with(State, #{outcome => forfeit, reason => clock_flag}).

end_with(State, Decision) ->
    {ok, Cmd} = end_game_v1:new(Decision#{game_id => ?GAME}),
    maybe_end_game:handle(State, Cmd).

%% The state after `clock_flagged_v1' has been folded.
flagged(State) ->
    game_state:apply_event(State, flagged_event(now_ms())).

now_ms() -> erlang:system_time(millisecond).

%% A game that has started, whose current turn began at `StartedAt' so a clock of
%% `Clocks' has already run out when `StartedAt' is in the past.
started(StartedAt, Clocks) ->
    game_state:apply_event(seated(StartedAt), started_event(StartedAt, Clocks)).

seated(StartedAt) ->
    State1 = game_state:apply_event(game_state:new(?GAME), initiated_event(StartedAt)),
    State2 = game_state:apply_event(State1, claim_event(white, ?ALICE)),
    game_state:apply_event(State2, claim_event(black, ?BOB)).

%% The same game, in a position black has mated: white to move, and lost.
mated(StartedAt) ->
    started_in(?FOOLS_MATE, StartedAt).

%% A started game standing in `Fen', white to move, the turn begun at
%% `StartedAt' so a 1 s clock has already run out.
started_in(Fen, StartedAt) ->
    State = started(StartedAt, #{white => 1000, black => 1000}),
    game_state:apply_event(State, #{event_type => <<"move_played_v1">>,
                                    game_id => ?GAME,
                                    player_node_id => ?BOB,
                                    move => <<"d8h4">>,
                                    ply => 3,
                                    fen_after => Fen,
                                    position_hash => 4242,
                                    halfmove_clock => 1,
                                    repetitions => 1,
                                    to_move => <<"w">>,
                                    clocks => #{white => 1000, black => 1000},
                                    status => 5,
                                    at_ms => StartedAt}).

initiated_event(At) ->
    #{event_type => <<"game_initiated_v1">>,
      game_id => ?GAME,
      protocol => <<"chess">>,
      time_control => {1000, 0},
      seats => #{white => <<>>, black => <<>>},
      position => ?START,
      to_move => <<"w">>,
      ply => 0,
      clocks => #{white => 1000, black => 1000},
      status => 3,
      initiator_node_id => ?ALICE,
      at_ms => At}.

claim_event(Colour, NodeId) ->
    #{event_type => <<"seat_claimed_v1">>,
      game_id => ?GAME,
      player_node_id => NodeId,
      color => game_state:colour_wire(Colour),
      seats => seats(Colour, NodeId),
      status => 3,
      at_ms => 0}.

seats(white, NodeId) -> #{white => NodeId, black => <<>>};
seats(black, NodeId) -> #{white => ?ALICE, black => NodeId}.

started_event(At, Clocks) ->
    #{event_type => <<"game_started_v1">>,
      game_id => ?GAME,
      white_node_id => ?ALICE,
      black_node_id => ?BOB,
      position => ?START,
      position_hash => 7,
      to_move => <<"w">>,
      ply => 0,
      clocks => Clocks,
      status => 5,
      at_ms => At}.

flagged_event(At) ->
    #{event_type => <<"clock_flagged_v1">>,
      game_id => ?GAME,
      player_node_id => ?ALICE,
      clocks => #{white => 0, black => 1000},
      status => 5,
      at_ms => At}.

ended_event(At) ->
    #{event_type => <<"game_ended_v1">>,
      game_id => ?GAME,
      outcome => winner,
      winner_node_id => ?BOB,
      reason => checkmate,
      fen_after => ?FOOLS_MATE,
      ply => 3,
      clocks => #{white => 0, black => 1000},
      status => 9,
      at_ms => At}.

archived_event() ->
    #{event_type => <<"game_archived_v1">>,
      game_id => ?GAME,
      reason => <<"retention">>,
      status => 17,
      at_ms => 0}.
