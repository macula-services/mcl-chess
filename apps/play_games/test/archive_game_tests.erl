%% @doc The death slice, after the window: archive_game_v1 through the real store.
%%
%% It is internal on purpose - the retention instance dispatches it - so what is
%% pinned here is the guard (an ended game, once) and the event: `game_archived_v1'
%% with reason `retention', which is how a reader tells it from the pre-start
%% `withdrawn' that shares the event type.
-module(archive_game_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("reckon_gater/include/reckon_gater_types.hrl").

-define(ALICE, <<"a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90">>).
-define(BOB, <<"b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1">>).

store_test_() ->
    {setup, fun play_games_test_store:start/0, fun play_games_test_store:stop/1,
     [{timeout, 60, fun an_ended_game_is_archived_by_retention/0},
      {timeout, 60, fun a_game_that_has_not_ended_is_not_archived/0},
      {timeout, 60, fun a_game_is_archived_once/0},
      {timeout, 60, fun a_game_that_does_not_exist_is_not_archived/0}]}.

an_ended_game_is_archived_by_retention() ->
    GameId = ended(),
    {ok, _Version, [Archived], View} = archive(GameId),
    ?assertEqual(<<"game_archived_v1">>, maps:get(event_type, Archived)),
    ?assertEqual(<<"retention">>, maps:get(reason, Archived)),
    %% ARCHIVED replaces ENDED and STARTED stays cleared, exactly as the pre-start
    %% withdraw leaves it.
    ?assertEqual(17, maps:get(status, Archived)),
    %% INITIATED is never cleared: it is the "this dossier exists" flag every
    %% slice guard checks, so an archived game is initiated and archived.
    ?assertEqual(<<"initiated, archived">>, maps:get(<<"status_label">>, View)),
    ?assertEqual([<<"game_initiated_v1">>, <<"seat_claimed_v1">>,
                  <<"seat_claimed_v1">>, <<"game_started_v1">>,
                  <<"game_ended_v1">>, <<"game_archived_v1">>],
                 play_games_test_store:strings(GameId)).

a_game_that_has_not_ended_is_not_archived() ->
    %% A game still being played is not the death slice's business: its own end
    %% comes first, and the window after that.
    GameId = started(),
    {error, not_ended} = archive(GameId),
    ?assertEqual([], events(GameId, <<"game_archived_v1">>)).

a_game_is_archived_once() ->
    GameId = ended(),
    {ok, _, _, _} = archive(GameId),
    ?assertEqual({error, game_archived}, archive(GameId)),
    ?assertEqual(1, length(events(GameId, <<"game_archived_v1">>))).

a_game_that_does_not_exist_is_not_archived() ->
    {error, not_initiated} = archive(initiate_game_v1:mint_game_id()).

%%====================================================================
%% Helpers
%%====================================================================

born() ->
    {ok, _, [Event], _} = initiate_game_api:handle(
                            #{time_control => {60000, 0}, initiator => ?ALICE}),
    maps:get(game_id, Event).

started() ->
    GameId = born(),
    {ok, _, _, _} = claim(GameId, ?ALICE, <<"w">>),
    {ok, _, _, _} = claim(GameId, ?BOB, <<"b">>),
    %% No policy runs in this suite, so the start is dispatched here.
    {ok, _, _, _} = start_game_api:handle(#{game_id => GameId}),
    GameId.

ended() ->
    GameId = started(),
    {ok, _, _, _} = resign_game_api:handle(#{game_id => GameId, caller => ?BOB}),
    GameId.

claim(GameId, NodeId, Color) ->
    claim_seat_api:handle(#{game_id => GameId, caller => NodeId, color => Color}).

archive(GameId) ->
    archive_game_api:handle(#{game_id => GameId}).

events(GameId, Type) ->
    [Event || Event <- play_games_test_store:stream(GameId),
              Event#event.event_type =:= Type].
