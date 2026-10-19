%%% @doc Tests for the chess rules NIF, through the module the referee calls.
%%%
%%% The deep arithmetic lives in the crate's own perft suite (cargo test), which
%%% walks the published node counts for the six standard perft positions. These
%%% tests are about the BEAM half: that the library loads, that the strings and
%%% integers cross the boundary intact, that the castling spellings behave, and
%%% that the verdicts are the five the wire understands.
-module(mcl_chess_rules_tests).

-include_lib("eunit/include/eunit.hrl").

-define(START, <<"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1">>).

%%% Loading

%%% If the .so were missing or built for another architecture, the module would
%%% not have loaded at all and every test below would be undef. This one says so
%%% in its own words.
nif_is_loaded_test() ->
    ?assertEqual(ok, mcl_chess_rules:validate_move(?START, <<"e2e4">>)).

%%% validate_move/2

legal_move_test() ->
    ?assertEqual(ok, mcl_chess_rules:validate_move(?START, <<"e2e4">>)),
    ?assertEqual(ok, mcl_chess_rules:validate_move(?START, <<"g1f3">>)).

illegal_move_test() ->
    %% A rook cannot jump its own pawn, and the king cannot cross the board.
    ?assertEqual({error, illegal_move}, mcl_chess_rules:validate_move(?START, <<"a1a8">>)),
    ?assertEqual({error, illegal_move}, mcl_chess_rules:validate_move(?START, <<"e1e8">>)),
    %% Moving a piece that is not even there, and moving for the wrong side.
    ?assertEqual({error, illegal_move}, mcl_chess_rules:validate_move(?START, <<"e3e4">>)),
    ?assertEqual({error, illegal_move}, mcl_chess_rules:validate_move(?START, <<"e7e5">>)).

not_a_move_test() ->
    ?assertEqual({error, invalid_move}, mcl_chess_rules:validate_move(?START, <<"e2e4e5">>)),
    ?assertEqual({error, invalid_move}, mcl_chess_rules:validate_move(?START, <<"xyz">>)),
    ?assertEqual({error, invalid_move}, mcl_chess_rules:validate_move(?START, <<"E2E4">>)),
    %% There is no king or pawn to promote to.
    ?assertEqual({error, invalid_move}, mcl_chess_rules:validate_move(?START, <<"e7e8k">>)).

not_a_position_test() ->
    ?assertEqual({error, invalid_fen}, mcl_chess_rules:validate_move(<<"not a fen">>, <<"e2e4">>)),
    %% A board with no king on it is not a position.
    ?assertEqual(
       {error, invalid_fen},
       mcl_chess_rules:validate_move(<<"8/8/8/8/8/8/8/8 w - - 0 1">>, <<"e2e4">>)).

%%% apply_move/2
%%%
%%% The third element is the halfmove-reset flag: the referee keeps its own
%%% counter because the library's is clamped to 100, and a pawn move or a
%%% capture is what starts it again.

apply_move_returns_the_position_after_it_test() ->
    ?assertEqual(
       {ok, <<"rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1">>,
        hash_of(?START, <<"e2e4">>), 1},
       mcl_chess_rules:apply_move(?START, <<"e2e4">>)),
    ?assertEqual(
       {ok, <<"rnbqkbnr/pppppppp/8/8/8/5N2/PPPPPPPP/RNBQKB1R b KQkq - 1 1">>,
        hash_of(?START, <<"g1f3">>), 0},
       mcl_chess_rules:apply_move(?START, <<"g1f3">>)).

refused_move_changes_nothing_test() ->
    ?assertEqual({error, illegal_move}, mcl_chess_rules:apply_move(?START, <<"e1e8">>)),
    ?assertEqual({error, invalid_move}, mcl_chess_rules:apply_move(?START, <<"nope">>)).

%%% Castling: ordinary UCI and the Chess960 spelling both work, and both arrive
%%% at the same position.

castling_kingside_test() ->
    Fen = <<"r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1">>,
    Expected = <<"r3k2r/8/8/8/8/8/8/R4RK1 b kq - 1 1">>,
    ?assertEqual({ok, Expected, hash_of(Fen, <<"e1g1">>), 0},
                 mcl_chess_rules:apply_move(Fen, <<"e1g1">>)),
    %% The Chess960 spelling of the same castle: the king takes its own rook.
    ?assertEqual(hash_of(Fen, <<"e1g1">>), hash_of(Fen, <<"e1h1">>)).

castling_queenside_test() ->
    Fen = <<"r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1">>,
    ?assertEqual(
       {ok, <<"r3k2r/8/8/8/8/8/8/2KR3R b kq - 1 1">>, hash_of(Fen, <<"e1c1">>), 0},
       mcl_chess_rules:apply_move(Fen, <<"e1c1">>)),
    ?assertEqual(hash_of(Fen, <<"e1c1">>), hash_of(Fen, <<"e1a1">>)).

castling_black_test() ->
    Fen = <<"r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1">>,
    ?assertEqual({ok, <<"r4rk1/8/8/8/8/8/8/R3K2R w KQ - 1 2">>,
                  hash_of(Fen, <<"e8g8">>), 0},
                 mcl_chess_rules:apply_move(Fen, <<"e8g8">>)).

%%% A king move that cannot castle is refused rather than quietly played.
castling_without_the_right_is_refused_test() ->
    Fen = <<"r3k2r/8/8/8/8/8/8/R3K2R w kq - 0 1">>,
    ?assertEqual({error, illegal_move}, mcl_chess_rules:apply_move(Fen, <<"e1g1">>)).

en_passant_test() ->
    Fen = <<"rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3">>,
    ?assertEqual(
       {ok, <<"rnbqkbnr/ppp1pppp/3P4/8/8/8/PPPP1PPP/RNBQKBNR b KQkq - 0 3">>,
        hash_of(Fen, <<"e5d6">>), 1},
       mcl_chess_rules:apply_move(Fen, <<"e5d6">>)).

promotion_test() ->
    Fen = <<"8/P7/8/8/8/8/8/K6k w - - 0 1">>,
    ?assertEqual({ok, <<"Q7/8/8/8/8/8/8/K6k b - - 0 1">>, hash_of(Fen, <<"a7a8q">>), 1},
                 mcl_chess_rules:apply_move(Fen, <<"a7a8q">>)),
    ?assertEqual({ok, <<"N7/8/8/8/8/8/8/K6k b - - 0 1">>, hash_of(Fen, <<"a7a8n">>), 1},
                 mcl_chess_rules:apply_move(Fen, <<"a7a8n">>)),
    %% Choosing no piece at all is not a promotion.
    ?assertEqual({error, illegal_move}, mcl_chess_rules:apply_move(Fen, <<"a7a8">>)).

%%% The hash is the position's, not the road's.
%%%
%%% 1.e4 e5 2.Nf3 and 1.Nf3 e5 2.e4 stand the same pieces with the same side to
%%% move. The second leaves an en passant square nobody can use, which the FEN
%%% shows and FIDE does not count.
same_position_hashes_the_same_test() ->
    RouteA = play([<<"e2e4">>, <<"e7e5">>, <<"g1f3">>]),
    RouteB = play([<<"g1f3">>, <<"e7e5">>, <<"e2e4">>]),
    ?assertNotEqual(element(1, RouteA), element(1, RouteB)),
    ?assertEqual(element(2, RouteA), element(2, RouteB)).

%%% A hostile caller can send bytes that are not text at all. A payload the
%%% referee is meant to judge must be refused in its own vocabulary, never raise
%%% in the caller's process.
not_utf8_is_refused_not_raised_test() ->
    ?assertEqual({error, invalid_fen},
                 mcl_chess_rules:validate_move(<<255, 254>>, <<"e2e4">>)),
    ?assertEqual({error, invalid_move},
                 mcl_chess_rules:validate_move(?START, <<255, 254>>)),
    ?assertEqual({error, invalid_fen}, mcl_chess_rules:apply_move(<<255>>, <<"e2e4">>)),
    ?assertEqual({error, invalid_fen}, mcl_chess_rules:status(<<255>>, 0)).

%%% status/2

active_test() ->
    ?assertEqual(active, mcl_chess_rules:status(?START, 0)).

checkmate_test() ->
    %% Fool's mate, white to move and mated.
    ?assertEqual(
       checkmate,
       mcl_chess_rules:status(<<"rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3">>, 1)).

stalemate_test() ->
    ?assertEqual(stalemate, mcl_chess_rules:status(<<"7k/5Q2/6K1/8/8/8/8/8 b - - 0 1">>, 0)).

insufficient_material_test() ->
    %% Bare kings.
    ?assertEqual(insufficient_material, mcl_chess_rules:status(<<"4k3/8/8/8/8/8/8/4K3 w - - 0 1">>, 0)),
    %% King and one minor piece.
    ?assertEqual(insufficient_material, mcl_chess_rules:status(<<"4k3/8/8/8/8/8/8/4KB2 w - - 0 1">>, 0)),
    ?assertEqual(insufficient_material, mcl_chess_rules:status(<<"4k3/8/8/8/8/8/8/4KN2 w - - 0 1">>, 0)),
    %% A bishop each, on the same colour of square: they never meet.
    ?assertEqual(insufficient_material, mcl_chess_rules:status(<<"2b1k3/8/8/8/8/8/8/4KB2 w - - 0 1">>, 0)).

material_that_can_mate_is_still_active_test() ->
    %% A bishop against a knight can mate with help.
    ?assertEqual(active, mcl_chess_rules:status(<<"1n2k3/8/8/8/8/8/8/4KB2 w - - 0 1">>, 0)),
    %% King and pawn is not dead: the pawn can become a queen.
    ?assertEqual(active, mcl_chess_rules:status(<<"4k3/8/8/8/8/8/4P3/4K3 w - - 0 1">>, 0)).

status_refuses_a_non_position_test() ->
    ?assertEqual({error, invalid_fen}, mcl_chess_rules:status(<<"nonsense">>, 0)).

%%% The clock is the referee's, not the FEN's. cozy-chess keeps the FEN's
%%% counter as a byte clamped to 100, so a game where neither side captures nor
%%% moves a pawn could never reach the 150 halfmoves the 75 move rule fires at.
%%% The count is therefore passed in, and it has to keep working past a byte:
%%% a refused value there would make status unreachable for the rest of that
%%% game, and no verdict of any kind could be reached.
seventy_five_moves_test() ->
    ?assertEqual(active, mcl_chess_rules:status(?START, 0)),
    ?assertEqual(active, mcl_chess_rules:status(?START, 149)),
    ?assertEqual(seventy_five_moves, mcl_chess_rules:status(?START, 150)),
    ?assertEqual(seventy_five_moves, mcl_chess_rules:status(?START, 300)),
    ?assertEqual(seventy_five_moves, mcl_chess_rules:status(?START, 65535)),
    ?assertEqual(seventy_five_moves, mcl_chess_rules:status(?START, 4294967296)),
    %% Checkmate wins over the counter, and a dead position reports its own
    %% reason: both are the rules engine's order, not this module's.
    ?assertEqual(checkmate,
                 mcl_chess_rules:status(
                   <<"rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3">>,
                   300)),
    ?assertEqual(stalemate,
                 mcl_chess_rules:status(<<"7k/5Q2/6K1/8/8/8/8/8 b - - 0 1">>, 300)).

%%% Helpers

hash_of(Fen, Uci) ->
    {ok, _Position, Hash, _Resets} = mcl_chess_rules:apply_move(Fen, Uci),
    Hash.

%% Play a list of moves from the start position and return {Fen, Hash}.
play(Moves) ->
    lists:foldl(
      fun(Uci, {Fen, _Hash}) ->
              {ok, Next, Hash, _Resets} = mcl_chess_rules:apply_move(Fen, Uci),
              {Next, Hash}
      end,
      {?START, 0},
      Moves).
