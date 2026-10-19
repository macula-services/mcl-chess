%% @doc The move slice, end to end: submit_move_v1 through the real store.
%%
%% What this pins: a move is played by the seat that holds the game and is to
%% move, a refusal from a player who is IN the game is recorded as evidence
%% (bounded by the one refusal counter), a caller with no standing records
%% nothing, and the event carries everything the end policy decides on: the
%% position, the referee's halfmove count and how often this position has
%% occurred.
%%
%% The clock arithmetic is pinned separately, against the state directly, because
%% a test that sleeps for a millisecond is a test that fails on a busy machine.
-module(submit_move_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("reckon_gater/include/reckon_gater_types.hrl").

-define(ALICE, <<"a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90">>).
-define(BOB, <<"b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1">>).
-define(CAROL, <<"c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2">>).
-define(START, <<"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1">>).
-define(GAME, <<"game-01a155d187887b2d9828309b42952c86">>).

store_test_() ->
    {setup, fun play_games_test_store:start/0, fun play_games_test_store:stop/1,
     [{timeout, 60, fun the_seat_to_move_plays_its_move/0},
      {timeout, 60, fun the_event_carries_the_whole_position/0},
      {timeout, 60, fun the_move_belongs_to_the_caller_not_the_body/0},
      {timeout, 60, fun an_out_of_turn_move_is_refused_and_recorded/0},
      {timeout, 60, fun an_illegal_move_is_refused_and_recorded/0},
      {timeout, 60, fun a_stranger_records_nothing/0},
      {timeout, 60, fun a_move_before_the_start_records_nothing/0},
      {timeout, 60, fun a_move_on_an_archived_game_records_nothing/0},
      {timeout, 60, fun a_move_after_the_end_is_refused_and_recorded/0},
      {timeout, 60, fun the_halfmove_counter_resets_on_a_pawn_move/0},
      {timeout, 60, fun the_halfmove_counter_climbs_on_quiet_moves/0},
      {timeout, 60, fun a_repeated_position_is_counted/0},
      {timeout, 60, fun a_mover_cannot_grow_the_stream_without_bound/0}]}.

the_seat_to_move_plays_its_move() ->
    GameId = started(),
    {ok, _Version, [Played], View} = move(GameId, ?ALICE, <<"e2e4">>),
    ?assertEqual(<<"move_played_v1">>, maps:get(event_type, Played)),
    ?assertEqual(<<"rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1">>,
                 maps:get(<<"position">>, View)),
    ?assertEqual(<<"b">>, maps:get(<<"to_move">>, View)),
    ?assertEqual(1, maps:get(<<"ply">>, View)),
    ?assertEqual([<<"game_initiated_v1">>, <<"seat_claimed_v1">>,
                  <<"seat_claimed_v1">>, <<"game_started_v1">>,
                  <<"move_played_v1">>],
                 play_games_test_store:strings(GameId)).

the_event_carries_the_whole_position() ->
    %% One event, one read: a projection, a clock instance or a replay never
    %% needs a second stream to interpret this.
    GameId = started(),
    {ok, _, [Played], _} = move(GameId, ?ALICE, <<"g1f3">>),
    Data = data_of(Played),
    ?assertEqual(<<"g1f3">>, maps:get(move, Data)),
    ?assertEqual(1, maps:get(ply, Data)),
    ?assertEqual(<<"b">>, maps:get(to_move, Data)),
    ?assertEqual(1, maps:get(halfmove_clock, Data)),
    ?assertEqual(1, maps:get(repetitions, Data)),
    ?assert(is_integer(maps:get(position_hash, Data))),
    ?assertEqual(#{white => ?ALICE, black => ?BOB}, started_seats(GameId)),
    ?assert(is_integer(maps:get(at_ms, Data))).

the_move_belongs_to_the_caller_not_the_body() ->
    %% BOB is seated but it is white's turn. A body naming ALICE changes
    %% nothing: the caller is the node macula verified.
    GameId = started(),
    {error, out_of_turn} =
        submit_move_api:handle(#{game_id => GameId,
                                 caller => ?BOB,
                                 move => <<"e7e5">>,
                                 player_node_id => ?ALICE}),
    [Refused] = events(GameId, <<"move_refused_v1">>),
    ?assertEqual(?BOB, maps:get(player_node_id, data_of(Refused))),
    ?assertEqual(<<"e7e5">>, maps:get(move, data_of(Refused))).

an_out_of_turn_move_is_refused_and_recorded() ->
    GameId = started(),
    {error, out_of_turn} = move(GameId, ?BOB, <<"e7e5">>),
    [?assertEqual(out_of_turn, maps:get(reason, data_of(E)))
     || E <- events(GameId, <<"move_refused_v1">>)],
    %% Nothing moved: a refusal is not a turn.
    ?assertEqual([], events(GameId, <<"move_played_v1">>)).

an_illegal_move_is_refused_and_recorded() ->
    GameId = started(),
    {error, illegal_move} = move(GameId, ?ALICE, <<"e1e8">>),
    {error, invalid_move} = move(GameId, ?ALICE, <<"nonsense">>),
    ?assertEqual([illegal_move, invalid_move],
                 [maps:get(reason, data_of(E))
                  || E <- events(GameId, <<"move_refused_v1">>)]).

a_stranger_records_nothing() ->
    GameId = started(),
    {error, not_a_player} = move(GameId, ?CAROL, <<"e2e4">>),
    ?assertEqual([<<"game_initiated_v1">>, <<"seat_claimed_v1">>,
                  <<"seat_claimed_v1">>, <<"game_started_v1">>],
                 play_games_test_store:strings(GameId)).

a_move_before_the_start_records_nothing() ->
    GameId = born(),
    {ok, _, _, _} = claim(GameId, ?ALICE, <<"w">>),
    {error, not_started} = move(GameId, ?ALICE, <<"e2e4">>),
    ?assertEqual([<<"game_initiated_v1">>, <<"seat_claimed_v1">>],
                 play_games_test_store:strings(GameId)).

a_move_on_an_archived_game_records_nothing() ->
    GameId = born(),
    {ok, _, _, _} = withdraw_game_api:handle(#{game_id => GameId, caller => ?ALICE}),
    {error, game_archived} = move(GameId, ?ALICE, <<"e2e4">>),
    ?assertEqual([<<"game_initiated_v1">>, <<"game_archived_v1">>],
                 play_games_test_store:strings(GameId)).

a_move_after_the_end_is_refused_and_recorded() ->
    %% A seat holder moving in a game that is over is trying something, and the
    %% design of record names it as evidence.
    GameId = started(),
    {ok, _, _, _} = resign_game_api:handle(#{game_id => GameId, caller => ?BOB}),
    {error, game_ended} = move(GameId, ?ALICE, <<"e2e4">>),
    [Refused] = events(GameId, <<"move_refused_v1">>),
    ?assertEqual(game_ended, maps:get(reason, data_of(Refused))),
    ?assertEqual(?ALICE, maps:get(player_node_id, data_of(Refused))).

the_halfmove_counter_resets_on_a_pawn_move() ->
    GameId = started(),
    {ok, _, _, _} = move(GameId, ?ALICE, <<"g1f3">>),
    {ok, _, _, _} = move(GameId, ?BOB, <<"g8f6">>),
    {ok, _, [Played], _} = move(GameId, ?ALICE, <<"e2e4">>),
    ?assertEqual(0, maps:get(halfmove_clock, data_of(Played))).

the_halfmove_counter_climbs_on_quiet_moves() ->
    GameId = started(),
    {ok, _, _, _} = move(GameId, ?ALICE, <<"g1f3">>),
    {ok, _, [Played], _} = move(GameId, ?BOB, <<"g8f6">>),
    ?assertEqual(2, maps:get(halfmove_clock, data_of(Played))).

a_repeated_position_is_counted() ->
    %% Knights out and back: after four moves the game stands in its own start
    %% position again, and after a fifth it is in the position the first move
    %% produced. The count is per position, and it is what the fivefold draw
    %% reads.
    GameId = started(),
    [{ok, _, _, _} = move(GameId, Who, Uci) || {Who, Uci} <- [
        {?ALICE, <<"g1f3">>}, {?BOB, <<"g8f6">>},
        {?ALICE, <<"f3g1">>}, {?BOB, <<"f6g8">>}]],
    {ok, _, [Returned], _} = move(GameId, ?ALICE, <<"g1f3">>),
    ?assertEqual(2, maps:get(repetitions, data_of(Returned))),
    %% The start position itself is in the history: the event that began the
    %% game recorded it, so a count that began at the first move would miss one.
    Started = data_of(hd(events(GameId, <<"game_started_v1">>))),
    ?assert(is_integer(maps:get(position_hash, Started))).

a_mover_cannot_grow_the_stream_without_bound() ->
    %% The same cap the seat refusals use: ten per player per game, and the
    %% eleventh attempt is still answered the same way and writes nothing.
    GameId = started(),
    [begin {error, illegal_move} = move(GameId, ?ALICE, <<"e1e8">>) end
     || _ <- lists:seq(1, 10)],
    {error, illegal_move} = move(GameId, ?ALICE, <<"e1e8">>),
    ?assertEqual(10, length(events(GameId, <<"move_refused_v1">>))),
    %% One player spending its ten does not silence the other, once it is that
    %% player's turn.
    {ok, _, _, _} = move(GameId, ?ALICE, <<"e2e4">>),
    {error, illegal_move} = move(GameId, ?BOB, <<"e8e1">>),
    ?assertEqual(11, length(events(GameId, <<"move_refused_v1">>))).

%%====================================================================
%% The clock, pinned against the state rather than against the wall clock
%%====================================================================

%% A turn costs the time since the last event that changed the game, and pays
%% the increment on top when a move completed.
charge_turn_test() ->
    State = game_state:apply_event(game_state:new(?GAME),
                                   #{event_type => <<"game_started_v1">>,
                                     white_node_id => ?ALICE,
                                     black_node_id => ?BOB,
                                     position => ?START,
                                     position_hash => 7,
                                     to_move => <<"w">>,
                                     ply => 0,
                                     clocks => #{white => 60000, black => 60000},
                                     status => 5,
                                     at_ms => 1000}),
    %% White used 500 ms of the 60 s, and the time control's increment is 0 in
    %% this fixture, so the turn costs exactly the 500 ms.
    ?assertEqual(#{white => 59500, black => 60000},
                 game_state:charge_turn(State, white, 1500, 0)),
    %% With a 1 s increment a completed move pays it back.
    ?assertEqual(#{white => 60500, black => 60000},
                 game_state:charge_turn(State, white, 1500, 1000)),
    %% A turn that ran out is recorded at zero and pays no increment: an
    %% increment is paid for a move, and a flagged player made none.
    ?assertEqual(#{white => 0, black => 60000},
                 game_state:charge_turn(State, white, 61000, 1000)).

%% The counter and the history are folded from the event, not recomputed, so a
%% replay arrives at the same state the live game did. An irreversible move
%% starts the history again, because no earlier position can recur.
the_history_is_trimmed_at_an_irreversible_move_test() ->
    ?assertEqual([9, 8, 7], game_state:advance_hashes([8, 7], 3, 9)),
    ?assertEqual([9], game_state:advance_hashes([8, 7], 0, 9)),
    ?assertEqual(2, game_state:occurrences([9, 8, 9, 7], 9)).

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
    {ok, _, _, _} = start_game_api:handle(#{game_id => GameId}),
    GameId.

claim(GameId, NodeId, Color) ->
    claim_seat_api:handle(#{game_id => GameId, caller => NodeId, color => Color}).

move(GameId, NodeId, Uci) ->
    submit_move_api:handle(#{game_id => GameId, caller => NodeId, move => Uci}).

started_seats(GameId) ->
    Data = data_of(hd(events(GameId, <<"game_started_v1">>))),
    #{white => maps:get(white_node_id, Data),
      black => maps:get(black_node_id, Data)}.

events(GameId, Type) ->
    [Event || Event <- play_games_test_store:stream(GameId),
              Event#event.event_type =:= Type].

data_of(#event{data = Data}) when is_map(Data) -> Data;
data_of(#{data := Data}) when is_map(Data) -> Data;
data_of(Event) -> Event.
