%% @doc The start slice: start_game_v1, the command no caller can reach.
%%
%% start_game is internal on purpose: it is dispatched by the seats-full policy
%% when the second seat is claimed, so a game starts itself and needs no extra
%% round trip. What this pins is the guard (both seats filled, never twice) and
%% the event, which carries the whole started state so a projector reads it
%% alone.
-module(start_game_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("reckon_gater/include/reckon_gater_types.hrl").

-define(ALICE, <<"a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90">>).
-define(BOB, <<"b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1">>).

store_test_() ->
    {setup, fun play_games_test_store:start/0, fun play_games_test_store:stop/1,
     [{timeout, 60, fun a_game_with_two_seats_starts/0},
      {timeout, 60, fun the_started_event_carries_the_whole_state/0},
      {timeout, 60, fun the_seat_holders_are_the_seat_holders_whatever_the_colour/0},
      {timeout, 60, fun a_game_with_one_seat_does_not_start/0},
      {timeout, 60, fun a_game_with_no_seats_does_not_start/0},
      {timeout, 60, fun a_started_game_cannot_start_again/0},
      {timeout, 60, fun a_game_that_does_not_exist_does_not_start/0}]}.

a_game_with_two_seats_starts() ->
    GameId = seated(),
    {ok, _Version, [Started], View} = start_game_api:handle(#{game_id => GameId}),
    ?assertEqual(<<"game_started_v1">>, maps:get(event_type, Started)),
    ?assertEqual(5, maps:get(<<"status">>, View)),
    ?assertEqual(<<"initiated, started">>, maps:get(<<"status_label">>, View)),
    ?assertEqual([<<"game_initiated_v1">>, <<"seat_claimed_v1">>,
                  <<"seat_claimed_v1">>, <<"game_started_v1">>],
                 play_games_test_store:strings(GameId)).

the_started_event_carries_the_whole_state() ->
    {ok, _, [Started], _} = start_game_api:handle(#{game_id => seated()}),
    ?assertEqual(?ALICE, maps:get(white_node_id, Started)),
    ?assertEqual(?BOB, maps:get(black_node_id, Started)),
    ?assertEqual(<<"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1">>,
                 maps:get(position, Started)),
    ?assertEqual(<<"w">>, maps:get(to_move, Started)),
    ?assertEqual(0, maps:get(ply, Started)),
    ?assertEqual(#{white => 60000, black => 60000}, maps:get(clocks, Started)),
    ?assertEqual(5, maps:get(status, Started)),
    ?assert(is_integer(maps:get(at_ms, Started))).

the_seat_holders_are_the_seat_holders_whatever_the_colour() ->
    %% Born by ALICE, taken by BOB in white and ALICE in black: the event names
    %% the holders by colour, so nothing anywhere assumes the initiator is white.
    GameId = born(),
    {ok, _, _, _} = claim(GameId, ?BOB, <<"w">>),
    {ok, _, _, _} = claim(GameId, ?ALICE, <<"b">>),
    {ok, _, [Started], _} = start_game_api:handle(#{game_id => GameId}),
    ?assertEqual(?BOB, maps:get(white_node_id, Started)),
    ?assertEqual(?ALICE, maps:get(black_node_id, Started)).

a_game_with_one_seat_does_not_start() ->
    GameId = born(),
    {ok, _, _, _} = claim(GameId, ?ALICE, <<"w">>),
    ?assertEqual({error, seats_not_filled}, start_game_api:handle(#{game_id => GameId})),
    ?assertEqual([<<"game_initiated_v1">>, <<"seat_claimed_v1">>],
                 play_games_test_store:strings(GameId)).

a_game_with_no_seats_does_not_start() ->
    GameId = born(),
    ?assertEqual({error, seats_not_filled}, start_game_api:handle(#{game_id => GameId})).

a_started_game_cannot_start_again() ->
    GameId = seated(),
    {ok, _, _, _} = start_game_api:handle(#{game_id => GameId}),
    %% A second dispatch is not a crash and not a second event: the policy can
    %% be handed the same claim twice, and the guard is what makes it safe.
    ?assertEqual({error, already_started}, start_game_api:handle(#{game_id => GameId})),
    ?assertEqual(1, length(started_events(GameId))).

a_game_that_does_not_exist_does_not_start() ->
    {error, not_initiated} = start_game_api:handle(#{game_id => initiate_game_v1:mint_game_id()}).

%%====================================================================
%% Helpers
%%====================================================================

born() ->
    {ok, _, [Event], _} = initiate_game_api:handle(
                            #{time_control => {60000, 0}, initiator => ?ALICE}),
    maps:get(game_id, Event).

seated() ->
    GameId = born(),
    {ok, _, _, _} = claim(GameId, ?ALICE, <<"w">>),
    {ok, _, _, _} = claim(GameId, ?BOB, <<"b">>),
    GameId.

claim(GameId, NodeId, Color) ->
    claim_seat_api:handle(#{game_id => GameId, caller => NodeId, color => Color}).

started_events(GameId) ->
    [E || E <- play_games_test_store:stream(GameId),
          E#event.event_type =:= <<"game_started_v1">>].
