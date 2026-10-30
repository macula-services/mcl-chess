%% @doc The walking skeleton, end to end: birth and death through all three
%% departments, with the facts on the mesh.
%%
%% One test drives the whole slice a caller will drive: initiate_game_v1 into
%% the real reckon-db store, the $all subscription delivering the event to
%% the emitter and the projection, game_archived_v1 the same way, the read
%% model answering, and get_game_by_id returning what the query desk
%% promised. The mesh itself is mecked, exactly as the fleet emitter suites
%% do: the fact's topic and shape are real, only the network is not.
%%
%% No seats, no clock, no rules: that is the point of a skeleton.
-module(walking_skeleton_tests).

-include_lib("eunit/include/eunit.hrl").

-define(INITIATOR, <<"a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90">>).
-define(COLLECTOR, mcl_chess_test_collector).

skeleton_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     [{timeout, 90, fun birth_and_death_walk_end_to_end/0},
      {timeout, 90, fun both_facts_reach_the_mesh/0},
      {timeout, 90, fun the_read_model_answers_after_the_death/0}]}.

setup() ->
    {Dir, Started} = play_games_test_store:start(),
    %% The read model is a separate sqlite file, as it is in the release.
    Sqlite = filename:join(Dir, "mcl_chess.sqlite3"),
    %% eunit runs each test in its own process, so the mesh double cannot send
    %% to `self()' here: it sends to a collector that outlives the setup and
    %% answers whichever test asks.
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
                                          emit_game_archived_v1_to_mesh,
                                          game_lifecycle_to_games]],
    collector_clear(),
    {Dir, Started, Sub, ReadModel, Query, Handlers, Collector}.

cleanup({Dir, Started, Sub, ReadModel, Query, Handlers, Collector}) ->
    [stop(P) || P <- [Sub, ReadModel, Query | Handlers]],
    Collector ! stop,
    catch unregister(?COLLECTOR),
    meck:unload([mcl_om, macula]),
    play_games_test_store:stop({Dir, Started}).

birth_and_death_walk_end_to_end() ->
    GameId = born(),
    {ok, _Version, [Archived], View} = withdraw_game_api:handle(
                                          #{game_id => GameId,
                                            caller => ?INITIATOR}),
    ?assertEqual(<<"game_archived_v1">>, maps:get(event_type, Archived)),
    %% Both events are on the game's own stream, in the order they happened.
    ?assertEqual([<<"game_initiated_v1">>, <<"game_archived_v1">>],
                 play_games_test_store:strings(GameId)),
    %% The death slice ran: OPEN and ENDED are clear, INITIATED and ARCHIVED
    %% are set.
    ?assertEqual(17, maps:get(<<"status">>, View)),
    ?assertEqual(GameId, maps:get(<<"game_id">>, View)).

both_facts_reach_the_mesh() ->
    GameId = born(),
    {ok, _, _, _} = withdraw_game_api:handle(#{game_id => GameId,
                                               caller => ?INITIATOR}),
    Facts = collector_take(GameId, 2, 200),
    Initiated = fact_on(Facts, <<"game_initiated_v1">>),
    Archived = fact_on(Facts, <<"game_archived_v1">>),
    ?assertEqual(<<"io.macula/mcl-chess/chess/game/game_initiated_v1">>,
                 topic_of(Initiated)),
    ?assertEqual(<<"io.macula/mcl-chess/chess/game/game_archived_v1">>,
                 topic_of(Archived)),
    ?assertEqual({text, GameId}, maps:get(game_id, fact_of(Initiated))),
    ?assertEqual({text, <<"withdrawn">>}, maps:get(reason, fact_of(Archived))).

the_read_model_answers_after_the_death() ->
    GameId = born(),
    {ok, _, _, _} = withdraw_game_api:handle(#{game_id => GameId,
                                               caller => ?INITIATOR}),
    Row = await_row(GameId, 200),
    %% A game's label at rest is the mask spelled out: INITIATED never
    %% clears, so an archived game reads "initiated, archived".
    ?assertEqual(<<"initiated, archived">>, label(Row)),
    ?assertEqual(GameId, maps:get(<<"game_id">>, Row)),
    ?assertEqual(17, maps:get(<<"status">>, Row)),
    ?assertEqual(<<"withdrawn">>, maps:get(<<"archive_reason">>, Row)).

%%====================================================================
%% Helpers
%%====================================================================

born() ->
    {ok, _Version, [Event], _View} = initiate_game_api:handle(
                                       #{time_control => {60000, 0},
                                         initiator => ?INITIATOR}),
    maps:get(game_id, Event).

%% The read model is written by the projection, so it arrives a moment after
%% the command returns. Wait for it rather than sleeping a guessed interval.
await_row(GameId, Tries) ->
    case get_game_by_id:find(GameId) of
        {ok, Row} ->
            answered(Row, GameId, Tries);
        {error, not_found} ->
            timer:sleep(20),
            await_row(GameId, Tries - 1);
        {error, _} = Error ->
            error(Error)
    end.

%% The game is born before it is archived, so the row exists with status 3
%% first; wait until the archive projection has caught up. A row that never
%% gets there is a failure, not something to return.
answered(Row, GameId, Tries) when Tries > 0 ->
    case label(Row) of
        <<"initiated, archived">> -> Row;
        _ -> timer:sleep(20), await_row(GameId, Tries - 1)
    end;
answered(Row, _GameId, 0) ->
    error({read_model_never_archived, Row}).

label(Row) ->
    maps:get(<<"status_label">>, Row).

%% A collector process: eunit runs each test in its own process, so the mesh
%% double cannot send to the setup process's mailbox and be heard. The
%% collector is registered and answers a look-up by GAME id, because it
%% outlives one test and an earlier test's fact for another game may still be
%% in it.
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
            %% Non-destructive: one test may look for two facts on the same
            %% game, and the second look must still find the first.
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

%% Wait until at least `Want' facts exist for this game, then hand them back.
collector_take(GameId, Want, Tries) ->
    ?COLLECTOR ! {take, GameId, self()},
    receive
        {taken, Facts} when length(Facts) >= Want -> Facts;
        {taken, _Few} -> collector_retry(GameId, Want, Tries)
    after 2000 ->
        collector_retry(GameId, Want, Tries)
    end.

collector_retry(GameId, _Want, 0) ->
    error({not_enough_facts_published_for, GameId});
collector_retry(GameId, Want, Tries) ->
    timer:sleep(20),
    collector_take(GameId, Want, Tries - 1).

topic_of({Topic, _Fact}) -> Topic.
fact_of({_Topic, Fact}) -> Fact.

%% The one fact on the topic ending in this event name.
fact_on(Facts, EventName) ->
    [Fact] = [F || F <- Facts,
                   binary:match(topic_of(F), EventName) =/= nomatch],
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
