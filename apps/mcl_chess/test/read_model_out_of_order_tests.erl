%% @doc One cursor per row: a game's columns cannot be lost, and a redelivery
%% cannot undo a newer state (mcl-chess#18).
%%
%% THE FAILURE THIS STANDS FOR IS SILENT AND PERMANENT. Before the merge, this
%% read model started one evoq handler per event type. Since evoq 1.30 every
%% handler has its own courier, so delivery is ordered within a handler and not
%% across handlers (evoq#30), and two events of one game were projected in an
%% order nobody controlled. A version guard on each write keeps an older event
%% from overwriting a newer one, but it drops that write WHOLE - and each event
%% owns columns no other event writes (`started_at` only a start,
%% `flagged_node_id` only a flag, the outcome only an end, `to_move` only a
%% move), so the dropped event's columns were lost for good. It showed up as
%% `game_to_the_end_tests` failing roughly half the time, which is why it read as
%% a flaky test rather than a lost write.
%%
%% The fix is not a cleverer guard: it is ONE handler interested in all seven
%% game events, so evoq's per-handler ordering is an ordering over the game's own
%% events. `one_handler_owns_every_game_event' is the test that bites if someone
%% splits it back up; the four column tests say what would be lost if they did;
%% and the redelivery tests say what the guard is still for.
-module(read_model_out_of_order_tests).

-include_lib("eunit/include/eunit.hrl").

-define(GAME, <<"game-0a1b2c3d4e5f60718293a4b5c6d7e8f9">>).
-define(INITIAL, <<"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1">>).
-define(FOOLS_MATE, <<"rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3">>).

out_of_order_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     [{timeout, 60, fun one_handler_owns_every_game_event/0},
      {timeout, 60, fun a_redelivered_move_cannot_undo_the_end/0},
      {timeout, 60, fun a_redelivered_start_cannot_undo_the_end/0},
      {timeout, 60, fun a_redelivered_birth_cannot_undo_the_end/0},
      {timeout, 60, fun the_four_column_groups_survive_one_game/0},
      {timeout, 60, fun an_archived_game_keeps_its_outcome/0},
      {timeout, 60, fun a_flag_and_the_end_of_one_command_both_land/0},
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

%% THE ONE THAT BITES. If the games row is projected by more than one evoq
%% handler again, evoq orders those handlers' deliveries against nothing, and
%% every column test below becomes a coin toss in production even though each of
%% them passes here - because here they are driven in order. So the structural
%% claim is asserted, not assumed: one child, and it names all seven events.
one_handler_owns_every_game_event() ->
    ?assertEqual([<<"clock_flagged_v1">>, <<"game_archived_v1">>,
                  <<"game_ended_v1">>, <<"game_initiated_v1">>,
                  <<"game_started_v1">>, <<"move_played_v1">>,
                  <<"seat_claimed_v1">>],
                 lists:sort(game_lifecycle_to_games:interested_in())),
    Handlers = [Id || #{id := Id, modules := Mods} <- projection_children(),
                      lists:member(evoq_event_handler, Mods)],
    ?assertEqual([game_lifecycle_to_games], Handlers).

%% The mate's last move delivered a second time after the end: the game stays
%% ended, and the move row it carries is its own fact keyed by ply, so it is
%% still listed.
a_redelivered_move_cannot_undo_the_end() ->
    played_to_mate(),
    ?assertEqual(ok, project(move(7, <<"d8h4">>))),
    Row = row(),
    ?assertEqual(9, maps:get(<<"status">>, Row)),
    ?assertEqual(<<"winner">>, maps:get(<<"outcome">>, Row)),
    ?assertEqual(?FOOLS_MATE, maps:get(<<"position">>, Row)),
    ?assertEqual([[8, 9]], game_read_model_store:q(
                             "SELECT version, status FROM games WHERE game_id = ?",
                             [?GAME])),
    ?assertEqual([<<"f2f3">>, <<"e7e5">>, <<"g2g4">>, <<"d8h4">>],
                 maps:get(<<"moves">>, Row)).

a_redelivered_start_cannot_undo_the_end() ->
    played_to_mate(),
    ?assertEqual(ok, project(started())),
    ?assertEqual(9, maps:get(<<"status">>, row())).

a_redelivered_birth_cannot_undo_the_end() ->
    played_to_mate(),
    ?assertEqual(ok, project(initiated())),
    Row = row(),
    ?assertEqual(9, maps:get(<<"status">>, Row)),
    ?assertEqual(?FOOLS_MATE, maps:get(<<"position">>, Row)).

%% The four column groups that the split handlers could lose, each owned by
%% exactly one event: a start's moment, a flag's player, a move's side to move,
%% and the end's outcome. One cursor means all four are on the row at once; a
%% dropped write lost whichever group it carried, for good.
the_four_column_groups_survive_one_game() ->
    flagged_out(),
    Row = row(),
    ?assertEqual(1792435657980, maps:get(<<"started_at">>, Row)),   %% start
    %% `flagged_node_id' is a column the query desk does not serve; the read
    %% model is what this test is about, so it is read from the row itself.
    ?assertEqual([[<<"b2c3">>]], game_read_model_store:q(
                                  "SELECT flagged_node_id FROM games"
                                  " WHERE game_id = ?", [?GAME])),  %% flag
    ?assertEqual(<<"b">>, maps:get(<<"to_move">>, Row)),            %% move
    ?assertEqual(<<"checkmate">>, maps:get(<<"end_reason">>, Row)), %% end
    ?assertEqual([[8]], game_read_model_store:q(
                        "SELECT version FROM games WHERE game_id = ?", [?GAME])),
    ?assertEqual(4, maps:get(<<"ply">>, Row)).

%% An archived game is not a game with everything erased: the death slice is
%% what an operator did to it, and the outcome under it is still the answer to
%% "how did it end".
an_archived_game_keeps_its_outcome() ->
    played_to_mate(),
    ?assertEqual(ok, project(archived(9))),
    Row = row(),
    ?assertEqual(17, maps:get(<<"status">>, Row)),
    ?assertEqual(<<"winner">>, maps:get(<<"outcome">>, Row)),
    ?assertEqual(<<"checkmate">>, maps:get(<<"end_reason">>, Row)),
    ?assertEqual(<<"b2c3">>, maps:get(<<"winner">>, Row)),
    ?assertEqual(1792435657999, maps:get(<<"ended_at">>, Row)),
    ?assertEqual(<<"searching">>, maps:get(<<"archive_reason">>, Row)).

%% A flag and the end it produces come out of ONE command, two events, versions
%% 7 and 8. Two handlers projected them on two cursors, which is how a row could
%% keep the end's clocks and lose the flagged player. One cursor keeps both.
a_flag_and_the_end_of_one_command_both_land() ->
    flagged_out(),
    Row = row(),
    ?assertEqual([[<<"b2c3">>]], game_read_model_store:q(
                                  "SELECT flagged_node_id FROM games"
                                  " WHERE game_id = ?", [?GAME])),
    ?assertEqual(9, maps:get(<<"status">>, Row)),
    ?assertEqual(<<"winner">>, maps:get(<<"outcome">>, Row)).

%% And the guard must not change what a well-behaved projection order produces:
%% the read model a settled store rebuilds is the same row either way.
the_same_events_in_order_reach_the_same_row() ->
    played_to_mate(),
    Row = row(),
    ?assertEqual(9, maps:get(<<"status">>, Row)),
    ?assertEqual(<<"checkmate">>, maps:get(<<"end_reason">>, Row)),
    ?assertEqual(4, maps:get(<<"ply">>, Row)).

%%====================================================================
%% Fixtures
%%====================================================================

%% A game played to mate, projected in the order the stream has it.
played_to_mate() ->
    before_the_end(),
    ok = project(move(7, <<"d8h4">>)),
    ok = project(ended(8)).

%% A game that ends on the clock instead: three moves, then the flag and the end
%% that command produces, versions 7 and 8.
flagged_out() ->
    before_the_end(),
    ok = project(flagged(7)),
    ok = project(ended(8)).

%% Each test starts from no row: the suite shares one sqlite file and one game
%% id, so a projection left by the test before it would make every write here a
%% stale one.
fresh() ->
    ok = game_read_model_store:exec("DELETE FROM games WHERE game_id = ?", [?GAME]),
    ok = game_read_model_store:exec("DELETE FROM moves WHERE game_id = ?", [?GAME]).

%% The part every game shares: the birth, the claim of each seat, the start and
%% three moves.
before_the_end() ->
    ok = fresh(),
    ok = project(initiated()),
    ok = project(seat(1, <<"a1b2">>, <<>>)),
    ok = project(seat(2, <<"a1b2">>, <<"b2c3">>)),
    ok = project(started()),
    ok = project(move(4, <<"f2f3">>)),
    ok = project(move(5, <<"e7e5">>)),
    ok = project(move(6, <<"g2g4">>)).

%% The projection is driven the way evoq delivers to it: one handler, the event
%% type it is interested in, the event as the store hands it over.
project(Event) ->
    case game_lifecycle_to_games:handle_event(
           maps:get(event_type, Event), Event, #{}, #{}) of
        {ok, _State} -> ok;
        {error, Reason} -> {error, Reason}
    end.

%% The children the PRJ division actually starts, from its own supervisor spec.
projection_children() ->
    {ok, {_Flags, Children}} = project_games_sup:init([]),
    Children.

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

flagged(Version) ->
    event(<<"clock_flagged_v1">>, Version,
          #{game_id => ?GAME, player_node_id => <<"b2c3">>,
            clocks => #{white => 58000, black => 0}, status => 5,
            at_ms => 1792435657995}).

ended(Version) ->
    event(<<"game_ended_v1">>, Version,
          #{game_id => ?GAME, fen_after => ?FOOLS_MATE, ply => 4,
            clocks => #{white => 58000, black => 59000}, status => 9,
            outcome => winner, reason => checkmate, winner_node_id => <<"b2c3">>,
            at_ms => 1792435657999}).

archived(Version) ->
    event(<<"game_archived_v1">>, Version,
          #{game_id => ?GAME, reason => <<"searching">>, status => 17,
            at_ms => 1792435658001}).

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
