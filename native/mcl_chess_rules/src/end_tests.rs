//! The referee's own count, and the verdicts that depend on it (WP5).
//!
//! Two things cozy-chess cannot answer by itself:
//!
//! * the **halfmove clock**: its `Board` keeps the FEN's counter, which is a
//!   `u8` capped at 100 (`play_unchecked` clamps it, and the builder refuses a
//!   larger one). The 75 move rule fires at 150 halfmoves, a number that
//!   counter can never reach, so the referee keeps its own count and this
//!   module pins the one fact it needs from a move: whether that move reset the
//!   count, which is exactly "a pawn moved or something was captured".
//! * the **verdict at that count**: a draw at 150 halfmoves, unless the move
//!   that got there was checkmate, which wins.
//!
//! Fivefold repetition is not here and cannot be: it is not a function of one
//! position. The aggregate counts it over the hashes the events recorded.

use crate::rules::{self, MoveError, Verdict};
use crate::rules::{apply_move, position_hash, status};
use cozy_chess::Board;
use std::str::FromStr;

const START: &str = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";

/// A capture on the 150th halfmove is still a draw by the counter, and the
/// counter is the referee's, so `status/2` has to take it seriously.
#[test]
fn the_counter_reaches_the_seventy_five_move_rule() {
    assert_eq!(status(START, 149).unwrap(), Verdict::Active);
    assert_eq!(status(START, 150).unwrap(), Verdict::SeventyFiveMoves);
    assert_eq!(status(START, 151).unwrap(), Verdict::SeventyFiveMoves);
    assert_eq!(
        status(START, u64::MAX).unwrap(),
        Verdict::SeventyFiveMoves,
        "the count has no ceiling of its own"
    );
}

/// Checkmate on the move that reaches the counter is a win, not a draw: FIDE
/// puts the mate first, and so does the referee.
#[test]
fn checkmate_beats_the_counter() {
    // Fool's mate, with the counter already at the threshold.
    let mate = "rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3";
    assert_eq!(status(mate, 150).unwrap(), Verdict::Checkmate);
}

/// A stalemate at the counter reports the position's own reason, not the
/// counter's: both are draws, and the specific one is the more useful record.
#[test]
fn a_dead_position_reports_its_own_reason() {
    let stale = "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1";
    assert_eq!(status(stale, 150).unwrap(), Verdict::Stalemate);
    let bare = "4k3/8/8/8/8/8/8/4K3 w - - 0 1";
    assert_eq!(status(bare, 150).unwrap(), Verdict::InsufficientMaterial);
}

/// The one bit of the counter the referee needs from a move. Cozy clamps the
/// FEN's counter, so reading `0` back out of it would work only by accident;
/// the move says what it did.
#[test]
fn apply_move_says_when_it_resets_the_counter() {
    let (_, _, reset) = apply_move(START, "e2e4").unwrap();
    assert!(reset, "a pawn move resets the counter");
    let (_, _, reset) = apply_move(START, "g1f3").unwrap();
    assert!(!reset, "a quiet knight move does not");
    let (after, _, reset_push) = apply_move(START, "e2e4").unwrap();
    assert!(reset_push, "a first pawn move resets the counter");
    let (_, _, reset_quiet) = apply_move(&after, "g8f6").unwrap();
    assert!(!reset_quiet, "a knight move does not");
    let fen_after_capture_ready = "rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3";
    let (_, _, capture) = apply_move(fen_after_capture_ready, "e4d5").unwrap();
    assert!(capture, "a capture resets the counter");
}

/// A castle is the one capture that does not: the rook on h1 is where the king
/// lands, and cozy spells the move that way.
#[test]
fn castling_is_not_a_capture() {
    let fen = "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 4 1";
    let (_, _, reset) = apply_move(fen, "e1g1").unwrap();
    assert!(!reset, "castling does not reset the halfmove counter");
}

/// The hash of a position, without playing a move into it. The aggregate seeds
/// its repetition history with the position a game starts from.
#[test]
fn a_position_can_be_hashed_without_a_move() {
    let by_function = position_hash(&Board::from_str(START).unwrap());
    let (_, by_move, _) = apply_move(
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        "e2e4",
    )
    .unwrap();
    assert_ne!(
        by_function, by_move,
        "a different position, a different hash"
    );
    assert_eq!(
        by_function,
        position_hash(
            &Board::from_str("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 4 1").unwrap()
        ),
        "the counter and the move number are not part of the position"
    );
    assert_eq!(rules::position_hash_of(START).unwrap(), by_function);
    assert_eq!(
        rules::position_hash_of("nonsense"),
        Err(MoveError::InvalidFen)
    );
}
