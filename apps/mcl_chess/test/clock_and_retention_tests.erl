%% @doc The clock and the death slice, end to end: a game that runs out of time
%% ends itself, and an ended game is archived after the retention window.
%%
%% What this pins is the chain nobody can drive from outside: the game's clock
%% instance schedules the deadline from the start event, the deadline fires a
%% flag, the flag desk records it, the flag policy dispatches the end, the end
%% re-judges the position, the projections write it all, the facts go out and the
%% query answers. The retention
%% instance does the same for the death slice once the end's window has passed.
%%
%% The clock is real here, which is the point: a 1 s control is the shortest the
%% boundary accepts, and the test waits for the event rather than sleeping a
%% guessed interval. The retention window is configuration and is set short for
%% the same reason.
%%
%% The mesh is mecked exactly as the other walks are: the topic and the shape are
%% real, only the network is not.
-module(clock_and_retention_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("evoq/include/evoq.hrl").
-include_lib("reckon_gater/include/reckon_gater_types.hrl").

-define(INITIATOR, <<"a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90">>).
-define(OPPONENT, <<"b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1">>).
-define(COLLECTOR, mcl_chess_clock_test_collector).
-define(WINDOW, 300).
-define(RETRY, 200).

%% A 1 s control: the shortest the boundary accepts (mcl-chess#1, gate answer 2),
%% which is what keeps this suite quick.
-define(BLITZ, {1000, 0}).

clock_and_retention_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     [{timeout, 90, fun a_clock_that_runs_out_ends_the_game/0},
      {timeout, 90, fun a_failed_flag_dispatch_is_asked_again/0},
      {timeout, 90, fun the_flag_and_the_end_both_reach_the_mesh/0},
      {timeout, 90, fun the_read_model_shows_the_game_was_lost_on_time/0},
      {timeout, 90, fun an_ended_game_is_archived_after_the_window/0},
      {timeout, 90, fun a_game_still_being_played_is_never_archived/0}]}.

setup() ->
    {Dir, Started} = play_games_test_store:start(),
    Sqlite = filename:join(Dir, "mcl_chess.sqlite3"),
    Collector = collector_start(),
    meck:new(mcl_om, [passthrough]),
    meck:new(macula, [passthrough]),
    meck:expect(mcl_om, mesh_handles,
                fun() -> {ok, pool, crypto:hash(sha256, <<"io.macula">>)} end),
    meck:expect(macula, publish, fun(_Pool, _Realm, Topic, Fact) ->
                                         Collector ! {published, Topic, Fact}, ok
                                 end),
    application:set_env(play_games, game_retention_ms, ?WINDOW),
    %% The retry interval a failed dispatch is asked again at, and the delay the
    %% clock waits before it catches up a half-done sequence: both are
    %% configuration, and both are short here.
    application:set_env(play_games, catch_up_ms, ?RETRY),
    {ok, Sub} = evoq_store_subscription:start_link(play_games_test_store:store()),
    unlink(Sub),
    {ok, ReadModel} = game_read_model_store:start_link(Sqlite),
    unlink(ReadModel),
    {ok, Query} = game_query_store:start_link(Sqlite),
    unlink(Query),
    Handlers = [start_handler(M) || M <- [emit_game_initiated_v1_to_mesh,
                                          emit_seat_claimed_v1_to_mesh,
                                          emit_seat_refused_v1_to_mesh,
                                          emit_game_started_v1_to_mesh,
                                          emit_move_played_v1_to_mesh,
                                          emit_move_refused_v1_to_mesh,
                                          emit_clock_flagged_v1_to_mesh,
                                          emit_game_ended_v1_to_mesh,
                                          emit_game_archived_v1_to_mesh,
                                          on_seat_claimed_v1_maybe_start_game,
                                          on_move_played_v1_maybe_end_game,
                                          on_clock_flagged_v1_maybe_end_game,
                                          game_lifecycle_to_games]],
    %% The clock and the retention are process managers, registered rather than
    %% started: evoq's PM supervisor owns their instances.
    ok = evoq_process_manager:start(game_clock_pm, #{}),
    ok = evoq_process_manager:start(game_retention_pm, #{}),
    collector_clear(),
    {Dir, Started, Sub, ReadModel, Query, Handlers, Collector}.

cleanup({Dir, Started, Sub, ReadModel, Query, Handlers, Collector}) ->
    [stop(P) || P <- [Sub, ReadModel, Query | Handlers]],
    application:unset_env(play_games, game_retention_ms),
    application:unset_env(play_games, catch_up_ms),
    Collector ! stop,
    catch unregister(?COLLECTOR),
    meck:unload([mcl_om, macula]),
    play_games_test_store:stop({Dir, Started}).

a_clock_that_runs_out_ends_the_game() ->
    GameId = started_blitz_game(),
    %% Nobody moves and nobody is asked: white's second runs out and the game
    %% ends itself.
    events = await_event(GameId, <<"game_ended_v1">>, 400),
    ?assertEqual([<<"game_initiated_v1">>, <<"seat_claimed_v1">>,
                  <<"seat_claimed_v1">>, <<"game_started_v1">>,
                  <<"clock_flagged_v1">>, <<"game_ended_v1">>],
                 play_games_test_store:strings(GameId)),
    [Flagged] = events(GameId, <<"clock_flagged_v1">>),
    ?assertEqual(?INITIATOR, maps:get(player_node_id, data_of(Flagged))),
    [Ended] = events(GameId, <<"game_ended_v1">>),
    Data = data_of(Ended),
    ?assertEqual(forfeit, maps:get(outcome, Data)),
    ?assertEqual(clock_flag, maps:get(reason, Data)),
    ?assertEqual(?OPPONENT, maps:get(winner_node_id, Data)),
    %% The flagged clock is the one at zero, and the other never ran.
    ?assertMatch(#{white := 0}, maps:get(clocks, Data)).

a_failed_flag_dispatch_is_asked_again() ->
    %% A store timeout, or a Ra leader change during a station roll. evoq's PM
    %% runtime only logs a failed dispatch, so the flag would never be recorded
    %% and the game would never end: the clock asks again until the event that
    %% settles it arrives.
    Counter = counters:new(1, []),
    meck:new(evoq_router, [passthrough]),
    meck:expect(evoq_router, dispatch, fun(Command) ->
        case Command#evoq_command.command_type of
            flag_clock_v1 ->
                counters:add(Counter, 1, 1),
                failed_once(counters:get(Counter, 1), Command);
            _Other ->
                meck:passthrough([Command])
        end
    end),
    GameId = started_blitz_game(),
    Result = events = await_event(GameId, <<"game_ended_v1">>, 600),
    ?assertEqual(events, Result),
    meck:unload(evoq_router),
    %% The first attempt failed and at least one more was made.
    ?assert(counters:get(Counter, 1) >= 2),
    [Flagged] = events(GameId, <<"clock_flagged_v1">>),
    ?assertEqual(?INITIATOR, maps:get(player_node_id, data_of(Flagged))),
    [Ended] = events(GameId, <<"game_ended_v1">>),
    ?assertEqual(clock_flag, maps:get(reason, data_of(Ended))).

%% The first dispatch fails and every later one is real.
failed_once(1, _Command) ->
    {error, simulated_store_timeout};
failed_once(_Attempts, Command) ->
    meck:passthrough([Command]).

the_flag_and_the_end_both_reach_the_mesh() ->
    GameId = started_blitz_game(),
    events = await_event(GameId, <<"game_ended_v1">>, 400),
    Facts = collector_take(GameId, 6, 400),
    Flagged = fact_on(Facts, <<"clock_flagged_v1">>),
    ?assertEqual(<<"io.macula/mcl-chess/chess/game/clock_flagged_v1">>,
                 topic_of(Flagged)),
    ?assertEqual({text, ?INITIATOR}, maps:get(player_node_id, fact_of(Flagged))),
    Ended = fact_on(Facts, <<"game_ended_v1">>),
    ?assertEqual({text, <<"forfeit">>}, maps:get(outcome, fact_of(Ended))),
    ?assertEqual({text, <<"clock_flag">>}, maps:get(reason, fact_of(Ended))).

the_read_model_shows_the_game_was_lost_on_time() ->
    GameId = started_blitz_game(),
    events = await_event(GameId, <<"game_ended_v1">>, 400),
    Row = await_status(GameId, 9, 400),
    ?assertEqual(<<"forfeit">>, maps:get(<<"outcome">>, Row)),
    ?assertEqual(<<"clock_flag">>, maps:get(<<"end_reason">>, Row)),
    ?assertEqual(?OPPONENT, maps:get(<<"winner">>, Row)),
    %% The flagged clock is at zero and the other never ran.
    ?assertEqual(#{<<"white">> => 0, <<"black">> => 1000},
                 maps:get(<<"clocks">>, Row)).

an_ended_game_is_archived_after_the_window() ->
    %% A game that ended by resignation is archived once the window has passed,
    %% with nobody asking: the retention instance it left behind does it.
    GameId = started_game(?BLITZ),
    {ok, _, _, _} = resign_game_api:handle(#{game_id => GameId, caller => ?OPPONENT}),
    events = await_event(GameId, <<"game_archived_v1">>, 400),
    [Archived] = events(GameId, <<"game_archived_v1">>),
    ?assertEqual(<<"retention">>, maps:get(reason, data_of(Archived))),
    ?assertEqual(17, maps:get(status, data_of(Archived))),
    Facts = collector_take(GameId, 6, 400),
    ArchivedFact = fact_on(Facts, <<"game_archived_v1">>),
    ?assertEqual({text, <<"retention">>}, maps:get(reason, fact_of(ArchivedFact))),
    Row = await_status(GameId, 17, 400),
    ?assertEqual(<<"retention">>, maps:get(<<"archive_reason">>, Row)).

a_game_still_being_played_is_never_archived() ->
    %% A started game is not the death slice's business, and its clock has not
    %% run out either.
    GameId = started_game({60000, 0}),
    timer:sleep(3 * ?WINDOW),
    ?assertEqual([], events(GameId, <<"game_archived_v1">>)),
    ?assertEqual([], events(GameId, <<"game_ended_v1">>)),
    {ok, Row} = get_game_by_id:find(GameId),
    ?assertEqual(5, maps:get(<<"status">>, Row)).

%%====================================================================
%% Helpers
%%====================================================================

born(TimeControl) ->
    {ok, _, [Event], _} = initiate_game_api:handle(
                            #{time_control => TimeControl, initiator => ?INITIATOR}),
    maps:get(game_id, Event).

claim(GameId, NodeId, Color) ->
    claim_seat_api:handle(#{game_id => GameId, caller => NodeId, color => Color}).

%% The second claim starts the game in the same command, so the clock instance
%% sees the start event and schedules white's deadline.
started_game(TimeControl) ->
    GameId = born(TimeControl),
    {ok, _, _, _} = claim(GameId, ?INITIATOR, <<"w">>),
    {ok, _, _, _} = claim(GameId, ?OPPONENT, <<"b">>),
    await_event(GameId, <<"game_started_v1">>, 200),
    GameId.

started_blitz_game() ->
    started_game(?BLITZ).

await_event(GameId, EventType, Tries) ->
    case lists:member(EventType, play_games_test_store:strings(GameId)) of
        true -> events;
        false -> retry_event(GameId, EventType, Tries)
    end.

retry_event(_GameId, EventType, 0) -> error({event_never_appeared, EventType});
retry_event(GameId, EventType, Tries) ->
    timer:sleep(20),
    await_event(GameId, EventType, Tries - 1).

await_status(GameId, Status, Tries) ->
    case get_game_by_id:find(GameId) of
        {ok, #{<<"status">> := Status} = Row} -> Row;
        {ok, _Row} -> retry_status(GameId, Status, Tries);
        {error, not_found} -> retry_status(GameId, Status, Tries);
        {error, _} = Error -> error(Error)
    end.

retry_status(_GameId, _Status, 0) ->
    error(read_model_never_reached_that_status);
retry_status(GameId, Status, Tries) ->
    timer:sleep(20),
    await_status(GameId, Status, Tries - 1).

start_handler(Module) ->
    {ok, Pid} = evoq_event_handler:start_link(Module, #{}),
    unlink(Pid),
    Pid.

stop(Pid) ->
    gen_server:stop(Pid).

events(GameId, Type) ->
    [Event || #event{event_type = EventType} = Event
                  <- play_games_test_store:stream(GameId),
              EventType =:= Type].

data_of(#event{data = Data}) when is_map(Data) -> Data;
data_of(#{data := Data}) when is_map(Data) -> Data;
data_of(Event) -> Event.

collector_start() ->
    Collector = spawn(fun() -> collect([]) end),
    unlink(Collector),
    register(?COLLECTOR, Collector),
    Collector.

collect(Seen) ->
    receive
        {published, Topic, Fact} ->
            collect([{Topic, Fact} | Seen]);
        {take, GameId, From} ->
            From ! {taken, lists:reverse(matching(GameId, Seen))},
            collect(Seen);
        {clear, From} ->
            From ! cleared,
            collect([]);
        stop ->
            ok
    end.

matching(GameId, Seen) ->
    [Entry || {_Topic, Fact} = Entry <- Seen,
              maps:get(game_id, Fact, undefined) =:= {text, GameId}].

collector_clear() ->
    ?COLLECTOR ! {clear, self()},
    receive cleared -> ok after 2000 -> ok end.

collector_take(GameId, Want, Tries) ->
    ?COLLECTOR ! {take, GameId, self()},
    receive
        {taken, Facts} when length(Facts) >= Want -> Facts;
        {taken, _Few} -> collector_retry(GameId, Want, Tries)
    after 2000 ->
        collector_retry(GameId, Want, Tries)
    end.

collector_retry(_GameId, _Want, 0) -> error(not_enough_facts);
collector_retry(GameId, Want, Tries) ->
    timer:sleep(20),
    collector_take(GameId, Want, Tries - 1).

topic_of({Topic, _Fact}) -> Topic.
fact_of({_Topic, Fact}) -> Fact.

fact_on(Facts, Name) ->
    hd([F || F <- Facts, binary:match(topic_of(F), Name) =/= nomatch]).
