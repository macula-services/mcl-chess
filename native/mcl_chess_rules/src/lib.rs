//! `mcl_chess_rules`: the chess referee's rules engine.
//!
//! A Rustler NIF over [cozy-chess](https://crates.io/crates/cozy-chess), a
//! perft-verified move generator with legal-only generation and incremental
//! Zobrist hashing (MIT; the licensing decision is in mcl-chess#1's design of
//! record).
//!
//! Two layers, deliberately:
//!
//! * [`rules`] is pure Rust with no BEAM types in it. It parses a FEN, resolves
//!   a UCI move, plays it, hashes the result and gives a verdict. This is where
//!   the perft cross-checks bite.
//! * the `nif` module (compiled out under `cfg(test)`) translates those
//!   functions into Erlang terms for the BEAM.
//!
//! The BEAM-side module is `mcl_chess_rules.erl` in the `play_games` app, which
//! loads this library from `<app>/priv/lib`.

pub mod rules;

#[cfg(test)]
mod perft_tests;

#[cfg(not(test))]
mod nif;

#[cfg(not(test))]
rustler::init!("mcl_chess_rules");
