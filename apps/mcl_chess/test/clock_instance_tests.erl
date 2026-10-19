%% @doc The clock instance's own lifecycle: what it finishes, and when it stops.
%%
%% This suite runs the store subscription and the clock instance WITHOUT the
%% policies, which is exactly the state a crash leaves: a game whose events were
%% recorded and whose policy never dispatched. What it pins is the two things the
%% instance is responsible for on its own:
%%
%% - a claim that filled the second seat with no start is caught up, so a game
%%   with two players is playable even when the node died in between
%% - an archived game takes its instance with it, so a game that never played
%%   leaves nothing behind to fire refused commands for the rest of the node's
%%   life
%%
%% The catch-up delay is configuration and is set short here, so the suite waits
%% for an outcome rather than a guessed interval.
-module(clock_instance_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("reckon_gater/include/reckon_gater_types.hrl").

-define(INITIATOR, <<"a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90">>).
-define(OPPONENT, <<"b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1">>).
-define(CATCH_UP, 100).

instance_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     [{timeout, 60, fun a_full_game_with_no_start_is_caught_up/0},
      {timeout, 60, fun an_archived_game_takes_its_instance_with_it/0}]}.

setup() ->
    {Dir, Started} = play_games_test_store:start(),
    application:set_env(play_games, catch_up_ms, ?CATCH_UP),
    {ok, Sub} = evoq_store_subscription:start_link(play_games_test_store:store()),
    unlink(Sub),
    %% The emitters only: no seats-full policy, so the start is the instance's
    %% job, which is the state the node is in after a crash between the event
    %% and the dispatch.
    Handlers = [start_handler(M) || M <- [emit_seat_claimed_v1_to_mesh,
                                          emit_game_started_v1_to_mesh,
                                          emit_game_archived_v1_to_mesh]],
    ok = evoq_process_manager:start(game_clock_pm, #{}),
    {Dir, Started, Sub, Handlers}.

cleanup({Dir, Started, Sub, Handlers}) ->
    [stop(P) || P <- [Sub | Handlers]],
    application:unset_env(play_games, catch_up_ms),
    play_games_test_store:stop({Dir, Started}).

a_full_game_with_no_start_is_caught_up() ->
    GameId = seated(),
    events = await_event(GameId, <<"game_started_v1">>, 200),
    ?assertEqual([<<"game_initiated_v1">>, <<"seat_claimed_v1">>,
                  <<"seat_claimed_v1">>, <<"game_started_v1">>],
                 play_games_test_store:strings(GameId)).

an_archived_game_takes_its_instance_with_it() ->
    GameId = seated(),
    {ok, _, _, _} = withdraw_game_api:handle(#{game_id => GameId,
                                               caller => ?INITIATOR}),
    %% The archive ends the instance, and the catch-up it would otherwise have
    %% fired never happens: a start on a dead game is refused, and this is what
    %% keeps the node from asking for ever.
    gone = await_no_instance(GameId, 200),
    ?assertEqual([<<"game_initiated_v1">>, <<"seat_claimed_v1">>,
                  <<"seat_claimed_v1">>, <<"game_archived_v1">>],
                 play_games_test_store:strings(GameId)).

%%====================================================================
%% Helpers
%%====================================================================

born() ->
    {ok, _, [Event], _} = initiate_game_api:handle(
                            #{time_control => {60000, 0}, initiator => ?INITIATOR}),
    maps:get(game_id, Event).

seated() ->
    GameId = born(),
    {ok, _, _, _} = claim_seat_api:handle(#{game_id => GameId, caller => ?INITIATOR,
                                            color => <<"w">>}),
    {ok, _, _, _} = claim_seat_api:handle(#{game_id => GameId, caller => ?OPPONENT,
                                            color => <<"b">>}),
    GameId.

await_event(GameId, EventType, Tries) ->
    case lists:member(EventType, play_games_test_store:strings(GameId)) of
        true -> events;
        false -> retry_event(GameId, EventType, Tries)
    end.

retry_event(_GameId, EventType, 0) -> error({event_never_appeared, EventType});
retry_event(GameId, EventType, Tries) ->
    timer:sleep(20),
    await_event(GameId, EventType, Tries - 1).

%% The instance for this game is gone: no process is registered for it, so no
%% deadline and no catch-up can fire for the game again.
await_no_instance(GameId, Tries) ->
    case evoq_pm_router:get_instance(game_clock_pm, GameId) of
        {error, not_found} -> gone;
        {ok, _Pid} -> retry_no_instance(GameId, Tries)
    end.

retry_no_instance(_GameId, 0) -> error(the_instance_outlived_the_game);
retry_no_instance(GameId, Tries) ->
    timer:sleep(20),
    await_no_instance(GameId, Tries - 1).

start_handler(Module) ->
    {ok, Pid} = evoq_event_handler:start_link(Module, #{}),
    unlink(Pid),
    Pid.

stop(Pid) ->
    gen_server:stop(Pid).
