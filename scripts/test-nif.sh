#!/usr/bin/env bash
# The rules engine's own gate: the perft cross-checks and the FIDE-position
# tests. Run by CI after the Erlang steps, so the correctness heart of the
# referee is gated and not just compiled.
#
# Release is not an optimization here, it is the configuration the deep perft
# depths are compiled for (src/perft_tests.rs). A debug build generates moves
# roughly thirty times slower, which turns the start position at depth five
# from a fraction of a second into a minute.
#
# --lib because the NIF registration is compiled out under cfg(test): the
# enif_* calls it makes only exist inside the BEAM. See src/nif.rs.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

cd "$ROOT/native/mcl_chess_rules"
cargo test --release --locked --lib
