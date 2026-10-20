%% @doc The end slice, end to end: resign_game_v1 and end_game_v1 through the
%% real store.
%%
%% What this pins: a resignation is a forfeit with the opponent winning, an end
%% needs a game that actually started, a game ends once, and the end policy's
%% internal command cannot end a game on a winner the game never admitted.
-module(resign_and_end_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("reckon_gater/include/reckon_gater_types.hrl").

%% The caller as macula actually delivers it (the raw 32-byte node id) and as
%% this service stores it (hex). A 64-hex caller cannot tell the two apart
%% (mcl-chess#10).
-define(ALICE_RAW, crypto:hash(sha256, <<"resign-tests alice">>)).
-define(ALICE, binary:encode_hex(?ALICE_RAW, lowercase)).
-define(BOB, <<"b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1">>).
-define(CAROL, <<"c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2">>).

store_test_() ->
    {setup, fun play_games_test_store:start/0, fun play_games_test_store:stop/1,
     [{timeout, 60, fun the_opponent_wins_when_a_player_resigns/0},
      {timeout, 60, fun the_end_event_carries_the_whole_state/0},
      {timeout, 60, fun a_started_game_ends_once/0},
      {timeout, 60, fun a_game_that_never_started_does_not_end/0},
      {timeout, 60, fun a_stranger_cannot_resign_a_game/0},
      {timeout, 60, fun an_archived_game_does_not_end/0},
      {timeout, 60, fun the_end_desk_names_a_winner_the_game_admitted/0},
      {timeout, 60, fun a_draw_names_nobody/0},
      {timeout, 60, fun an_ended_game_cannot_be_withdrawn/0},
      {timeout, 60, fun a_resignation_over_the_wire_is_read_and_answered_in_text/0}]}.

the_opponent_wins_when_a_player_resigns() ->
    GameId = started(),
    {ok, _Version, [Ended], View} = resign(GameId, ?BOB),
    ?assertEqual(<<"game_ended_v1">>, maps:get(event_type, Ended)),
    ?assertEqual(forfeit, maps:get(outcome, data_of(Ended))),
    ?assertEqual(?ALICE, maps:get(winner_node_id, data_of(Ended))),
    ?assertEqual(resignation, maps:get(reason, data_of(Ended))),
    ?assertEqual(9, maps:get(<<"status">>, View)),
    ?assertEqual(<<"initiated, ended">>, maps:get(<<"status_label">>, View)),
    ?assertEqual(<<"forfeit">>, maps:get(<<"outcome">>, View)),
    ?assertEqual(?ALICE, maps:get(<<"winner">>, View)),
    ?assertEqual(<<"resignation">>, maps:get(<<"end_reason">>, View)),
    ?assertEqual([<<"game_initiated_v1">>, <<"seat_claimed_v1">>,
                  <<"seat_claimed_v1">>, <<"game_started_v1">>,
                  <<"game_ended_v1">>],
                 play_games_test_store:strings(GameId)).

the_end_event_carries_the_whole_state() ->
    %% The position, the ply and the clocks stop where the game stopped: a
    %% projection reads this one event and has the finished game.
    GameId = started(),
    {ok, _, _, _} = submit_move_api:handle(#{game_id => GameId,
                                             caller => ?ALICE,
                                             move => <<"e2e4">>}),
    {ok, _, [Ended], _} = resign(GameId, ?ALICE),
    Data = data_of(Ended),
    ?assertEqual(1, maps:get(ply, Data)),
    ?assertEqual(9, maps:get(status, Data)),
    ?assertEqual(<<"rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1">>,
                 maps:get(fen_after, Data)),
    #{white := White, black := Black} = maps:get(clocks, Data),
    %% White resigned after using some of its time and pays for it; black's
    %% clock has not run at all.
    ?assert(White =< 60000),
    ?assertEqual(60000, Black),
    ?assert(is_integer(maps:get(at_ms, Data))).

a_started_game_ends_once() ->
    GameId = started(),
    {ok, _, _, _} = resign(GameId, ?ALICE),
    {error, already_ended} = resign(GameId, ?BOB),
    ?assertEqual(1, length(events(GameId, <<"game_ended_v1">>))).

a_game_that_never_started_does_not_end() ->
    GameId = born(),
    {ok, _, _, _} = claim(GameId, ?ALICE, <<"w">>),
    ?assertEqual({error, not_started}, resign(GameId, ?ALICE)),
    ?assertEqual([<<"game_initiated_v1">>, <<"seat_claimed_v1">>],
                 play_games_test_store:strings(GameId)).

a_stranger_cannot_resign_a_game() ->
    GameId = started(),
    {error, not_a_player} = resign(GameId, ?CAROL),
    ?assertEqual([], events(GameId, <<"game_ended_v1">>)),
    %% Not evidence either: a resignation is a lawful act, and a stranger's
    %% attempt says nothing about the players.
    ?assertEqual([], events(GameId, <<"move_refused_v1">>)).

an_archived_game_does_not_end() ->
    GameId = born(),
    {ok, _, _, _} = withdraw_game_api:handle(#{game_id => GameId, caller => ?ALICE}),
    {error, game_archived} = resign(GameId, ?ALICE),
    ?assertEqual([<<"game_initiated_v1">>, <<"game_archived_v1">>],
                 play_games_test_store:strings(GameId)).

%% The end command is internal, dispatched by a policy this service runs, and
%% the handler still refuses a winner the game never admitted: a node id in the
%% record that never held a seat is a claim the aggregate cannot check later.
the_end_desk_names_a_winner_the_game_admitted() ->
    GameId = started(),
    ?assertEqual({error, winner_not_seated},
                 end_game_api:handle(#{game_id => GameId, outcome => winner,
                                       winner_node_id => ?CAROL,
                                       reason => checkmate})),
    ?assertEqual([], events(GameId, <<"game_ended_v1">>)).

a_draw_names_nobody() ->
    GameId = started(),
    {ok, _, [Ended], _} = end_game_api:handle(#{game_id => GameId,
                                                outcome => draw,
                                                reason => stalemate}),
    ?assertEqual(<<>>, maps:get(winner_node_id, data_of(Ended))),
    ?assertEqual(draw, maps:get(outcome, data_of(Ended))),
    %% A win that names nobody is refused by the event itself.
    ?assertMatch({error, invalid_winner},
                 game_ended_v1:new(#{game_id => GameId, outcome => winner,
                                     reason => checkmate, fen_after => <<>>,
                                     ply => 0, clocks => #{},
                                     status => 9})).

%% Ending clears STARTED, so an ended game looks unstarted to the withdraw
%% desk. Without its own guard the initiator could archive a game that had been
%% played, replacing an outcome with `withdrawn` and bypassing the retention
%% slice that owns the death of a played game.
an_ended_game_cannot_be_withdrawn() ->
    GameId = started(),
    {ok, _, _, _} = resign(GameId, ?ALICE),
    {error, game_ended} = withdraw_game_api:handle(#{game_id => GameId,
                                                     caller => ?ALICE}),
    ?assertEqual([], events(GameId, <<"game_archived_v1">>)),
    ?assertEqual(1, length(events(GameId, <<"game_ended_v1">>))).

%%====================================================================
%% Helpers
%%====================================================================

born() ->
    {ok, _, [Event], _} = initiate_game_api:handle(
                            #{time_control => {60000, 0}, initiator => ?ALICE}),
    maps:get(game_id, Event).

%% The test speaks the wire (mcl-om#31): the request is authored the way a
%% client writes it, delivered with text keys and a RAW 32-byte caller, and read
%% back as the client reads it. The reply is the ended state in text.
a_resignation_over_the_wire_is_read_and_answered_in_text() ->
    GameId = started(),
    View = mcl_om_wire_test:call(resign_game_responder_v1,
                                 #{game_id => GameId},
                                 ?ALICE_RAW),
    ?assertEqual(<<"resignation">>, maps:get(<<"end_reason">>, View)),
    ?assertEqual(<<"forfeit">>, maps:get(<<"outcome">>, View)),
    %% The resigner is the wire's caller in hex, not the 32 raw bytes.
    ?assertEqual(?ALICE, maps:get(<<"initiator">>, View)).

started() ->
    GameId = born(),
    {ok, _, _, _} = claim(GameId, ?ALICE, <<"w">>),
    {ok, _, _, _} = claim(GameId, ?BOB, <<"b">>),
    %% No policy runs in this suite, so the start is dispatched here.
    {ok, _, _, _} = start_game_api:handle(#{game_id => GameId}),
    GameId.

claim(GameId, NodeId, Color) ->
    claim_seat_api:handle(#{game_id => GameId, caller => NodeId, color => Color}).

resign(GameId, NodeId) ->
    resign_game_api:handle(#{game_id => GameId, caller => NodeId}).

events(GameId, Type) ->
    [Event || Event <- play_games_test_store:stream(GameId),
              Event#event.event_type =:= Type].

data_of(#event{data = Data}) when is_map(Data) -> Data;
data_of(#{data := Data}) when is_map(Data) -> Data;
data_of(Event) -> Event.
