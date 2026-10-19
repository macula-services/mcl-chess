%% @doc The game's clock, pinned as a state machine: deadlines in, a flag out.
%%
%% The callbacks are driven directly rather than through a running instance, so
%% the arithmetic is pinned without waiting for anything: what has to be right is
%% that the deadline is the event's own `at_ms' plus what the side to move has
%% left, and that a message for a deadline which has been replaced does nothing.
%% One test does let a real timer fire, because "the deadline was scheduled for
%% now" is only true if the message arrives.
-module(game_clock_pm_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("evoq/include/evoq.hrl").

-define(GAME, <<"game-01a155d187887b2d9828309b42952c86">>).
-define(ALICE, <<"a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90">>).
-define(BOB, <<"b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1">>).

clock_test_() ->
    [{timeout, 30, fun the_game_started_event_sets_whites_deadline/0},
     {timeout, 30, fun a_move_hands_the_deadline_to_the_other_player/0},
     {timeout, 30, fun the_end_stops_the_clock/0},
     {timeout, 30, fun the_deadline_fires_a_flag_for_the_seat_to_move/0},
     {timeout, 30, fun a_message_for_a_replaced_deadline_does_nothing/0},
     {timeout, 30, fun a_replayed_event_rebuilds_the_deadline_and_it_fires/0},
     {timeout, 30, fun routing_answers_without_a_game_id_are_false/0},
     %% The two sequences a crash can leave half done, and the catch-up that
     %% finishes them when the instance is rebuilt.
     {timeout, 30, fun a_full_game_with_no_start_is_caught_up/0},
     {timeout, 30, fun a_started_game_is_not_caught_up/0},
     {timeout, 30, fun a_flag_with_no_end_is_caught_up/0},
     {timeout, 30, fun a_game_that_ended_is_not_caught_up/0},
     {timeout, 30, fun an_archived_game_stops_the_clock/0}].

the_game_started_event_sets_whites_deadline() ->
    State = handled(started_event(1000, #{white => 60000, black => 60000})),
    ?assertEqual(61000, maps:get(deadline_ms, State)),
    ?assertEqual(white, maps:get(colour, State)),
    %% The seats are kept because the flag command names a node id, and the clock
    %% only knows colours.
    ?assertEqual(#{white => ?ALICE, black => ?BOB}, maps:get(seats, State)).

a_move_hands_the_deadline_to_the_other_player() ->
    %% White moved at 5000 with 59000 left, so black's deadline is black's own
    %% remaining time from that instant.
    State = handled(moved_event(5000, <<"b">>, #{white => 59000, black => 60000})),
    ?assertEqual(65000, maps:get(deadline_ms, State)),
    ?assertEqual(black, maps:get(colour, State)).

the_end_stops_the_clock() ->
    State = handled(moved_event(5000, <<"b">>, #{white => 59000, black => 60000})),
    Ended = handled(ended_event(6000), State),
    ?assertEqual(undefined, maps:get(deadline_ms, Ended)),
    ?assertEqual(undefined, maps:get(timer, Ended)).

the_deadline_fires_a_flag_for_the_seat_to_move() ->
    State = handled(started_event(1000, #{white => 60000, black => 60000})),
    Deadline = maps:get(deadline_ms, State),
    {noreply, Fired, [Command]} =
        game_clock_pm:handle_info({game_clock_deadline, ?GAME, Deadline, white}, State),
    ?assertMatch(#evoq_command{command_type = flag_clock_v1}, Command),
    ?assertEqual(?GAME, Command#evoq_command.aggregate_id),
    ?assertEqual(#{command_type => flag_clock_v1,
                   game_id => ?GAME,
                   player_node_id => ?ALICE}, Command#evoq_command.payload),
    %% THE DEADLINE IS KEPT AND ASKED AGAIN. A failed dispatch is only logged by
    %% evoq's PM runtime, so a cleared deadline would leave a player who is out
    %% of time in a game that never ends. The flag event is what clears it.
    ?assertEqual(Deadline, maps:get(deadline_ms, Fired)),
    ?assertNotEqual(undefined, maps:get(timer, Fired)),
    {noreply, _Again, [Retry]} =
        game_clock_pm:handle_info({game_clock_deadline, ?GAME, Deadline, white}, Fired),
    ?assertMatch(#evoq_command{command_type = flag_clock_v1}, Retry),
    %% And the event that settles it stops the clock for good.
    Settled = handled(flagged_event(3000), Fired),
    ?assertEqual(undefined, maps:get(deadline_ms, Settled)),
    ?assertEqual({noreply, Settled},
                 game_clock_pm:handle_info({game_clock_deadline, ?GAME, Deadline, white},
                                           Settled)).

a_message_for_a_replaced_deadline_does_nothing() ->
    %% The move landed and took the turn with it: the message from the earlier
    %% turn must not flag anybody.
    State = handled(moved_event(5000, <<"b">>, #{white => 59000, black => 60000})),
    ?assertEqual({noreply, State},
                 game_clock_pm:handle_info({game_clock_deadline, ?GAME, 61000, white},
                                           State)).

a_replayed_event_rebuilds_the_deadline_and_it_fires() ->
    %% A replay of a game whose clock ran out while the node was down: handle/3
    %% runs again with `replaying => true', and the deadline it rebuilds is
    %% already past, so the flag arrives without anybody waiting for it.
    Long = erlang:system_time(millisecond) - 5000,
    %% A game id of its own: the other tests in this module schedule timers that
    %% fire immediately, and only this test's mailbox should be read here.
    Replay = <<"game-01a155d187887b2d9828309b42952c87">>,
    {ok, Fresh} = game_clock_pm:init(Replay),
    {ok, State} = game_clock_pm:handle(Fresh, started_event(Replay, Long,
                                                            #{white => 1000, black => 1000}),
                                       #{replaying => true}),
    Deadline = Long + 1000,
    ?assertEqual(Deadline, maps:get(deadline_ms, State)),
    %% Matched on the deadline this test scheduled: the other tests in this
    %% module schedule timers of their own, and a receive that took the first
    %% message of any kind would be reading theirs.
    receive
        {game_clock_deadline, Replay, Fired, white} -> ?assertEqual(Deadline, Fired)
    after 1000 ->
        ?assert(false)
    end.

routing_answers_without_a_game_id_are_false() ->
    %% A crash here would silence every process manager on the node (evoq#9), so
    %% the answers are total.
    ?assertEqual(false, game_clock_pm:correlate(#{event_type => <<"move_played_v1">>,
                                                  data => #{}}, #{})),
    ?assertEqual({continue, ?GAME},
                 game_clock_pm:correlate(#{event_type => <<"move_played_v1">>,
                                           data => #{game_id => ?GAME}}, #{})),
    ?assertEqual({stop, ?GAME},
                 game_clock_pm:correlate(#{event_type => <<"game_ended_v1">>,
                                           data => #{game_id => ?GAME}}, #{})).

a_full_game_with_no_start_is_caught_up() ->
    %% The second claim landed and the node died before the seats-full policy's
    %% start: a game nobody could play, and only the initiator could clear.
    State = handled(claim_event(white, ?ALICE)),
    State2 = handled(claim_event(black, ?BOB), State),
    ?assertNotEqual(undefined, maps:get(catch_up, State2)),
    {noreply, _Cleared, [Command]} =
        game_clock_pm:handle_info({game_clock_catch_up, ?GAME}, State2),
    ?assertMatch(#evoq_command{command_type = start_game_v1}, Command),
    ?assertEqual(?GAME, Command#evoq_command.aggregate_id),
    ?assertEqual(#{command_type => start_game_v1, game_id => ?GAME},
                 Command#evoq_command.payload).

a_started_game_is_not_caught_up() ->
    %% A healthy node: the policy's start landed a moment after the claim, and by
    %% the time the catch-up fires there is nothing to do.
    State = handled(started_event(1000, #{white => 60000, black => 60000})),
    ?assertEqual(undefined, maps:get(catch_up, State)),
    ?assertEqual({noreply, State},
                 game_clock_pm:handle_info({game_clock_catch_up, ?GAME}, State)).

a_flag_with_no_end_is_caught_up() ->
    %% The clock flagged the player and the node died before the flag policy's
    %% end: the game nobody can play again, this time with a clock that ran out.
    Started = handled(started_event(1000, #{white => 60000, black => 60000})),
    Flagged = handled(flagged_event(2000), Started),
    ?assertNotEqual(undefined, maps:get(catch_up, Flagged)),
    {noreply, _Cleared, [Command]} =
        game_clock_pm:handle_info({game_clock_catch_up, ?GAME}, Flagged),
    ?assertMatch(#evoq_command{command_type = end_game_v1}, Command),
    %% The decision is the policy's: a forfeit that `end_game' re-judges against
    %% the position, and names the winner from the record.
    ?assertMatch(#{command_type := end_game_v1, game_id := ?GAME,
                   outcome := forfeit, reason := clock_flag},
                 Command#evoq_command.payload).

a_game_that_ended_is_not_caught_up() ->
    Started = handled(started_event(1000, #{white => 60000, black => 60000})),
    Flagged = handled(flagged_event(2000), Started),
    Ended = handled(ended_event(3000), Flagged),
    ?assertEqual(undefined, maps:get(catch_up, Ended)),
    ?assertEqual({noreply, Ended},
                 game_clock_pm:handle_info({game_clock_catch_up, ?GAME}, Ended)).

an_archived_game_stops_the_clock() ->
    %% An archived game is dead: no deadline, no catch-up, and no instance to
    %% route another event to.
    Started = handled(started_event(1000, #{white => 60000, black => 60000})),
    Archived = handled(#{event_type => <<"game_archived_v1">>,
                         data => #{game_id => ?GAME, reason => <<"withdrawn">>,
                                   status => 17, at_ms => 2000}}, Started),
    ?assertEqual(undefined, maps:get(timer, Archived)),
    ?assertEqual(undefined, maps:get(deadline_ms, Archived)),
    ?assertEqual({stop, ?GAME},
                 game_clock_pm:correlate(#{event_type => <<"game_archived_v1">>,
                                           data => #{game_id => ?GAME}}, #{})).

%%====================================================================
%% Helpers
%%====================================================================

handled(Event) ->
    {ok, Fresh} = game_clock_pm:init(?GAME),
    handled(Event, Fresh).

handled(Event, Before) ->
    {ok, Handled} = game_clock_pm:handle(Before, Event, #{}),
    game_clock_pm:apply(Handled, Event).

started_event(At, Clocks) ->
    started_event(?GAME, At, Clocks).

started_event(GameId, At, Clocks) ->
    #{event_type => <<"game_started_v1">>,
      data => #{game_id => GameId, white_node_id => ?ALICE, black_node_id => ?BOB,
                to_move => <<"w">>, clocks => Clocks, at_ms => At}}.

moved_event(At, ToMove, Clocks) ->
    #{event_type => <<"move_played_v1">>,
      data => #{game_id => ?GAME, player_node_id => ?ALICE, to_move => ToMove,
                clocks => Clocks, at_ms => At}}.

claim_event(white, NodeId) ->
    #{event_type => <<"seat_claimed_v1">>,
      data => #{game_id => ?GAME, player_node_id => NodeId, color => <<"w">>,
                seats => #{white => NodeId, black => <<>>}, status => 3,
                at_ms => 100}};
claim_event(black, NodeId) ->
    #{event_type => <<"seat_claimed_v1">>,
      data => #{game_id => ?GAME, player_node_id => NodeId, color => <<"b">>,
                seats => #{white => ?ALICE, black => NodeId}, status => 3,
                at_ms => 200}}.

flagged_event(At) ->
    #{event_type => <<"clock_flagged_v1">>,
      data => #{game_id => ?GAME, player_node_id => ?ALICE,
                clocks => #{white => 0, black => 60000}, status => 5,
                at_ms => At}}.

ended_event(At) ->
    #{event_type => <<"game_ended_v1">>,
      data => #{game_id => ?GAME, at_ms => At, outcome => forfeit,
                reason => clock_flag, clocks => #{white => 0, black => 1000},
                status => 9, fen_after => <<>>, ply => 0,
                winner_node_id => ?BOB}}.
