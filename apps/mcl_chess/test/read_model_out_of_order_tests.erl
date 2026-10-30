%% @doc A projection of an older event cannot undo a newer one (mcl-chess#18).
%%
%% THE FAILURE THIS STANDS FOR IS SILENT AND PERMANENT. evoq gives each
%% subscribed handler its own cursor, and this read model has one handler per
%% event type, so `move_played_v1' and `game_ended_v1' are projected by two
%% processes that do not order themselves against each other. Every projection
%% writes the row's `status' from its own event, so a mate's last move landing
%% after the end it caused put the finished game back to `in progress' and left
%% it there: the events were right, the mesh fact was right, and only the read
%% model was wrong. It showed up as `game_to_the_end_tests' failing roughly half
%% the time, which is why it read as a flaky test rather than a lost write -
%% and why raising the test's retry budget could not help it.
%%
%% The fixture is the projection modules themselves, driven in the order that
%% hurts. No store, no policy, no clock: the same events, applied twice over,
%% newest first and then stale, which is exactly what a lagging cursor does.
-module(read_model_out_of_order_tests).

-include_lib("eunit/include/eunit.hrl").

-define(GAME, <<"game-0a1b2c3d4e5f60718293a4b5c6d7e8f9">>).
-define(INITIAL, <<"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1">>).
-define(FOOLS_MATE, <<"rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3">>).

out_of_order_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     [{timeout, 60, fun a_stale_move_cannot_undo_the_end/0},
      {timeout, 60, fun a_stale_start_cannot_undo_the_end/0},
      {timeout, 60, fun a_redelivered_birth_cannot_undo_the_end/0},
      {timeout, 60, fun the_same_events_in_order_reach_the_same_row/0}]}.

setup() ->
    Dir = filename:join(["/tmp", "mcl_chess_out_of_order",
                         integer_to_list(erlang:unique_integer([positive]))]),
    Sqlite = filename:join(Dir, "read_model.sqlite3"),
    ok = filelib:ensure_dir(Sqlite),
    %% A sibling suite may hold the registered name; this suite owns it now.
    stop_running(game_read_model_store),
    stop_running(game_query_store),
    {ok, ReadModel} = game_read_model_store:start_link(Sqlite),
    {ok, Query} = game_query_store:start_link(Sqlite),
    unlink(ReadModel),
    unlink(Query),
    #{dir => Dir, read_model => ReadModel, query => Query}.

cleanup(#{dir := Dir, read_model := ReadModel, query := Query}) ->
    [stop(P) || P <- [Query, ReadModel]],
    _ = file:del_dir_r(Dir),
    ok.

%% The one that cost the package its green build: the mate's final move is
%% projected after the end, and the game must stay ended. The move row it
%% carries is its own fact keyed by ply, so it must still be listed.
a_stale_move_cannot_undo_the_end() ->
    played_in_order(),
    ?assertEqual(ok, project(move_played_v1_to_sqlite_games, move(7, <<"d8h4">>))),
    Row = row(),
    ?assertEqual(9, maps:get(<<"status">>, Row)),
    ?assertEqual(<<"winner">>, maps:get(<<"outcome">>, Row)),
    ?assertEqual(?FOOLS_MATE, maps:get(<<"position">>, Row)),
    ?assertEqual([[8, 9]], game_read_model_store:q(
                             "SELECT version, status FROM games WHERE game_id = ?",
                             [?GAME])),
    ?assertEqual([<<"f2f3">>, <<"e7e5">>, <<"g2g4">>, <<"d8h4">>],
                 maps:get(<<"moves">>, Row)).

a_stale_start_cannot_undo_the_end() ->
    played_in_order(),
    ?assertEqual(ok, project(game_started_v1_to_sqlite_games, started())),
    ?assertEqual(9, maps:get(<<"status">>, row())).

a_redelivered_birth_cannot_undo_the_end() ->
    played_in_order(),
    ?assertEqual(ok, project(game_initiated_v1_to_sqlite_games, initiated())),
    Row = row(),
    ?assertEqual(9, maps:get(<<"status">>, Row)),
    ?assertEqual(?FOOLS_MATE, maps:get(<<"position">>, Row)).

%% And the guard must not change what a well-behaved projection order produces:
%% the read model a settled store rebuilds is the same row either way.
the_same_events_in_order_reach_the_same_row() ->
    played_in_order(),
    Row = row(),
    ?assertEqual(9, maps:get(<<"status">>, Row)),
    ?assertEqual(<<"checkmate">>, maps:get(<<"end_reason">>, Row)),
    ?assertEqual(4, maps:get(<<"ply">>, Row)).

%%====================================================================
%% Fixtures
%%====================================================================

%% A game played to mate, projected in the order the stream has it.
played_in_order() ->
    ok = project(game_initiated_v1_to_sqlite_games, initiated()),
    ok = project(seat_claimed_v1_to_sqlite_games, seat(1, <<"a1b2">>, <<>>)),
    ok = project(seat_claimed_v1_to_sqlite_games, seat(2, <<"a1b2">>, <<"b2c3">>)),
    ok = project(game_started_v1_to_sqlite_games, started()),
    ok = project(move_played_v1_to_sqlite_games, move(4, <<"f2f3">>)),
    ok = project(move_played_v1_to_sqlite_games, move(5, <<"e7e5">>)),
    ok = project(move_played_v1_to_sqlite_games, move(6, <<"g2g4">>)),
    ok = project(move_played_v1_to_sqlite_games, move(7, <<"d8h4">>)),
    ok = project(game_ended_v1_to_sqlite_games, ended(8)).

project(Module, Event) ->
    case Module:handle_event(maps:get(event_type, Event), Event, #{}, #{}) of
        {ok, _State} -> ok;
        {error, Reason} -> {error, Reason}
    end.

row() ->
    {ok, Row} = get_game_by_id:find(?GAME),
    Row.

initiated() ->
    event(<<"game_initiated_v1">>, 0,
          #{game_id => ?GAME, protocol => <<"chess">>, time_control => {60000, 0},
            seats => #{white => <<>>, black => <<>>}, position => ?INITIAL,
            to_move => <<"w">>, ply => 0, clocks => clocks(60000),
            status => 3, initiator_node_id => <<"a1b2">>, at_ms => 1792435657965}).

seat(Version, White, Black) ->
    event(<<"seat_claimed_v1">>, Version,
          #{game_id => ?GAME, seats => #{white => White, black => Black},
            status => seats(White, Black), at_ms => 1792435657970}).

started() ->
    event(<<"game_started_v1">>, 3,
          #{game_id => ?GAME, white_node_id => <<"a1b2">>, black_node_id => <<"b2c3">>,
            position => ?INITIAL, position_hash => 424242, to_move => <<"w">>, ply => 0,
            clocks => clocks(60000), status => 5, at_ms => 1792435657980}).

move(Version, Uci) ->
    event(<<"move_played_v1">>, Version,
          #{game_id => ?GAME, fen_after => position_after(Version),
            position_hash => Version, to_move => to_move_after(Version),
            ply => Version - 3, clocks => clocks(59000), halfmove_clock => 1,
            status => 5, move => Uci, at_ms => 1792435657990}).

ended(Version) ->
    event(<<"game_ended_v1">>, Version,
          #{game_id => ?GAME, fen_after => ?FOOLS_MATE, ply => 4,
            clocks => #{white => 58000, black => 59000}, status => 9,
            outcome => winner, reason => checkmate, winner_node_id => <<"b2c3">>,
            at_ms => 1792435657999}).

%% `seat_claimed_v1' carries the status the game reaches with that claim: both
%% seats taken is what starts it, so the second claim already reads 5.
seats(<<>>, _Black) -> 3;
seats(_White, <<>>) -> 3;
seats(_White, _Black) -> 5.

%% Only the last move's position matters to the assertions here; the earlier
%% plies carry a placeholder that is still a legal FEN shape.
position_after(7) -> ?FOOLS_MATE;
position_after(_Ply) -> ?INITIAL.

to_move_after(Version) when Version rem 2 =:= 0 -> <<"b">>;
to_move_after(_Version) -> <<"w">>.

clocks(Ms) -> #{white => Ms, black => Ms}.

event(Type, Version, Data) ->
    #{event_type => Type, data => Data,
      event_id => <<"event-", (integer_to_binary(Version))/binary>>, version => Version}.

%%====================================================================
%% Store lifecycle
%%====================================================================

stop_running(Name) ->
    case whereis(Name) of
        undefined -> ok;
        Pid -> catch gen_server:stop(Pid), ok
    end.

stop(Pid) ->
    catch gen_server:stop(Pid),
    ok.
