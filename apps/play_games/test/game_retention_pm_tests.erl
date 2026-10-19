%% @doc The retention of an ended game, pinned as a state machine.
%%
%% The window is configuration, so the tests set it rather than waiting a day:
%% what has to be right is that the deadline is the end's own `at_ms' plus the
%% window, that the archive command comes out of the instance that scheduled it,
%% and that an archive already recorded stops it.
-module(game_retention_pm_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("evoq/include/evoq.hrl").

-define(GAME, <<"game-01a155d187887b2d9828309b42952c86">>).
-define(WINDOW, 1000).

retention_test_() ->
    {setup, fun set_window/0, fun clear_window/1,
     [{timeout, 30, fun the_end_archives_after_the_window/0},
      {timeout, 30, fun the_window_is_configuration/0},
      {timeout, 30, fun the_archive_stops_the_retention/0},
      {timeout, 30, fun an_archive_that_already_happened_routes_as_a_stop/0},
      {timeout, 30, fun a_long_ended_game_archives_without_waiting/0},
      {timeout, 30, fun routing_answers_without_a_game_id_are_false/0}]}.

set_window() ->
    application:set_env(play_games, game_retention_ms, ?WINDOW).

clear_window(_) ->
    application:unset_env(play_games, game_retention_ms).

the_end_archives_after_the_window() ->
    State = handled(ended_event(5000)),
    ?assertEqual(5000 + ?WINDOW, maps:get(deadline_ms, State)),
    {noreply, Fired, [Command]} =
        game_retention_pm:handle_info({game_retention_expired, ?GAME,
                                       maps:get(deadline_ms, State)}, State),
    ?assertMatch(#evoq_command{command_type = archive_game_v1}, Command),
    ?assertEqual(?GAME, Command#evoq_command.aggregate_id),
    ?assertEqual(#{command_type => archive_game_v1, game_id => ?GAME},
                 Command#evoq_command.payload),
    %% The deadline is kept and asked again until `game_archived_v1' says the
    %% slice ran: a failed dispatch is only logged by evoq's PM runtime.
    ?assertEqual(6000, maps:get(deadline_ms, Fired)),
    {noreply, _Again, [Retry]} =
        game_retention_pm:handle_info({game_retention_expired, ?GAME, 6000}, Fired),
    ?assertMatch(#evoq_command{command_type = archive_game_v1}, Retry).

the_window_is_configuration() ->
    %% The number an operator sets is the number that is used, and the shipped
    %% default is a day when nothing is set.
    ?assertEqual(?WINDOW, game_retention_pm:window_ms()),
    application:unset_env(play_games, game_retention_ms),
    ?assertEqual(86400000, game_retention_pm:window_ms()),
    application:set_env(play_games, game_retention_ms, ?WINDOW).

the_archive_stops_the_retention() ->
    State = handled(ended_event(5000)),
    Archived = handled(archived_event(6000), State),
    ?assertEqual(undefined, maps:get(deadline_ms, Archived)),
    ?assertEqual(undefined, maps:get(timer, Archived)).

an_archive_that_already_happened_routes_as_a_stop() ->
    ?assertEqual({stop, ?GAME},
                 game_retention_pm:correlate(#{event_type => <<"game_archived_v1">>,
                                               data => #{game_id => ?GAME}}, #{})),
    ?assertEqual({continue, ?GAME},
                 game_retention_pm:correlate(#{event_type => <<"game_ended_v1">>,
                                               data => #{game_id => ?GAME}}, #{})).

a_long_ended_game_archives_without_waiting() ->
    %% A game that ended while the node was down, replayed at boot: its window is
    %% already past, so the deadline fires at once rather than never.
    Long = erlang:system_time(millisecond) - 60000,
    Replay = <<"game-01a155d187887b2d9828309b42952c87">>,
    {ok, Fresh} = game_retention_pm:init(Replay),
    {ok, State} = game_retention_pm:handle(Fresh, ended_event(Replay, Long),
                                           #{replaying => true}),
    Deadline = Long + ?WINDOW,
    ?assertEqual(Deadline, maps:get(deadline_ms, State)),
    receive
        {game_retention_expired, Replay, Fired} -> ?assertEqual(Deadline, Fired)
    after 1000 ->
        ?assert(false)
    end.

routing_answers_without_a_game_id_are_false() ->
    ?assertEqual(false,
                 game_retention_pm:correlate(#{event_type => <<"game_ended_v1">>,
                                               data => #{}}, #{})).

%%====================================================================
%% Helpers
%%====================================================================

handled(Event) ->
    {ok, Fresh} = game_retention_pm:init(?GAME),
    handled(Event, Fresh).

handled(Event, Before) ->
    {ok, Handled} = game_retention_pm:handle(Before, Event, #{}),
    game_retention_pm:apply(Handled, Event).

ended_event(At) ->
    ended_event(?GAME, At).

ended_event(GameId, At) ->
    #{event_type => <<"game_ended_v1">>,
      data => #{game_id => GameId, at_ms => At, outcome => forfeit,
                reason => clock_flag, clocks => #{white => 0, black => 1000},
                status => 9, fen_after => <<>>, ply => 0,
                winner_node_id => <<"b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1">>}}.

archived_event(At) ->
    #{event_type => <<"game_archived_v1">>,
      data => #{game_id => ?GAME, reason => <<"retention">>, status => 17,
                at_ms => At}}.
