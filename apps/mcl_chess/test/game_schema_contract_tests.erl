%% @doc The read model's schema contract (mcl-chess#5, WP7).
%%
%% Two divisions write and read one sqlite file that neither owns alone: PRJ
%% declares the shape (`game_read_model_store:schema/0`), every projection in PRJ
%% writes into it, and QRY's desks select from it. Three modules promised this
%% suite and none existed, so a column added to the DDL and not to the SELECT, or
%% a column a projection writes that the DDL never declares, would fail at run
%% time in a desk or a projection and only be noticed by whichever end-to-end
%% test happened to touch that field.
%%
%% Nothing here restates the schema. The columns are parsed out of the DDL
%% itself, and the two facts that matter are established by using the real store:
%%
%%   - the query's SELECT names only columns the DDL declares, in the order
%%     `get_game_by_id' destructures them, proved by writing one row whose cells
%%     are all different and reading it back through the desk;
%%   - every column a projection writes is one the DDL declares, proved by
%%     running every projection against the real file.
-module(game_schema_contract_tests).

-include_lib("eunit/include/eunit.hrl").

-define(GAME, <<"game-0102030405060708090a0b0c0d0e0f10">>).
-define(INITIAL, <<"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1">>).

contract_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun(_Ctx) ->
             [{timeout, 60, fun the_parser_reads_the_declared_schema/0},
              {timeout, 60, fun the_ddl_and_the_file_agree/0},
              {timeout, 60, fun the_migrations_only_add_declared_columns/0},
              {timeout, 60, fun the_query_selects_only_declared_columns/0},
              {timeout, 60, fun every_projection_writes_only_declared_columns/0},
              {timeout, 60, fun the_move_list_is_a_table_of_its_own/0}]
     end}.

setup() ->
    Dir = filename:join(["/tmp", "mcl_chess_schema_contract",
                         integer_to_list(erlang:unique_integer([positive]))]),
    Sqlite = filename:join(Dir, "contract.sqlite3"),
    {ok, ReadModel} = game_read_model_store:start_link(Sqlite),
    {ok, Query} = game_query_store:start_link(Sqlite),
    unlink(ReadModel),
    unlink(Query),
    #{dir => Dir, read_model => ReadModel, query => Query}.

cleanup(#{dir := Dir, read_model := ReadModel, query := Query}) ->
    [stop(P) || P <- [Query, ReadModel]],
    _ = file:del_dir_r(Dir),
    ok.

stop(Pid) ->
    catch gen_server:stop(Pid),
    ok.

%%====================================================================
%% The DDL, parsed
%%====================================================================

%% The parser is the foundation of every test below, so it is tested: two
%% tables, the PRIMARY KEY constraint is not read as a column (its own comma is
%% not a column separator), and no column name is lost.
the_parser_reads_the_declared_schema() ->
    ?assertEqual([<<"games">>, <<"moves">>], lists:sort(maps:keys(declared()))),
    ?assert(lists:member(<<"game_id">>, columns(games))),
    ?assert(lists:member(<<"status_label">>, columns(games))),
    %% The move table's primary key spans two columns and is not itself one.
    ?assertEqual([<<"game_id">>, <<"ply">>, <<"uci">>], columns(moves)),
    %% A started game carries its own start time (mcl-chess#3).
    ?assert(lists:member(<<"started_at">>, columns(games))),
    ?assertEqual(false, lists:member(<<"PRIMARY">>, columns(games))),
    ?assertEqual(false, lists:member(<<"KEY">>, columns(moves))).

%% What the DDL declares is what the file has: this is what makes the parsed
%% list the source of truth rather than a second copy of the schema.
the_ddl_and_the_file_agree() ->
    [begin
         Rows = game_read_model_store:q("PRAGMA table_info(" ++ atom_to_list(Table) ++ ")",
                                        []),
         Present = lists:sort([Name || [_Cid, Name | _] <- Rows]),
         ?assertEqual({Table, lists:sort(columns(Table))}, {Table, Present})
     end || Table <- [games, moves]],
    ok.

%% The other half of "a column added after the table shipped": it is in the DDL
%% and in the ALTER TABLE, and a migration names only columns the DDL has.
the_migrations_only_add_declared_columns() ->
    Declared = columns(games),
    [?assert({Name, true} =:= {Name, lists:member(list_to_binary(Name), Declared)})
     || {Name, _Sql} <- game_read_model_store:migrations()],
    ok.

%%====================================================================
%% The query, against the real store
%%====================================================================

%% One row, every column a different value, read back through the desk. If the
%% SELECT named a column the DDL does not declare the store would refuse it; if
%% its order drifted away from `found/1''s destructuring, a value would land
%% under the wrong key and this map would not match.
the_query_selects_only_declared_columns() ->
    sentinel_row(),
    ?assertEqual(expected_row(), get_game_by_id:find(?GAME)).

%% The move list is a second read, ordered by ply, and it survives a replay:
%% the same ply delivered twice is one row, not two.
the_move_list_is_a_table_of_its_own() ->
    sentinel_row(),
    [?assertEqual(ok, project(move_played_v1_to_sqlite_games, move(Ply, Uci)))
     || {Ply, Uci} <- [{3, <<"g1f3">>}, {1, <<"e2e4">>}, {2, <<"e7e5">>}]],
    ?assertEqual(ok, project(move_played_v1_to_sqlite_games, move(2, <<"c7c5">>))),
    {ok, Game} = get_game_by_id:find(?GAME),
    ?assertEqual(#{<<"moves">> => [<<"e2e4">>, <<"c7c5">>, <<"g1f3">>]},
                 maps:with([<<"moves">>], Game)).

%%====================================================================
%% The projections, against the real store
%%====================================================================

%% Every projection, in the order a game produces them, writing into the file
%% the DDL creates. A column name the DDL does not declare comes back as a store
%% error rather than a green test, which is the point of the exercise.
every_projection_writes_only_declared_columns() ->
    %% From no game at all: the birth is what creates the row, and the query
    %% test above leaves a sentinel row under the same id. A birth projected
    %% onto an existing row writes nothing (`ON CONFLICT DO NOTHING', because a
    %% later event has already carried it forward), so the flow below would be
    %% read back through the sentinel's values rather than its own.
    ok = game_read_model_store:exec("DELETE FROM games WHERE game_id = ?", [?GAME]),
    [?assertEqual({Projection, ok}, {Projection, project(Projection, Event)})
     || {Projection, Event} <- game_flow()],
    {ok, Game} = get_game_by_id:find(?GAME),
    ?assertEqual(<<"checkmate">>, maps:get(<<"end_reason">>, Game)),
    ?assertEqual(<<"winner">>, maps:get(<<"outcome">>, Game)),
    ?assertEqual(<<"searching">>, maps:get(<<"archive_reason">>, Game)),
    %% The start time the desk answers with is the one `game_started_v1'
    %% carried, not a moment the projection chose (mcl-chess#3).
    ?assertEqual(1792435657980, maps:get(<<"started_at">>, Game)).

game_flow() ->
    [{game_initiated_v1_to_sqlite_games, initiated()},
     {seat_claimed_v1_to_sqlite_games, claimed()},
     {game_started_v1_to_sqlite_games, started()},
     {move_played_v1_to_sqlite_games, move(1, <<"e2e4">>)},
     {clock_flagged_v1_to_sqlite_games, flagged()},
     {game_ended_v1_to_sqlite_games, ended()},
     {game_archived_v1_to_sqlite_games, archived()}].

%%====================================================================
%% The DDL, parsed for real
%%====================================================================

%% @private The declared columns, per table, from `schema/0' itself.
declared() ->
    maps:from_list([{table_name(Sql), columns_of(Sql)}
                    || Sql <- game_read_model_store:schema()]).

%% The tables are named as binaries, from the DDL; callers ask for them as the
%% atoms the test writes.
columns(Table) ->
    maps:get(atom_to_binary(Table, utf8), declared()).

table_name(Sql) ->
    ["CREATE", "TABLE", "IF", "NOT", "EXISTS", Name | _] = string:lexemes(Sql, " ("),
    list_to_binary(Name).

%% Between the first "(" and the last ")", minus any constraint's own bracket,
%% which is what keeps the primary key's comma from reading as a column break.
%% Exactly one closing bracket is dropped: trimming all of them would eat the
%% constraint's, and its contents would then read as columns.
columns_of(Sql) ->
    Open = string:str(Sql, "("),
    Body = string:substr(Sql, Open + 1, string:len(Sql) - Open),
    Trimmed = string:slice(Body, 0, string:len(Body) - 1),
    Constraints = re:replace(Trimmed, "\\([^()]*\\)", "", [global, {return, list}]),
    [list_to_binary(Name)
     || Part <- string:split(Constraints, ",", all),
        Name <- [first_lexeme(Part)],
        Name =/= "PRIMARY", Name =/= "UNIQUE", Name =/= "FOREIGN", Name =/= ""].

first_lexeme(Part) ->
    case string:lexemes(Part, " \t\r\n") of
        [] -> "";
        [First | _] -> First
    end.

%%====================================================================
%% Fixtures
%%====================================================================

%% One row, built from the parsed DDL: every declared column gets a value of its
%% own, so a value read back under the wrong key is visible rather than
%% plausible.
sentinel_row() ->
    All = columns(games),
    Sql = "INSERT OR REPLACE INTO games ("
        ++ string:join([binary_to_list(Column) || Column <- All], ", ") ++ ") VALUES ("
        ++ string:join(lists:duplicate(length(All), "?"), ", ") ++ ")",
    ?assertEqual(ok, game_read_model_store:exec(Sql, [sentinel(Column) || Column <- All])).

sentinel(<<"game_id">>) -> ?GAME;
sentinel(<<"protocol">>) -> <<"protocol-sentinel">>;
sentinel(<<"initial_ms">>) -> 101;
sentinel(<<"increment_ms">>) -> 102;
sentinel(<<"white_node_id">>) -> <<"white-sentinel">>;
sentinel(<<"black_node_id">>) -> <<"black-sentinel">>;
sentinel(<<"position">>) -> <<"position-sentinel">>;
sentinel(<<"to_move">>) -> <<"w">>;
sentinel(<<"ply">>) -> 107;
sentinel(<<"white_clock_ms">>) -> 108;
sentinel(<<"black_clock_ms">>) -> 109;
sentinel(<<"halfmove_clock">>) -> 110;
sentinel(<<"status">>) -> 111;
sentinel(<<"status_label">>) -> <<"label-sentinel">>;
sentinel(<<"outcome">>) -> <<"outcome-sentinel">>;
sentinel(<<"end_reason">>) -> <<"reason-sentinel">>;
sentinel(<<"winner_node_id">>) -> <<"winner-sentinel">>;
sentinel(<<"flagged_node_id">>) -> <<"flagged-sentinel">>;
sentinel(<<"initiator">>) -> <<"initiator-sentinel">>;
sentinel(<<"archive_reason">>) -> <<"archive-sentinel">>;
sentinel(<<"initiated_at">>) -> 118;
sentinel(<<"started_at">>) -> 117;
sentinel(<<"ended_at">>) -> 119;
sentinel(<<"archived_at">>) -> 120;
sentinel(<<"event_id">>) -> <<"event-sentinel">>;
sentinel(<<"version">>) -> 122.

%% What `get_game_by_id:find/1' answers for that row. The SELECT deliberately
%% leaves out `flagged_node_id', `event_id' and `version'; that choice is part of
%% the contract too, because a desk's map is what a caller is promised.
expected_row() ->
    {ok, #{<<"game_id">> => ?GAME,
           <<"protocol">> => <<"protocol-sentinel">>,
           <<"status">> => 111,
           <<"status_label">> => <<"label-sentinel">>,
           <<"time_control">> => #{<<"initial_ms">> => 101, <<"increment_ms">> => 102},
           <<"seats">> => #{<<"white">> => <<"white-sentinel">>,
                            <<"black">> => <<"black-sentinel">>},
           <<"position">> => <<"position-sentinel">>,
           <<"to_move">> => <<"w">>,
           <<"ply">> => 107,
           <<"clocks">> => #{<<"white">> => 108, <<"black">> => 109},
           <<"halfmove_clock">> => 110,
           <<"outcome">> => <<"outcome-sentinel">>,
           <<"end_reason">> => <<"reason-sentinel">>,
           <<"winner">> => <<"winner-sentinel">>,
           <<"initiator">> => <<"initiator-sentinel">>,
           <<"archive_reason">> => <<"archive-sentinel">>,
           <<"initiated_at">> => 118,
           <<"started_at">> => 117,
           <<"ended_at">> => 119,
           <<"archived_at">> => 120,
           <<"moves">> => []}}.

project(Module, Event) ->
    case Module:handle_event(maps:get(event_type, Event), Event, #{}, #{}) of
        {ok, _State} -> ok;
        {error, Reason} -> {error, Reason}
    end.

initiated() ->
    event(<<"game_initiated_v1">>, 0,
          #{game_id => ?GAME, protocol => <<"chess">>, time_control => {60000, 0},
            seats => #{white => <<>>, black => <<>>}, position => ?INITIAL,
            to_move => <<"w">>, ply => 0, clocks => #{white => 60000, black => 60000},
            status => 3, initiator_node_id => <<"a1b2">>, at_ms => 1792435657965}).

claimed() ->
    event(<<"seat_claimed_v1">>, 1,
          #{game_id => ?GAME, player_node_id => <<"b2c3">>, color => <<"b">>,
            seats => #{white => <<"a1b2">>, black => <<"b2c3">>}, status => 3,
            at_ms => 1792435657970}).

started() ->
    event(<<"game_started_v1">>, 2,
          #{game_id => ?GAME, white_node_id => <<"a1b2">>, black_node_id => <<"b2c3">>,
            position => ?INITIAL, position_hash => 424242, to_move => <<"w">>, ply => 0,
            clocks => #{white => 60000, black => 60000}, status => 5,
            at_ms => 1792435657980}).

move(Ply, Uci) ->
    event(<<"move_played_v1">>, 2 + Ply,
          #{game_id => ?GAME, player_node_id => <<"a1b2">>, move => Uci, ply => Ply,
            fen_after => <<"rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1">>,
            position_hash => 424243, halfmove_clock => 0, repetitions => 1,
            to_move => <<"b">>, clocks => #{white => 59000, black => 60000},
            status => 5, at_ms => 1792435657990}).

flagged() ->
    event(<<"clock_flagged_v1">>, 4,
          #{game_id => ?GAME, player_node_id => <<"a1b2">>,
            clocks => #{white => 0, black => 60000}, status => 5,
            at_ms => 1792435657995}).

ended() ->
    event(<<"game_ended_v1">>, 5,
          #{game_id => ?GAME, outcome => winner, winner_node_id => <<"b2c3">>,
            reason => checkmate,
            fen_after => <<"rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3">>,
            ply => 4, clocks => #{white => 0, black => 57000}, status => 9,
            at_ms => 1792435658000}).

archived() ->
    event(<<"game_archived_v1">>, 6,
          #{game_id => ?GAME, reason => <<"searching">>, status => 17,
            at_ms => 1792435744000}).

%% The projections read `data' when the store hands them a wrapped event, and the
%% event's own id and version: this is that shape. The version is the event's
%% place in its stream, which is what a projection guards its write on, so each
%% fixture above carries the one the stream really gives it (mcl-chess#18).
event(Type, Version, Data) ->
    #{event_type => Type, data => Data,
      event_id => <<"event-0123456789abcdef0123456789abcdef">>, version => Version}.
