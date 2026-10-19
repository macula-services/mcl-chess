#!/usr/bin/env bash
# Build the chess rules NIF and install it into the app that loads it.
#
# Runs from rebar3's compile pre_hook (apps/play_games/rebar.config), so it runs
# wherever this project is compiled, including inside the image's builder stage.
# It is the mcl-embed pattern: cargo directly, no rebar3_cargo, because rustler
# 0.34 pulls mix-only transitives that rebar3 cannot build and the Erlang side
# needs no rustler at all.
#
# CARGO_BUILD_JOBS is passed through to cargo. On a shared box, cap it:
#   CARGO_BUILD_JOBS=8 rebar3 compile
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CRATE="$ROOT/native/mcl_chess_rules"
DEST="$ROOT/apps/play_games/priv/lib"

cargo build --release --locked --manifest-path "$CRATE/Cargo.toml"

mkdir -p "$DEST"
case "$(uname -s)" in
    Linux*)   ext=so ;;
    Darwin*)  ext=dylib ;;
    *) echo "Unsupported: $(uname -s)" >&2; exit 1 ;;
esac

src="$CRATE/target/release/libmcl_chess_rules.$ext"
dst="$DEST/libmcl_chess_rules.$ext"
cp "$src" "$dst"
echo "Built: $dst"
