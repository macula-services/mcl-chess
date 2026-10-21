#!/usr/bin/env bash
# The rules engine's lint: rustfmt and clippy, both fatal.
#
# CI gates clippy itself (lint.yml adds the clippy component for the image's
# pinned rustc, so the toolchain does not float); rustfmt is not installed
# there, so `cargo fmt --check` stays yours to run before a push. Run this
# before pushing a change to the crate; scripts/test-nif.sh is the other part
# CI runs.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

cd "$ROOT/native/mcl_chess_rules"
cargo fmt --check
cargo clippy --release --all-targets --locked -- -D warnings
