%% @doc The birth slice, end to end: initiate_game_v1 through the real store.
%%
%% What this pins: the game id is a valid reckon stream id minted by evoq's
%% own seam, the event is the full initial state, the caller gets that state
%% back with no follow-up query, and a bad time control never reaches the
%% aggregate.
-module(initiate_game_tests).

-include_lib("eunit/include/eunit.hrl").

-define(INITIATOR, <<"a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90">>).
%% The caller as macula actually delivers it: the raw 32-byte node id, whose
%% hex form is ?INITIATOR_HEX. One is the wire, the other is what this service
%% stores; the boundary between them is mcl_chess_wire:caller/1.
-define(INITIATOR_RAW, crypto:hash(sha256, <<"initiate-game-tests initiator">>)).
-define(INITIATOR_HEX, binary:encode_hex(?INITIATOR_RAW, lowercase)).
-define(STRANGER_A, <<"b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1">>).
-define(STRANGER_B, <<"c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2">>).

store_test_() ->
    {setup, fun play_games_test_store:start/0, fun play_games_test_store:stop/1,
     [{timeout, 60, fun a_game_is_born_with_its_whole_state/0},
      {timeout, 60, fun the_caller_gets_the_state_the_event_produced/0},
      {timeout, 60, fun the_game_id_is_minted_in_the_store_contract/0},
      {timeout, 60, fun two_games_get_two_ids/0},
      {timeout, 60, fun an_initiated_game_cannot_be_initiated_again/0},
      {timeout, 60, fun a_caller_cannot_preassign_the_seats/0}]}.

pure_test_() ->
    [fun a_control_shorter_than_a_second_is_refused/0,
     fun a_control_past_a_day_is_refused/0,
     fun a_zero_increment_is_legal/0,
     fun the_wire_request_builds_a_command/0,
     fun an_empty_wire_request_is_refused_in_text/0].

a_game_is_born_with_its_whole_state() ->
    GameId = initiated(60000, 2000),
    ?assertEqual([<<"game_initiated_v1">>], play_games_test_store:strings(GameId)).

the_caller_gets_the_state_the_event_produced() ->
    {ok, _Version, [Event], View} = initiate_game_api:handle(
                                      #{time_control => {300000, 5000},
                                        initiator => ?INITIATOR}),
    GameId = maps:get(game_id, Event),
    %% The reply is the state the event produced, so the caller needs no
    %% follow-up query (session-level consistency).
    ?assertEqual(GameId, maps:get(<<"game_id">>, View)),
    ?assertEqual(3, maps:get(<<"status">>, View)),
    ?assertEqual(game_status:to_string(3), maps:get(<<"status_label">>, View)),
    ?assertEqual(?INITIATOR, maps:get(<<"initiator">>, View)),
    ?assertEqual(#{<<"initial_ms">> => 300000, <<"increment_ms">> => 5000},
                 maps:get(<<"time_control">>, View)),
    ?assertEqual(#{<<"white">> => <<>>, <<"black">> => <<>>},
                 maps:get(<<"seats">>, View)).

the_game_id_is_minted_in_the_store_contract() ->
    GameId = initiate_game_v1:mint_game_id(),
    ?assertEqual(ok, reckon_gater_stream_id:validate(GameId)),
    ?assertEqual(<<"game">>, reckon_gater_stream_id:prefix_of(GameId)).

two_games_get_two_ids() ->
    First = initiated(60000, 0),
    Second = initiated(60000, 0),
    ?assertNotEqual(First, Second).

an_initiated_game_cannot_be_initiated_again() ->
    GameId = initiated(60000, 0),
    {ok, Cmd} = initiate_game_v1:new(#{game_id => GameId,
                                       time_control => {60000, 0},
                                       initiator => ?INITIATOR}),
    ?assertEqual({error, already_initiated}, maybe_initiate_game:dispatch(Cmd)).

%% Consent is a seat claim, so a body that names two node ids has not asked
%% them and must not seat them: the born game has two empty seats whatever
%% the caller sent. Pre-assignment is the future matchmaker's path, and it
%% will need its own authorization when it is built.
%%
%% THE TEST SPEAKS THE WIRE (mcl-om#31). The request is authored the way a
%% client writes one, and `mcl_om_wire_test:call/3' delivers it as text keys
%% and the RAW 32-byte caller a station produces, puts the reply through the
%% check macula runs before answering, and hands back the client's own view. A
%% test fed the shape the handler happens to expect stays green while every
%% real caller is refused, which is how 0.7.1 shipped answering invalid_params
%% to everyone (mcl-chess#10).
a_caller_cannot_preassign_the_seats() ->
    View = mcl_om_wire_test:call(
             initiate_game_responder_v1,
             #{time_control => #{initial_ms => 60000, increment_ms => 0},
               seats => #{white => ?STRANGER_A, black => ?STRANGER_B}},
             ?INITIATOR_RAW),
    ?assertEqual(#{<<"white">> => <<>>, <<"black">> => <<>>},
                 maps:get(<<"seats">>, View)),
    %% The initiator is the wire's caller in hex, and the reply's text fields
    %% reach the client as text rather than as opaque byte strings.
    ?assertEqual(?INITIATOR_HEX, maps:get(<<"initiator">>, View)),
    ?assertMatch(<<"game-", _/binary>>, maps:get(<<"game_id">>, View)).

%% A request with nothing in it is refused by name, and the refusal itself
%% goes out as text: a caller must be able to read the reason.
an_empty_wire_request_is_refused_in_text() ->
    ?assertEqual(#{<<"error">> => <<"invalid_time_control">>},
                 mcl_om_wire_test:call(initiate_game_responder_v1, #{}, ?INITIATOR_RAW)).

a_control_shorter_than_a_second_is_refused() ->
    ?assertEqual({error, initial_ms_out_of_range},
                 initiate_game_v1:validate_time_control({999, 0})).

a_control_past_a_day_is_refused() ->
    ?assertEqual({error, initial_ms_out_of_range},
                 initiate_game_v1:validate_time_control({86400001, 0})),
    ?assertEqual({error, increment_ms_out_of_range},
                 initiate_game_v1:validate_time_control({60000, 86400001})).

a_zero_increment_is_legal() ->
    ?assertEqual(ok, initiate_game_v1:validate_time_control({60000, 0})),
    ?assertEqual(ok, initiate_game_v1:validate_time_control({1000, 86400000})).

the_wire_request_builds_a_command() ->
    {ok, Cmd} = initiate_game_v1:new(#{game_id => initiate_game_v1:mint_game_id(),
                                       time_control => {60000, 1000},
                                       initiator => ?INITIATOR}),
    ?assertEqual(ok, initiate_game_v1:validate(Cmd)).

%%====================================================================
%% Helpers
%%====================================================================

initiated(Initial, Increment) ->
    {ok, _Version, [Event], _View} = initiate_game_api:handle(
                                       #{time_control => {Initial, Increment},
                                         initiator => ?INITIATOR}),
    ?assertEqual(<<"game_initiated_v1">>, maps:get(event_type, Event)),
    maps:get(game_id, Event).
