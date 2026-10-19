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

# INSTALL WITH A NEW INODE, NEVER IN PLACE (mcl-chess#7).
#
# A VM that has loaded this library has it mmap'd. `cp src dst` truncates and
# rewrites the file the mapping is backed by, and the kernel then serves
# unrelocated file content to an already-relocated DSO: the loader's
# fini_array[0] reads as 0 and the VM dies at shutdown with SIGSEGV inside
# _dl_fini, or with SIGBUS part way through a copy. Two `rebar3` runs in one
# checkout are enough to do it, because this script runs from the compile
# pre_hook every time.
#
# cp to a temporary name and rename it: rename(2) is atomic, a running VM keeps
# the inode it mapped, and the next load gets the new file.
tmp="$dst.tmp.$$"
cp "$src" "$tmp"
mv -f "$tmp" "$dst"
echo "Built: $dst"
