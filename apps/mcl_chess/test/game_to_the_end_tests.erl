%% @doc A game played to its end, end to end: two agents, the real store, the
%% policy, the projections, the query and the facts.
%%
%% What this pins is the whole chain a pair of agents drives. A move goes
%% through the desk into the store; the end policy reads the move event and asks
%% the rules engine; a terminal verdict dispatches the internal end command; the
%% end event is projected, published and answered by the query. The mesh is
%% mecked exactly as the other walks do: the topic and the shape are real, only
%% the network is not.
%%
%% The 75 move rule is driven at the policy, with an event whose halfmove count
%% is the threshold: reaching 150 real halfmoves without repeating a position
%% five times needs a scripted game nobody would recognise, and the verdict
%% itself is pinned in the rules engine's own suite. What is pinned here is that
%% the policy turns that verdict into a draw.
-module(game_to_the_end_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("reckon_gater/include/reckon_gater_types.hrl").

-define(INITIATOR, <<"a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90">>).
-define(OPPONENT, <<"b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1">>).
-define(COLLECTOR, mcl_chess_end_test_collector).
-define(START, <<"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1">>).
-define(FOOLS_MATE, <<"rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3">>).
%% A reader as macula delivers one on the wire: the raw 32-byte node id. Reading
%% a game is open to anyone, so which reader it is does not matter here; that it
%% arrives in the wire's own form does.
-define(READER_RAW, crypto:hash(sha256, <<"game-to-the-end-tests reader">>)).

end_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     [{timeout, 90, fun fools_mate_ends_the_game_and_names_the_winner/0},
      {timeout, 90, fun the_ended_fact_reaches_the_mesh/0},
      {timeout, 90, fun the_read_model_holds_the_finished_game/0},
      {timeout, 90, fun the_read_model_answers_a_wire_shaped_request/0},
      {timeout, 90, fun fivefold_repetition_ends_the_game/0},
      {timeout, 90, fun the_policy_ends_a_game_on_the_seventy_five_move_rule/0},
      {timeout, 90, fun a_game_that_has_not_ended_keeps_playing/0}]}.

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
                                          emit_game_ended_v1_to_mesh,
                                          on_seat_claimed_v1_maybe_start_game,
                                          on_move_played_v1_maybe_end_game,
                                          game_initiated_v1_to_sqlite_games,
                                          seat_claimed_v1_to_sqlite_games,
                                          game_started_v1_to_sqlite_games,
                                          move_played_v1_to_sqlite_games,
                                          game_ended_v1_to_sqlite_games]],
    collector_clear(),
    {Dir, Started, Sub, ReadModel, Query, Handlers, Collector}.

cleanup({Dir, Started, Sub, ReadModel, Query, Handlers, Collector}) ->
    [stop(P) || P <- [Sub, ReadModel, Query | Handlers]],
    Collector ! stop,
    catch unregister(?COLLECTOR),
    meck:unload([mcl_om, macula]),
    play_games_test_store:stop({Dir, Started}).

fools_mate_ends_the_game_and_names_the_winner() ->
    GameId = started_game(),
    play(GameId, [{?INITIATOR, <<"f2f3">>}, {?OPPONENT, <<"e7e5">>},
                  {?INITIATOR, <<"g2g4">>}, {?OPPONENT, <<"d8h4">>}]),
    %% Nobody dispatched end_game: the policy read the last move and ended it.
    events = await_event(GameId, <<"game_ended_v1">>, 200),
    [Ended] = events(GameId, <<"game_ended_v1">>),
    Data = data_of(Ended),
    ?assertEqual(winner, maps:get(outcome, Data)),
    ?assertEqual(?OPPONENT, maps:get(winner_node_id, Data)),
    ?assertEqual(checkmate, maps:get(reason, Data)),
    ?assertEqual(?FOOLS_MATE, maps:get(fen_after, Data)),
    ?assertEqual(9, maps:get(status, Data)),
    ?assertEqual(4, maps:get(ply, Data)).

the_ended_fact_reaches_the_mesh() ->
    GameId = mate_in_four(),
    Facts = collector_take(GameId, 9, 200),
    Ended = fact_on(Facts, <<"game_ended_v1">>),
    ?assertEqual(<<"io.macula/mcl-chess/chess/game/game_ended_v1">>,
                 topic_of(Ended)),
    Payload = fact_of(Ended),
    ?assertEqual({text, <<"winner">>}, maps:get(outcome, Payload)),
    ?assertEqual({text, <<"checkmate">>}, maps:get(reason, Payload)),
    ?assertEqual({text, ?OPPONENT}, maps:get(winner_node_id, Payload)),
    ?assertEqual(9, maps:get(status, Payload)),
    %% The move that produced the mate is a fact of its own, with the counts the
    %% referee judged on.
    First = fact_of(fact_on(Facts, <<"move_played_v1">>)),
    Last = fact_of(last_fact_on(Facts, <<"move_played_v1">>)),
    ?assertEqual({text, <<"f2f3">>}, maps:get(move, First)),
    ?assertEqual({text, <<"d8h4">>}, maps:get(move, Last)),
    MovePayload = Last,
    ?assert(is_integer(maps:get(halfmove_clock, MovePayload))),
    ?assert(is_integer(maps:get(position_hash, MovePayload))).

the_read_model_holds_the_finished_game() ->
    GameId = mate_in_four(),
    Row = await_status(GameId, 9, 200),
    ?assertEqual(<<"winner">>, maps:get(<<"outcome">>, Row)),
    ?assertEqual(<<"checkmate">>, maps:get(<<"end_reason">>, Row)),
    ?assertEqual(?OPPONENT, maps:get(<<"winner">>, Row)),
    ?assertEqual(?FOOLS_MATE, maps:get(<<"position">>, Row)),
    ?assertEqual(4, maps:get(<<"ply">>, Row)),
    ?assertEqual([<<"f2f3">>, <<"e7e5">>, <<"g2g4">>, <<"d8h4">>],
                 maps:get(<<"moves">>, Row)),
    ?assertEqual(<<"initiated, ended">>, maps:get(<<"status_label">>, Row)).

%% The test speaks the wire (mcl-om#31): the request is authored the way a
%% client writes it and delivered with the text keys a station produces, so a
%% responder reading a bare `<<"game_id">>' key answers not_found, as it did to
%% every real read before mcl-chess#10. The reply is read as the client reads
%% it, after the check macula runs before answering, so a reply carrying its
%% text as an opaque byte string fails here rather than on the wire.
the_read_model_answers_a_wire_shaped_request() ->
    GameId = mate_in_four(),
    _ = await_status(GameId, 9, 200),
    View = mcl_om_wire_test:call(get_game_by_id_responder_v1,
                                 #{game_id => GameId},
                                 ?READER_RAW),
    ?assertEqual(?FOOLS_MATE, maps:get(<<"position">>, View)),
    ?assertEqual(<<"checkmate">>, maps:get(<<"end_reason">>, View)),
    ?assertEqual(<<"winner">>, maps:get(<<"outcome">>, View)),
    ?assertEqual(4, maps:get(<<"ply">>, View)).

fivefold_repetition_ends_the_game() ->
    %% Knights out and back, four times: after the sixteenth halfmove the game
    %% stands in its start position for the fifth time, which is the automatic
    %% draw (mcl-chess#4). The threefold draw is still a v2 claim, so the game
    %% plays through the earlier repeats.
    GameId = started_game(),
    play(GameId, lists:append(lists:duplicate(4, [{?INITIATOR, <<"g1f3">>},
                                                  {?OPPONENT, <<"g8f6">>},
                                                  {?INITIATOR, <<"f3g1">>},
                                                  {?OPPONENT, <<"f6g8">>}]))),
    events = await_event(GameId, <<"game_ended_v1">>, 200),
    [Ended] = events(GameId, <<"game_ended_v1">>),
    Data = data_of(Ended),
    ?assertEqual(draw, maps:get(outcome, Data)),
    ?assertEqual(fivefold_repetition, maps:get(reason, Data)),
    ?assertEqual(<<>>, maps:get(winner_node_id, Data)),
    ?assertEqual(16, maps:get(ply, Data)),
    %% The board is the one the game started from; the move counter and the
    %% halfmove clock have run, which is what the FEN's last two fields say.
    ?assertEqual(<<"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -">>,
                 first_four(maps:get(fen_after, Data))).

the_policy_ends_a_game_on_the_seventy_five_move_rule() ->
    GameId = started_game(),
    %% The count is the policy's input, and the verdict is the rules engine's:
    %% this asserts the hand-off between them, with the position still playable.
    ?assertEqual({ok, #{}},
                 on_move_played_v1_maybe_end_game:handle_event(
                       <<"move_played_v1">>,
                       #{data => #{game_id => GameId,
                                   fen_after => ?START,
                                   halfmove_clock => 150,
                                   repetitions => 1,
                                   player_node_id => ?INITIATOR}},
                       #{}, #{})),
    events = await_event(GameId, <<"game_ended_v1">>, 200),
    [Ended] = events(GameId, <<"game_ended_v1">>),
    ?assertEqual(draw, maps:get(outcome, data_of(Ended))),
    ?assertEqual(seventy_five_moves, maps:get(reason, data_of(Ended))).

a_game_that_has_not_ended_keeps_playing() ->
    GameId = started_game(),
    play(GameId, [{?INITIATOR, <<"e2e4">>}, {?OPPONENT, <<"e7e5">>}]),
    %% Two quiet moves are not an end, and nothing ended the game behind them.
    ?assertEqual([], events(GameId, <<"game_ended_v1">>)),
    Row = await_moves(GameId, 2, 200),
    ?assertEqual(5, maps:get(<<"status">>, Row)),
    ?assertEqual([<<"e2e4">>, <<"e7e5">>], maps:get(<<"moves">>, Row)).

%%====================================================================
%% Helpers
%%====================================================================

born() ->
    {ok, _, [Event], _} = initiate_game_api:handle(
                            #{time_control => {60000, 0}, initiator => ?INITIATOR}),
    maps:get(game_id, Event).

claim(GameId, NodeId, Color) ->
    claim_seat_api:handle(#{game_id => GameId, caller => NodeId, color => Color}).

started_game() ->
    GameId = born(),
    {ok, _, _, _} = claim(GameId, ?INITIATOR, <<"w">>),
    {ok, _, _, _} = claim(GameId, ?OPPONENT, <<"b">>),
    await_event(GameId, <<"game_started_v1">>, 200),
    GameId.

play(GameId, Moves) ->
    [{ok, _Version, _Events, _View} = submit_move_api:handle(
        #{game_id => GameId, caller => Caller, move => Uci})
     || {Caller, Uci} <- Moves],
    ok.

mate_in_four() ->
    GameId = started_game(),
    play(GameId, [{?INITIATOR, <<"f2f3">>}, {?OPPONENT, <<"e7e5">>},
                  {?INITIATOR, <<"g2g4">>}, {?OPPONENT, <<"d8h4">>}]),
    events = await_event(GameId, <<"game_ended_v1">>, 200),
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

%% The read model is written by the projection, so it arrives a moment after the
%% event. Wait for the state the event produced rather than a guessed interval.
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

await_moves(GameId, Count, Tries) ->
    case get_game_by_id:find(GameId) of
        {ok, #{<<"moves">> := Moves} = Row} when length(Moves) >= Count -> Row;
        {ok, _Row} -> retry_moves(GameId, Count, Tries);
        {error, not_found} -> retry_moves(GameId, Count, Tries);
        {error, _} = Error -> error(Error)
    end.

retry_moves(_GameId, _Count, 0) ->
    error(read_model_never_showed_those_moves);
retry_moves(GameId, Count, Tries) ->
    timer:sleep(20),
    await_moves(GameId, Count, Tries - 1).

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

last_fact_on(Facts, Name) ->
    lists:last([F || F <- Facts, binary:match(topic_of(F), Name) =/= nomatch]).

%% The position part of a FEN: the four fields that say where the pieces stand,
%% whose turn it is, what may still castle and whether an en passant capture is
%% available. The last two fields are counters, and a repetition ignores them.
first_four(Fen) ->
    iolist_to_binary(lists:join(<<" ">>, lists:sublist(
        binary:split(Fen, <<" ">>, [global]), 4))).
