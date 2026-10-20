%% @doc The seat slice, end to end: claim_seat_v1 through the real store.
%%
%% What this pins: a seat belongs to the caller the wire verified, first claim
%% wins that colour, a taken or full seat is REFUSED but RECORDED (claims are
%% how matchmaking observes demand, and a claimant is bounded where a move
%% spammer is not), and a refusal with no standing grows no stream.
%%
%% Every event carries the seats map after the claim, so a projection or a
%% replay reads one event and never a read model.
-module(claim_seat_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("reckon_gater/include/reckon_gater_types.hrl").

%% The caller as macula actually delivers it, and as this service stores it:
%% macula verifies a call and injects the RAW 32-byte node id, and the service
%% keeps the hex form (mcl_chess_wire:caller/1). One test below sends the raw
%% one and expects the hex one back, because a 64-hex caller cannot tell the
%% two apart and hid a fault that refused every real caller (mcl-chess#10).
-define(ALICE_RAW, crypto:hash(sha256, <<"claim-seat-tests alice">>)).
-define(ALICE, binary:encode_hex(?ALICE_RAW, lowercase)).
-define(BOB, <<"b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1">>).
-define(CAROL, <<"c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2">>).

store_test_() ->
    {setup, fun play_games_test_store:start/0, fun play_games_test_store:stop/1,
     [{timeout, 60, fun the_claimer_takes_the_colour_it_asked_for/0},
      {timeout, 60, fun the_second_seat_goes_to_the_second_caller/0},
      {timeout, 60, fun the_initiator_is_not_pinned_to_white/0},
      {timeout, 60, fun a_taken_colour_is_refused_and_recorded/0},
      {timeout, 60, fun a_full_game_refuses_the_third_claimer/0},
      {timeout, 60, fun a_node_cannot_hold_both_seats/0},
      {timeout, 60, fun a_claim_on_a_game_that_does_not_exist_records_nothing/0},
      {timeout, 60, fun a_claim_on_an_archived_game_records_nothing/0},
      {timeout, 60, fun a_caller_cannot_seat_another_node_from_the_body/0},
      {timeout, 60, fun an_unknown_colour_is_refused_without_an_event/0},
      {timeout, 60, fun the_seats_map_is_the_whole_state_after_the_claim/0},
      {timeout, 60, fun a_stranger_cannot_grow_the_stream_without_bound/0},
      {timeout, 60, fun the_refusal_cap_is_per_player_not_per_game/0},
      {timeout, 60, fun the_refusal_count_survives_a_snapshot/0}]}.

the_claimer_takes_the_colour_it_asked_for() ->
    GameId = born(),
    {ok, _Version, [Claimed], View} = claim(GameId, ?ALICE, <<"w">>),
    ?assertEqual(<<"seat_claimed_v1">>, maps:get(event_type, Claimed)),
    ?assertEqual(?ALICE, maps:get(<<"white">>, maps:get(<<"seats">>, View))),
    ?assertEqual(<<>>, maps:get(<<"black">>, maps:get(<<"seats">>, View))),
    %% The stream holds birth then claim, in that order.
    ?assertEqual([<<"game_initiated_v1">>, <<"seat_claimed_v1">>],
                 play_games_test_store:strings(GameId)).

the_second_seat_goes_to_the_second_caller() ->
    GameId = born(),
    {ok, _, _, _} = claim(GameId, ?ALICE, <<"w">>),
    {ok, _, _, View} = claim(GameId, ?BOB, <<"b">>),
    ?assertEqual(#{<<"white">> => ?ALICE, <<"black">> => ?BOB},
                 maps:get(<<"seats">>, View)),
    %% A claim does not start the game by itself: that is the policy's job and
    %% its own suite proves it.
    ?assertEqual(3, maps:get(<<"status">>, View)).

the_initiator_is_not_pinned_to_white() ->
    %% Born by ALICE, and BOB takes white first.
    GameId = born(),
    {ok, _, _, View} = claim(GameId, ?BOB, <<"w">>),
    ?assertEqual(?BOB, maps:get(<<"white">>, maps:get(<<"seats">>, View))).

a_taken_colour_is_refused_and_recorded() ->
    GameId = born(),
    {ok, _, _, _} = claim(GameId, ?ALICE, <<"w">>),
    {error, seat_taken} = claim(GameId, ?BOB, <<"w">>),
    %% The refusal is evidence, so it is on the stream.
    ?assertEqual([<<"game_initiated_v1">>, <<"seat_claimed_v1">>,
                  <<"seat_refused_v1">>],
                 play_games_test_store:strings(GameId)),
    [Refused] = refused_events(GameId),
    ?assertEqual(#{player_node_id => ?BOB, color => <<"w">>, reason => seat_taken},
                 picked([player_node_id, color, reason], data_of(Refused))).

a_full_game_refuses_the_third_claimer() ->
    GameId = born(),
    {ok, _, _, _} = claim(GameId, ?ALICE, <<"w">>),
    {ok, _, _, _} = claim(GameId, ?BOB, <<"b">>),
    {error, game_full} = claim(GameId, ?CAROL, <<"w">>),
    [Refused] = refused_events(GameId),
    ?assertEqual(#{player_node_id => ?CAROL, reason => game_full},
                 picked([player_node_id, reason], data_of(Refused))).

a_node_cannot_hold_both_seats() ->
    GameId = born(),
    {ok, _, _, _} = claim(GameId, ?ALICE, <<"w">>),
    %% Not news, and not a game: consent is one node's one seat. Nothing is
    %% recorded, because no other claimant is involved.
    {error, already_seated} = claim(GameId, ?ALICE, <<"b">>),
    {error, already_seated} = claim(GameId, ?ALICE, <<"w">>),
    ?assertEqual([<<"game_initiated_v1">>, <<"seat_claimed_v1">>],
                 play_games_test_store:strings(GameId)).

a_claim_on_a_game_that_does_not_exist_records_nothing() ->
    %% A stranger must not be able to grow a stream that was never born.
    Ghost = initiate_game_v1:mint_game_id(),
    {error, not_initiated} = claim(Ghost, ?ALICE, <<"w">>),
    ?assertEqual([], play_games_test_store:strings(Ghost)).

a_claim_on_an_archived_game_records_nothing() ->
    GameId = born(),
    {ok, _, _, _} = withdraw_game_api:handle(#{game_id => GameId, caller => ?ALICE}),
    {error, game_archived} = claim(GameId, ?ALICE, <<"w">>),
    ?assertEqual([<<"game_initiated_v1">>, <<"game_archived_v1">>],
                 play_games_test_store:strings(GameId)).

a_caller_cannot_seat_another_node_from_the_body() ->
    %% The R1 rule, carried forward: the seat holder is the node macula
    %% verified on the call, never a node id a body names.
    %%
    %% THE TEST SPEAKS THE WIRE (mcl-om#31): a request authored the way a
    %% client writes it, delivered as text keys and a RAW 32-byte caller, and
    %% read back as the client reads it. A test fed the shape the handler
    %% happens to expect stays green while every real caller is refused
    %% (mcl-chess#10).
    %%
    %% The body names a caller as well as a seat, because a peer that names
    %% itself is the case the platform rule exists for: the helper drops a
    %% body-sent `caller' the way a station does, so a handler that read it
    %% would seat BOB here and fail the assertion below.
    GameId = born(),
    View = mcl_om_wire_test:call(claim_seat_responder_v1,
                                 #{game_id => GameId,
                                   color => <<"w">>,
                                   caller => ?BOB,
                                   player_node_id => ?BOB,
                                   node_id => ?BOB},
                                 ?ALICE_RAW),
    ?assertEqual(?ALICE, maps:get(<<"white">>, maps:get(<<"seats">>, View))),
    %% The colour the caller asked for comes back as text too.
    ?assertEqual(<<"w">>, maps:get(<<"color">>, View)),
    [Claimed] = claimed_events(GameId),
    ?assertEqual(?ALICE, maps:get(player_node_id, data_of(Claimed))).

an_unknown_colour_is_refused_without_an_event() ->
    GameId = born(),
    {error, invalid_color} = claim(GameId, ?ALICE, <<"green">>),
    ?assertEqual([<<"game_initiated_v1">>], play_games_test_store:strings(GameId)).

the_seats_map_is_the_whole_state_after_the_claim() ->
    %% An event that carried only its delta would force a projector to read a
    %% second stream, which the house forbids.
    GameId = born(),
    {ok, _, [Claimed], _} = claim(GameId, ?ALICE, <<"w">>),
    ?assertEqual(#{white => ?ALICE, black => <<>>}, maps:get(seats, Claimed)),
    ?assertEqual(3, maps:get(status, Claimed)),
    ?assert(is_integer(maps:get(at_ms, Claimed))).

%% A RECORDED REFUSAL IS BOUNDED PER PLAYER, AND "NATURALLY BOUNDED BY
%% CLAIMANTS" IS NOT A BOUND. A node that holds no seat is not caught by
%% already_seated, so without a count one stranger can write seat_refused_v1 to
%% a game's stream, and publish the fact, for as long as the game lives. The
%% Design Gate settled the number for this class of evidence (answer 5, N = 10
%% per player per game), and WP5's move_refused_v1 uses the same counter.
a_stranger_cannot_grow_the_stream_without_bound() ->
    GameId = born(),
    {ok, _, _, _} = claim(GameId, ?ALICE, <<"w">>),
    [begin
         {error, seat_taken} = claim(GameId, ?CAROL, <<"w">>)
     end || _ <- lists:seq(1, 10)],
    %% The eleventh is still refused, and writes nothing.
    {error, seat_taken} = claim(GameId, ?CAROL, <<"w">>),
    ?assertEqual(10, length(refused_events(GameId))),
    ?assertEqual([<<"game_initiated_v1">>, <<"seat_claimed_v1">>] ++
                 lists:duplicate(10, <<"seat_refused_v1">>),
                 play_games_test_store:strings(GameId)).

the_refusal_cap_is_per_player_not_per_game() ->
    GameId = born(),
    {ok, _, _, _} = claim(GameId, ?ALICE, <<"w">>),
    [begin {error, seat_taken} = claim(GameId, ?CAROL, <<"w">>) end
     || _ <- lists:seq(1, 10)],
    %% One player spending its ten does not silence another.
    {error, seat_taken} = claim(GameId, ?BOB, <<"w">>),
    ?assertEqual(11, length(refused_events(GameId))).

%% The count is part of the aggregate state, so it has to survive the snapshot
%% the store takes: an aggregate restored from one that forgot the count would
%% start recording again from zero.
the_refusal_count_survives_a_snapshot() ->
    State = game_state:record_refusal(game_state:new(<<"game-01a155d187887b2d9828309b42952c86">>),
                                      ?CAROL),
    {ok, Restored} = game_state:from_map(game_state:to_map(State)),
    ?assertEqual(1, game_state:refusal_count(Restored, ?CAROL)),
    ?assertEqual(0, game_state:refusal_count(Restored, ?BOB)).

%%====================================================================
%% Helpers
%%====================================================================

born() ->
    {ok, _, [Event], _} = initiate_game_api:handle(
                            #{time_control => {60000, 0}, initiator => ?ALICE}),
    maps:get(game_id, Event).

claim(GameId, NodeId, Color) ->
    claim_seat_api:handle(#{game_id => GameId, caller => NodeId, color => Color}).

claimed_events(GameId) ->
    events(GameId, <<"seat_claimed_v1">>).

refused_events(GameId) ->
    events(GameId, <<"seat_refused_v1">>).

events(GameId, Type) ->
    [Event || Event <- play_games_test_store:stream(GameId),
              Event#event.event_type =:= Type].

%% A stored event is a #event{} record carrying its business fields under
%% `data'; an executed event carries them inline. Read whichever is there, as
%% production does.
data_of(#event{data = Data}) when is_map(Data) -> Data;
data_of(#{data := Data}) when is_map(Data) -> Data;
data_of(Event) -> Event.

picked(Keys, Data) -> maps:with(Keys, Data).
