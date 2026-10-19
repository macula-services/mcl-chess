//! The NIF surface of `mcl_chess_rules`.
//!
//! Five functions, stateless, microsecond scale: validate a move, apply a
//! move, hash a position, give a verdict, and answer FIDE 6.9's one-sided
//! question about mating material. The logic lives in [`crate::rules`], which
//! knows nothing about the BEAM and is tested on its own; this module is the
//! thin translation between Rust values and Erlang terms.
//!
//! There is no dirty scheduler here and no state: every call is bounded by one
//! FEN parse and one move-generation pass, which is scheduler-safe at this
//! size. The referee's state lives in its aggregate and its event stream.
//!
//! ⚠ This module is compiled out under `cfg(test)`. The `enif_*` calls a NIF
//! makes are resolved by the BEAM at load time and do not exist in a test
//! binary, so linking them there fails. Keeping the pure logic in its own
//! module is what lets the perft suite run as an ordinary `cargo test`.
//!
//! ⚠ Each function builds its own reply term rather than returning a Rust
//! `Result`: rustler encodes `Result` as `{ok, Value}` / `{error, Value}`, and
//! a refusal is already a two-tuple of atoms on the wire. Wrapping one in the
//! other gives `{error, {error, illegal_move}}`, which is what the BEAM tests
//! caught before these functions were written this way.

use crate::rules;
use rustler::{Atom, Binary, Encoder, Env, NifResult, Term};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_fen,
        invalid_move,
        illegal_move,
        active,
        checkmate,
        stalemate,
        insufficient_material,
        seventy_five_moves,
    }
}

/// A payload arrives as a binary, and a hostile caller can send bytes that are
/// not UTF-8 at all. Decoding into a `String` would make rustler raise instead
/// of returning a refusal, so the caller's process would die on input it was
/// supposed to be judging. These read the bytes and refuse them in the
/// referee's own vocabulary.
fn fen_str(fen: Binary<'_>) -> Result<&str, rules::MoveError> {
    std::str::from_utf8(fen.as_slice()).map_err(|_| rules::MoveError::InvalidFen)
}

fn uci_str(uci: Binary<'_>) -> Result<&str, rules::MoveError> {
    std::str::from_utf8(uci.as_slice()).map_err(|_| rules::MoveError::InvalidMove)
}

/// A colour arrives as `<<"w">>` or `<<"b">>`, the same text the aggregate's
/// `to_move` carries. Anything else is a caller that mistyped, not a position
/// this engine cannot read, so it is refused the way a malformed move is.
fn colour_str(colour: Binary<'_>) -> Result<&str, rules::MoveError> {
    std::str::from_utf8(colour.as_slice()).map_err(|_| rules::MoveError::InvalidMove)
}

fn reason_atom(error: rules::MoveError) -> Atom {
    match error {
        rules::MoveError::InvalidFen => atoms::invalid_fen(),
        rules::MoveError::InvalidMove => atoms::invalid_move(),
        rules::MoveError::IllegalMove => atoms::illegal_move(),
    }
}

fn verdict_atom(verdict: rules::Verdict) -> Atom {
    match verdict {
        rules::Verdict::Active => atoms::active(),
        rules::Verdict::Checkmate => atoms::checkmate(),
        rules::Verdict::Stalemate => atoms::stalemate(),
        rules::Verdict::InsufficientMaterial => atoms::insufficient_material(),
        rules::Verdict::SeventyFiveMoves => atoms::seventy_five_moves(),
    }
}

/// The 1/0 the rest of the division uses for flags, rather than an Erlang
/// boolean: the halfmove-reset bit and FIDE 6.9's answer are both flags, and one
/// convention everywhere is one thing to remember.
fn flag(value: bool) -> u32 {
    if value {
        1
    } else {
        0
    }
}

/// `validate_move(Fen, Uci) -> ok | {error, Reason}`
#[rustler::nif]
pub fn validate_move<'a>(env: Env<'a>, fen: Binary<'a>, uci: Binary<'a>) -> NifResult<Term<'a>> {
    let result =
        fen_str(fen).and_then(|fen| uci_str(uci).and_then(|uci| rules::validate_move(fen, uci)));
    Ok(match result {
        Ok(()) => atoms::ok().encode(env),
        Err(error) => (atoms::error(), reason_atom(error)).encode(env),
    })
}

/// `apply_move(Fen, Uci) -> {ok, Fen, ZobristHash, ResetsHalfmoveCounter}
/// | {error, Reason}`
#[rustler::nif]
pub fn apply_move<'a>(env: Env<'a>, fen: Binary<'a>, uci: Binary<'a>) -> NifResult<Term<'a>> {
    let result =
        fen_str(fen).and_then(|fen| uci_str(uci).and_then(|uci| rules::apply_move(fen, uci)));
    Ok(match result {
        Ok((next, hash, resets)) => (atoms::ok(), next, hash, flag(resets)).encode(env),
        Err(error) => (atoms::error(), reason_atom(error)).encode(env),
    })
}

/// `position_hash(Fen) -> ZobristHash | {error, invalid_fen}`
///
/// The aggregate seeds its repetition history with this, so a game's own start
/// position is counted when a repetition returns to it.
#[rustler::nif]
pub fn position_hash<'a>(env: Env<'a>, fen: Binary<'a>) -> NifResult<Term<'a>> {
    Ok(match fen_str(fen).and_then(rules::position_hash_of) {
        Ok(hash) => hash.encode(env),
        Err(error) => (atoms::error(), reason_atom(error)).encode(env),
    })
}

/// `status(Fen, HalfmoveClock) -> active | checkmate | stalemate
/// | insufficient_material | seventy_five_moves | {error, invalid_fen}
///
/// `HalfmoveClock` is the referee's own count, `u64`: the FEN's field is capped
/// at 100 by the library under this one, and the 75 move rule fires at 150.
#[rustler::nif]
pub fn status<'a>(env: Env<'a>, fen: Binary<'a>, halfmove_clock: u64) -> NifResult<Term<'a>> {
    Ok(
        match fen_str(fen).and_then(|fen| rules::status(fen, halfmove_clock)) {
            Ok(verdict) => verdict_atom(verdict).encode(env),
            Err(error) => (atoms::error(), reason_atom(error)).encode(env),
        },
    )
}

/// `cannot_mate(Fen, Colour) -> 1 | 0 | {error, Reason}`
///
/// FIDE 6.9, asked of one colour: can it deliver checkmate by any possible
/// series of legal moves? A flag asks it about the side that would otherwise be
/// credited with the win, which is the one question `is_insufficient_material`
/// (neither side can mate) cannot answer.
///
/// The answer is 1 for "cannot mate", so a caller that reads it as a flag never
/// has to invert it.
#[rustler::nif]
pub fn cannot_mate<'a>(env: Env<'a>, fen: Binary<'a>, colour: Binary<'a>) -> NifResult<Term<'a>> {
    let result = fen_str(fen)
        .and_then(|fen| colour_str(colour).and_then(|colour| rules::cannot_mate(fen, colour)));
    Ok(match result {
        Ok(cannot) => flag(cannot).encode(env),
        Err(error) => (atoms::error(), reason_atom(error)).encode(env),
    })
}
