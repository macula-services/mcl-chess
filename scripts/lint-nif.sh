#!/usr/bin/env bash
# The rules engine's lint: rustfmt and clippy, both fatal.
#
# Not run by CI, and that is deliberate: the pinned build image
# (macula-ci-otp) carries cargo and rustc but not the clippy and rustfmt
# components, and installing them at CI time would mean CI linting with a
# toolchain that is not the one the image pins. Run this before pushing a
# change to the crate; scripts/test-nif.sh is the part CI does run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

cd "$ROOT/native/mcl_chess_rules"
cargo fmt --check
cargo clippy --release --all-targets --locked -- -D warnings
