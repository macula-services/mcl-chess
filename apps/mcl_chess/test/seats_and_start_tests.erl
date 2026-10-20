%% @doc Seats and start, end to end: two agents seat themselves and the game
%% starts with nobody asking it to.
%%
%% The whole chain a real pair of agents drives: initiate_game_v1, claim_seat_v1
%% twice (once per agent, each seat its own), the seats-full policy dispatching
%% start_game_v1 by itself, the projections writing the read model, the query
%% desk answering, and the facts on the mesh. The mesh is mecked exactly as the
%% WP2 walk does: the topic and the shape are real, only the network is not.
-module(seats_and_start_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("reckon_gater/include/reckon_gater_types.hrl").

-define(INITIATOR, <<"a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90">>).
-define(OPPONENT, <<"b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1">>).
-define(COLLECTOR, mcl_chess_start_test_collector).

seats_and_start_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     [{timeout, 90, fun two_agents_seat_themselves_and_the_game_starts/0},
      {timeout, 90, fun the_started_fact_reaches_the_mesh/0},
      {timeout, 90, fun a_refused_claim_is_a_fact_too/0},
      {timeout, 90, fun the_query_answers_a_started_game/0}]}.

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
                                          on_seat_claimed_v1_maybe_start_game,
                                          game_initiated_v1_to_sqlite_games,
                                          seat_claimed_v1_to_sqlite_games,
                                          game_started_v1_to_sqlite_games]],
    collector_clear(),
    {Dir, Started, Sub, ReadModel, Query, Handlers, Collector}.

cleanup({Dir, Started, Sub, ReadModel, Query, Handlers, Collector}) ->
    [stop(P) || P <- [Sub, ReadModel, Query | Handlers]],
    Collector ! stop,
    catch unregister(?COLLECTOR),
    meck:unload([mcl_om, macula]),
    play_games_test_store:stop({Dir, Started}).

two_agents_seat_themselves_and_the_game_starts() ->
    GameId = born(),
    {ok, _, _, _} = claim(GameId, ?INITIATOR, <<"w">>),
    {ok, _, _, _} = claim(GameId, ?OPPONENT, <<"b">>),
    %% Nobody dispatches start_game: the policy does, off the second claim.
    events = await_event(GameId, <<"game_started_v1">>, 200),
    ?assertEqual([<<"game_initiated_v1">>, <<"seat_claimed_v1">>,
                  <<"seat_claimed_v1">>, <<"game_started_v1">>],
                 play_games_test_store:strings(GameId)).

the_started_fact_reaches_the_mesh() ->
    GameId = started_game(),
    Facts = collector_take(GameId, 4, 200),
    Started = fact_on(Facts, <<"game_started_v1">>),
    ?assertEqual(<<"io.macula/mcl-chess/chess/game/game_started_v1">>,
                 topic_of(Started)),
    Payload = fact_of(Started),
    ?assertEqual({text, GameId}, maps:get(game_id, Payload)),
    ?assertEqual({text, ?INITIATOR}, maps:get(white_node_id, Payload)),
    ?assertEqual({text, ?OPPONENT}, maps:get(black_node_id, Payload)),
    ?assertEqual(5, maps:get(status, Payload)).

a_refused_claim_is_a_fact_too() ->
    GameId = born(),
    {ok, _, _, _} = claim(GameId, ?INITIATOR, <<"w">>),
    {error, seat_taken} = claim(GameId, ?OPPONENT, <<"w">>),
    Facts = collector_take(GameId, 3, 200),
    Refused = fact_on(Facts, <<"seat_refused_v1">>),
    ?assertEqual(<<"io.macula/mcl-chess/chess/game/seat_refused_v1">>,
                 topic_of(Refused)),
    Payload = fact_of(Refused),
    ?assertEqual({text, ?OPPONENT}, maps:get(player_node_id, Payload)),
    ?assertEqual({text, <<"w">>}, maps:get(color, Payload)),
    ?assertEqual({text, <<"seat_taken">>}, maps:get(reason, Payload)).

the_query_answers_a_started_game() ->
    GameId = started_game(),
    Row = await_row(GameId, 200),
    ?assertEqual(GameId, maps:get(<<"game_id">>, Row)),
    ?assertEqual(#{<<"white">> => ?INITIATOR, <<"black">> => ?OPPONENT},
                 maps:get(<<"seats">>, Row)),
    ?assertEqual(5, maps:get(<<"status">>, Row)),
    ?assertEqual(<<"initiated, started">>, maps:get(<<"status_label">>, Row)),
    %% Since when: the read model answers with the moment game_started_v1
    %% recorded, so a reader needs neither the event stream nor a guess
    %% (mcl-chess#3).
    ?assertEqual(started_at(GameId), maps:get(<<"started_at">>, Row)).

%% The start time as the store holds it, taken from the event rather than from
%% the clock of whoever is reading.
started_at(GameId) ->
    [Event] = [E || #event{event_type = Type} = E
                        <- play_games_test_store:stream(GameId),
                    Type =:= <<"game_started_v1">>],
    maps:get(at_ms, data_of(Event)).

data_of(#event{data = Data}) when is_map(Data) -> Data;
data_of(#{data := Data}) when is_map(Data) -> Data;
data_of(Event) -> Event.

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

await_event(GameId, EventType, Tries) ->
    case lists:member(EventType, play_games_test_store:strings(GameId)) of
        true -> events;
        false -> retry_event(GameId, EventType, Tries)
    end.

retry_event(_GameId, EventType, 0) -> error({event_never_appeared, EventType});
retry_event(GameId, EventType, Tries) ->
    timer:sleep(20),
    await_event(GameId, EventType, Tries - 1).

%% The read model is written by the projection, so it arrives a moment after
%% the event. Wait for the status the start produced rather than a guessed
%% interval.
await_row(GameId, Tries) ->
    case get_game_by_id:find(GameId) of
        {ok, Row} ->
            arrived(Row, GameId, Tries);
        {error, not_found} ->
            timer:sleep(20),
            await_row(GameId, Tries - 1);
        {error, _} = Error ->
            error(Error)
    end.

arrived(Row, GameId, Tries) when Tries > 0 ->
    case maps:get(<<"status">>, Row) of
        5 -> Row;
        _ -> timer:sleep(20), await_row(GameId, Tries - 1)
    end;
arrived(Row, _GameId, 0) ->
    error({read_model_never_started, Row}).

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

fact_on(Facts, EventName) ->
    [Fact] = [F || F <- Facts, binary:match(topic_of(F), EventName) =/= nomatch],
    Fact.

start_handler(Module) ->
    {ok, Pid} = evoq_event_handler:start_link(Module, #{}),
    unlink(Pid),
    Pid.

stop(Pid) ->
    unlink(Pid),
    MRef = erlang:monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', MRef, process, Pid, _} -> ok after 2000 -> ok end.
