%% @doc The death slice, pre-start: withdraw_game_v1 through the real store.
%%
%% A withdraw before the game began is not an end. It archives the game with
%% reason `withdrawn', clears OPEN, keeps INITIATED, and only the initiator
%% may do it. Every refusal here is answered on the wire and records nothing:
%% none of them is evidence about a player's conduct.
-module(withdraw_game_tests).

-include_lib("eunit/include/eunit.hrl").

%% The caller as macula actually delivers it (the raw 32-byte node id) and as
%% this service stores it (hex). A 64-hex caller cannot tell the two apart
%% (mcl-chess#10).
-define(INITIATOR_RAW, crypto:hash(sha256, <<"withdraw-tests initiator">>)).
-define(INITIATOR, binary:encode_hex(?INITIATOR_RAW, lowercase)).
-define(STRANGER, <<"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff">>).

store_test_() ->
    {setup, fun play_games_test_store:start/0, fun play_games_test_store:stop/1,
     [{timeout, 60, fun the_initiator_withdraws_a_game_before_it_starts/0},
      {timeout, 60, fun a_stranger_cannot_withdraw_someone_elses_game/0},
      {timeout, 60, fun an_archived_game_cannot_be_withdrawn_again/0},
      {timeout, 60, fun a_withdrawn_game_is_not_an_ended_game/0},
      {timeout, 60, fun a_withdraw_over_the_wire_is_read_and_answered_in_text/0}]}.

the_initiator_withdraws_a_game_before_it_starts() ->
    GameId = initiated(),
    {ok, _Version, [Event], View} = withdraw_game_api:handle(
                                     #{game_id => GameId, caller => ?INITIATOR}),
    ?assertEqual(<<"game_archived_v1">>, maps:get(event_type, Event)),
    ?assertEqual(<<"withdrawn">>, maps:get(reason, Event)),
    ?assertEqual([<<"game_initiated_v1">>, <<"game_archived_v1">>],
                 play_games_test_store:strings(GameId)),
    ?assertEqual(17, maps:get(<<"status">>, View)),
    ?assertEqual(game_status:to_string(17), maps:get(<<"status_label">>, View)).

a_stranger_cannot_withdraw_someone_elses_game() ->
    GameId = initiated(),
    ?assertEqual({error, not_initiator},
                 withdraw_game_api:handle(#{game_id => GameId, caller => ?STRANGER})),
    %% Nothing was recorded: a refusal without standing leaves no trace.
    ?assertEqual([<<"game_initiated_v1">>], play_games_test_store:strings(GameId)).

an_archived_game_cannot_be_withdrawn_again() ->
    GameId = initiated(),
    {ok, _, _, _} = withdraw_game_api:handle(#{game_id => GameId,
                                               caller => ?INITIATOR}),
    ?assertEqual({error, game_archived},
                 withdraw_game_api:handle(#{game_id => GameId,
                                            caller => ?INITIATOR})).

a_withdrawn_game_is_not_an_ended_game() ->
    GameId = initiated(),
    {ok, _, _, View} = withdraw_game_api:handle(#{game_id => GameId,
                                                  caller => ?INITIATOR}),
    %% ENDED is 8 and STARTED is 4: a pre-start withdraw sets neither, because
    %% the game never existed as play.
    Status = maps:get(<<"status">>, View),
    ?assertEqual(0, Status band 8),
    ?assertEqual(0, Status band 4),
    ?assertEqual(1, Status band 1).

%%====================================================================
%% Helpers
%%====================================================================

%% The shape the wire delivers: text keys as `{text, Bin}', the caller under the
%% atom key and as the raw node id. The reply is the archived state in text, and
%% a payload macula will actually put on the wire.
a_withdraw_over_the_wire_is_read_and_answered_in_text() ->
    GameId = initiated(),
    Payload = #{{text, <<"game_id">>} => {text, GameId},
                caller => ?INITIATOR_RAW},
    {reply, View, _State} = withdraw_game_responder_v1:handle_request(Payload, undefined),
    %% Archived is not ended: INITIATED stays, ENDED is not set, and the label
    %% goes out as text.
    Status = maps:get(<<"status">>, View),
    ?assertEqual(1, Status band 1),
    ?assertEqual(0, Status band 8),
    ?assertMatch({text, _}, maps:get(<<"status_label">>, View)),
    ?assertEqual(ok, macula_frame:check_payload(View)),
    %% The initiator is the wire's caller in hex, not the 32 raw bytes.
    ?assertEqual({text, ?INITIATOR}, maps:get(<<"initiator">>, View)).

initiated() ->
    {ok, _Version, [Event], _View} = initiate_game_api:handle(
                                       #{time_control => {60000, 0},
                                         initiator => ?INITIATOR}),
    maps:get(game_id, Event).
