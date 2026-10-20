%% @doc A read-model file built before `started_at' existed still projects a
%% start (WP8, mcl-chess#3, review R1).
%%
%% THE FAILURE THIS STANDS FOR IS SILENT. The read model is a cache of the
%% events, but its file outlives the release that made it: the repository's own
%% `deploy/docker-compose.yml' runs the image as-is against a persistent data
%% directory, and a published 0.6.0 image is what would have made that file. Add
%% a column to the DDL, keep `CREATE TABLE IF NOT EXISTS', and the boot is green
%% because the table already exists; the projection then fails on EVERY
%% game_started_v1 with "no such column", which evoq treats as a retryable store
%% error. Games stay at `initiated' forever and nothing says why.
%%
%% So the fixture is the real thing: the current DDL, with the column the
%% migration is for dropped again, which is exactly the shape a 0.6.0 file has
%% (started_at is the only column added by this release). The store is then
%% started on that file, as a boot does, and the two projections a game's start
%% produces are run against it.
-module(read_model_migration_tests).

-include_lib("eunit/include/eunit.hrl").

-define(GAME, <<"game-0f1e2d3c4b5a69788796a5b4c3d2e1f0">>).
-define(INITIAL, <<"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1">>).
-define(MIGRATED, "started_at").

migration_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     [{timeout, 60, fun a_file_built_before_started_at_gains_it/0},
      {timeout, 60, fun the_start_projection_then_answers_the_start_time/0}]}.

setup() ->
    Dir = filename:join(["/tmp", "mcl_chess_migration",
                         integer_to_list(erlang:unique_integer([positive]))]),
    Sqlite = filename:join(Dir, "old.sqlite3"),
    ok = filelib:ensure_dir(Sqlite),
    ok = file_built_before(Dir),
    %% A sibling suite may hold the registered name; this suite owns it now.
    stop_running(game_read_model_store),
    stop_running(game_query_store),
    {ok, ReadModel} = game_read_model_store:start_link(Sqlite),
    {ok, Query} = game_query_store:start_link(Sqlite),
    unlink(ReadModel),
    unlink(Query),
    #{dir => Dir, sqlite => Sqlite, read_model => ReadModel, query => Query}.

cleanup(#{dir := Dir, read_model := ReadModel, query := Query}) ->
    [stop(P) || P <- [Query, ReadModel]],
    _ = file:del_dir_r(Dir),
    ok.

stop_running(Name) ->
    case whereis(Name) of
        undefined -> ok;
        Pid -> catch gen_server:stop(Pid), ok
    end.

stop(Pid) ->
    catch gen_server:stop(Pid),
    ok.

%% The store opened a file that predates the column and brought it up to date:
%% a boot that would otherwise leave every start failing.
a_file_built_before_started_at_gains_it() ->
    ?assert(lists:member(?MIGRATED, columns())).

%% And the whole slice then works on that file: the birth creates the row, the
%% start writes its moment, and the desk answers with it.
the_start_projection_then_answers_the_start_time() ->
    ?assertEqual(ok, project(game_initiated_v1_to_sqlite_games, initiated())),
    ?assertEqual(ok, project(game_started_v1_to_sqlite_games, started())),
    {ok, Game} = get_game_by_id:find(?GAME),
    ?assertEqual(5, maps:get(<<"status">>, Game)),
    ?assertEqual(1792435657980, maps:get(<<"started_at">>, Game)).

%%====================================================================
%% The file as an older release left it
%%====================================================================

%% The current DDL, then the new column dropped: the table a 0.6.0 image
%% created, without a second copy of the schema to drift from the first.
file_built_before(Dir) ->
    Sqlite = filename:join(Dir, "old.sqlite3"),
    {ok, Conn} = esqlite3:open(Sqlite),
    try
        [ok = esqlite3:exec(Conn, Sql) || Sql <- game_read_model_store:schema()],
        ok = esqlite3:exec(Conn, "ALTER TABLE games DROP COLUMN " ++ ?MIGRATED)
    after
        esqlite3:close(Conn)
    end.

columns() ->
    Rows = game_read_model_store:q("PRAGMA table_info(games)", []),
    [binary_to_list(Name) || [_Cid, Name | _] <- Rows, is_binary(Name)].

%%====================================================================
%% Fixtures
%%====================================================================

project(Module, Event) ->
    case Module:handle_event(maps:get(event_type, Event), Event, #{}, #{}) of
        {ok, _State} -> ok;
        {error, Reason} -> {error, Reason}
    end.

initiated() ->
    event(<<"game_initiated_v1">>,
          #{game_id => ?GAME, protocol => <<"chess">>, time_control => {60000, 0},
            seats => #{white => <<>>, black => <<>>}, position => ?INITIAL,
            to_move => <<"w">>, ply => 0, clocks => #{white => 60000, black => 60000},
            status => 3, initiator_node_id => <<"a1b2">>, at_ms => 1792435657965}).

started() ->
    event(<<"game_started_v1">>,
          #{game_id => ?GAME, white_node_id => <<"a1b2">>, black_node_id => <<"b2c3">>,
            position => ?INITIAL, position_hash => 424242, to_move => <<"w">>, ply => 0,
            clocks => #{white => 60000, black => 60000}, status => 5,
            at_ms => 1792435657980}).

event(Type, Data) ->
    #{event_type => Type, data => Data,
      event_id => <<"event-0123456789abcdef0123456789abcdef">>, version => 7}.
