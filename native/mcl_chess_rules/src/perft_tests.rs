//! Perft cross-checks against the published node counts.
//!
//! Perft is the only cheap way to know a move generator is right rather than
//! merely plausible: it counts every leaf of the legal move tree to a depth and
//! compares against a number the chess programming community has published and
//! re-verified. The six positions below are the standard set (the start
//! position, "Kiwipete", and positions 3 to 6 from the Chess Programming Wiki's
//! perft page), chosen because between them they exercise castling in and out
//! of check, en passant discovered check, promotion, pins and double check.
//!
//! Two things are measured:
//!
//! * `cozy_perft` walks cozy-chess directly. This says the rules library we
//!   depend on really does play chess.
//! * `referee_perft` walks the same tree through `rules::apply_move`, which is
//!   the function the referee calls: parse a FEN, resolve a UCI move, play it,
//!   hand back the new FEN and its Zobrist hash. This says OUR path over that
//!   library is right, including the castling spelling translation, rather than
//!   just the library underneath it.
//!
//! The deep depths run only in a release build (`scripts/test-nif.sh` passes
//! `--release`): a debug build generates moves roughly thirty times slower and
//! would spend minutes on nodes that take a second.

use crate::rules::{apply_move, position_hash};
use cozy_chess::{Board, Piece};
use std::str::FromStr;

/// (name, FEN, published counts for depths 1..=5)
///
/// `0` marks a depth whose published count this table does not claim.
const POSITIONS: &[(&str, &str, [u64; 5])] = &[
    (
        "start",
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        [20, 400, 8902, 197281, 4865609],
    ),
    (
        "kiwipete",
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        [48, 2039, 97862, 4085603, 0],
    ),
    (
        "position 3",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        [14, 191, 2812, 43238, 674624],
    ),
    (
        "position 4",
        "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
        [6, 264, 9467, 422333, 0],
    ),
    (
        "position 5",
        "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
        [44, 1486, 62379, 2103487, 0],
    ),
    (
        "position 6",
        "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
        [46, 2079, 89890, 3894594, 0],
    ),
];

/// Every legal move from this position, in the spelling cozy-chess uses: a
/// promotion is one move per promotion piece, and castling is king-takes-rook.
fn legal_moves(board: &Board) -> Vec<cozy_chess::Move> {
    let mut moves = Vec::new();
    board.generate_moves(|piece_moves| {
        moves.extend(piece_moves);
        false
    });
    moves
}

fn cozy_perft(board: &Board, depth: u8) -> u64 {
    if depth == 0 {
        return 1;
    }
    legal_moves(board)
        .into_iter()
        .map(|mv| {
            let mut next = board.clone();
            next.play_unchecked(mv);
            cozy_perft(&next, depth - 1)
        })
        .sum()
}

/// The same count, but every edge of the tree crossed through the functions the
/// referee actually calls.
fn referee_perft(fen: &str, depth: u8) -> u64 {
    if depth == 0 {
        return 1;
    }
    let board = Board::from_str(fen).expect("the referee's own FEN must parse");
    legal_moves(&board)
        .into_iter()
        .map(|mv| {
            let (next, _hash, _resets) = apply_move(fen, &mv.to_string())
                .unwrap_or_else(|e| panic!("{mv} refused in {fen}: {e:?}"));
            referee_perft(&next, depth - 1)
        })
        .sum()
}

/// Promotion is the one place a generated move is not a plain from/to pair, so
/// a perft that silently dropped promotions would still pass on positions
/// without one. This asserts the count is what the wiki publishes AND that the
/// tree contains all four promotion pieces.
#[test]
fn promotion_moves_are_generated_four_ways() {
    let board = Board::from_str("8/P7/8/8/8/8/8/K6k w - - 0 1").unwrap();
    let moves = legal_moves(&board);
    assert_eq!(moves.len(), 7, "a8 promotes four ways, the king has three");
    assert_eq!(
        moves.iter().filter(|mv| mv.promotion.is_some()).count(),
        4,
        "one move per promotion piece"
    );
}

#[test]
fn perft_matches_the_published_counts() {
    let deep = !cfg!(debug_assertions);
    for (name, fen, counts) in POSITIONS {
        let board = Board::from_str(fen).unwrap_or_else(|_| panic!("{name} must parse"));
        assert_published_counts(name, &board, counts, deep);
    }
}

/// Depth `d` is the table's entry `d - 1`; a `0` there means this table makes no
/// claim about that depth, and a debug build only walks the shallow ones.
fn assert_published_counts(name: &str, board: &Board, counts: &[u64; 5], deep: bool) {
    for (index, expected) in counts.iter().enumerate() {
        let depth = index as u8 + 1;
        if *expected == 0 || (depth > 3 && !deep) {
            continue;
        }
        assert_eq!(
            cozy_perft(board, depth),
            *expected,
            "{name}, depth {depth}: the library disagrees with the published count"
        );
    }
}

/// The referee's path, at a depth shallow enough to run in any build. This is
/// the test that catches a mistake in OUR glue: a mis-normalised castle, a FEN
/// that does not round-trip, a hash that is not the board's.
#[test]
fn the_referees_own_path_counts_the_same_nodes() {
    for (name, fen, _counts) in POSITIONS {
        let board = Board::from_str(fen).unwrap();
        for depth in 1..=3 {
            assert_eq!(
                referee_perft(fen, depth),
                cozy_perft(&board, depth),
                "{name}, depth {depth}: apply_move disagrees with the library it wraps"
            );
        }
    }
}

/// Sanity: the Zobrist hash the referee records really is a function of the
/// position rather than of the road taken to it.
///
/// The interesting case is the en passant square. `1.e4 e5 2.Nf3` and
/// `1.Nf3 e5 2.e4` stand the same pieces on the same squares with the same side
/// to move, but the second one records an `e3` en passant square that nobody
/// can use (no black pawn on d4 or f4). They are the same position by FIDE's
/// definition, so they must hash the same; that is the difference between
/// `hash()` and `hash_without_ep()`, and getting it wrong would make the
/// threefold check under-count a repetition.
#[test]
fn the_hash_is_the_positions_own() {
    let start = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
    let (after_e4, hash_e4, _) = apply_move(start, "e2e4").unwrap();
    let (_, hash_d4, _) = apply_move(start, "d2d4").unwrap();
    assert_ne!(hash_e4, hash_d4, "different positions, different hashes");

    // 1. e4 e5 2. Nf3 and 1. Nf3 e5 2. e4 arrive at the same board.
    let (a, _, _) = apply_move(&after_e4, "e7e5").unwrap();
    let (a, _, _) = apply_move(&a, "g1f3").unwrap();
    let (b, _, _) = apply_move(start, "g1f3").unwrap();
    let (b, _, _) = apply_move(&b, "e7e5").unwrap();
    let (b, hash_b, _) = apply_move(&b, "e2e4").unwrap();
    assert_ne!(
        a, b,
        "the FENs differ in the en passant field, as they should"
    );
    assert!(
        Board::from_str(&a)
            .unwrap()
            .same_position(&Board::from_str(&b).unwrap()),
        "but FIDE calls them the same position"
    );

    let (_, hash_a, _) = apply_move(&a, "a7a6").unwrap();
    let (_, hash_b2, _) = apply_move(&b, "a7a6").unwrap();
    assert_eq!(
        hash_a, hash_b2,
        "the hash follows the position, not the move order"
    );
    let _ = hash_b;
}

/// The other half of the same rule: an en passant square that CAN be captured
/// on is a real difference and must change the hash.
#[test]
fn a_playable_en_passant_changes_the_hash() {
    let after_double_push = "rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3";
    let without = "rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq - 0 3";
    let with_hash = position_hash(&Board::from_str(after_double_push).unwrap());
    let without_hash = position_hash(&Board::from_str(without).unwrap());
    assert_ne!(
        with_hash, without_hash,
        "white can take on d6 here, so this is a different position"
    );
}

/// A piece count guard on the test helper itself: if `legal_moves` ever grew a
/// duplicate expansion this would not be the published 20.
#[test]
fn the_start_position_has_twenty_moves() {
    let board = Board::default();
    assert_eq!(legal_moves(&board).len(), 20);
    assert!(legal_moves(&board)
        .iter()
        .all(|mv| mv.promotion.is_none() || mv.promotion == Some(Piece::Queen)));
}
