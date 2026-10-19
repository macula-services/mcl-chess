//! The NIF surface of `mcl_chess_rules`.
//!
//! Three functions, stateless, microsecond scale: validate a move, apply a
//! move, give a verdict. The logic lives in [`crate::rules`], which knows
//! nothing about the BEAM and is tested on its own; this module is the thin
//! translation between Rust values and Erlang terms.
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
use rustler::{Atom, Encoder, Env, NifResult, Term};

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
    }
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
    }
}

/// `validate_move(Fen, Uci) -> ok | {error, Reason}`
#[rustler::nif]
pub fn validate_move<'a>(env: Env<'a>, fen: String, uci: String) -> NifResult<Term<'a>> {
    Ok(match rules::validate_move(&fen, &uci) {
        Ok(()) => atoms::ok().encode(env),
        Err(error) => (atoms::error(), reason_atom(error)).encode(env),
    })
}

/// `apply_move(Fen, Uci) -> {ok, Fen, ZobristHash} | {error, Reason}`
#[rustler::nif]
pub fn apply_move<'a>(env: Env<'a>, fen: String, uci: String) -> NifResult<Term<'a>> {
    Ok(match rules::apply_move(&fen, &uci) {
        Ok((next, hash)) => (atoms::ok(), next, hash).encode(env),
        Err(error) => (atoms::error(), reason_atom(error)).encode(env),
    })
}

/// `status(Fen, HalfmoveClock) -> active | checkmate | stalemate
/// | insufficient_material | {error, invalid_fen}`
#[rustler::nif]
pub fn status<'a>(env: Env<'a>, fen: String, halfmove_clock: u8) -> NifResult<Term<'a>> {
    Ok(match rules::status(&fen, halfmove_clock) {
        Ok(verdict) => verdict_atom(verdict).encode(env),
        Err(error) => (atoms::error(), reason_atom(error)).encode(env),
    })
}
