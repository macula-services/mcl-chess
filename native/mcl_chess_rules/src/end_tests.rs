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
use crate::rules::{apply_move, cannot_mate, position_hash, status};
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

// FIDE 6.9 (mcl-chess#6, WP7): the one-sided question a flag asks. It is not
// `is_insufficient_material`, which asks whether NEITHER side can mate; a flag
// only cares about the side that would otherwise be credited with the win.

/// A pawn, a rook or a queen always mates eventually, so the answer is no.
#[test]
fn a_side_with_mating_material_can_mate() {
    assert!(!cannot_mate(START, "w").unwrap());
    assert!(!cannot_mate(START, "b").unwrap());
    let pawn = "4k3/8/8/8/8/8/4P3/4K3 w - - 0 1";
    assert!(
        !cannot_mate(pawn, "w").unwrap(),
        "a pawn can become a queen"
    );
}

/// A bare king has no mating move at all.
#[test]
fn a_bare_king_cannot_mate() {
    let bare = "4k3/8/8/8/8/8/8/4K3 w - - 0 1";
    assert!(cannot_mate(bare, "w").unwrap());
    assert!(cannot_mate(bare, "b").unwrap());
}

/// One minor piece cannot mate a bare king, because nothing on the board can
/// block a flight square. Give the defender a piece and the same material can
/// mate with help, which FIDE 6.9 counts: "any possible series of legal moves".
#[test]
fn one_minor_piece_needs_something_to_block_with() {
    let knight = "4k3/8/8/8/8/8/8/4KN2 w - - 0 1";
    assert!(cannot_mate(knight, "w").unwrap());
    let knight_vs_pawn = "4k3/4p3/8/8/8/8/8/4KN2 w - - 0 1";
    assert!(!cannot_mate(knight_vs_pawn, "w").unwrap());
    let bishop_vs_bishop = "2b1k3/8/8/8/8/8/8/4KB2 w - - 0 1";
    assert!(!cannot_mate(bishop_vs_bishop, "w").unwrap());
}

/// The issue's own example: the flagged side holds a queen, the opponent a bare
/// king. Under FIDE 6.9 the bare king cannot mate, so the game is drawn; the
/// queen, which belongs to the side that ran out, does not help it.
#[test]
fn the_flagged_sides_material_is_not_the_opponents() {
    let queen = "7k/8/8/8/8/8/6Q1/6K1 w - - 0 1";
    assert!(cannot_mate(queen, "b").unwrap(), "black has a bare king");
    assert!(!cannot_mate(queen, "w").unwrap(), "white has a queen");
}

/// Two minor pieces are treated as able to mate. Two knights against a bare
/// king is the one position that over-credits: no mate exists there, and the
/// referee errs towards recording a win rather than silently drawing a game
/// nobody claimed was drawn.
#[test]
fn two_minor_pieces_are_able_to_mate() {
    let two_knights = "4k3/8/8/8/8/8/8/1N2KN2 w - - 0 1";
    assert!(!cannot_mate(two_knights, "w").unwrap());
    let knight_and_bishop = "4k3/8/8/8/8/8/8/1N2KB2 w - - 0 1";
    assert!(!cannot_mate(knight_and_bishop, "w").unwrap());
}

/// Anything it cannot read is refused in the referee's own vocabulary, never
/// guessed at: a caller that mistyped a colour must not be told a dead position.
#[test]
fn cannot_mate_refuses_what_it_cannot_read() {
    assert_eq!(cannot_mate("nonsense", "w"), Err(MoveError::InvalidFen));
    assert_eq!(cannot_mate(START, "x"), Err(MoveError::InvalidMove));
    assert_eq!(cannot_mate(START, ""), Err(MoveError::InvalidMove));
}
