#!/usr/bin/env bash
# Reproduce (or refute) mcl-chess#7: a NIF shared object rewritten in place
# while a live VM has it mapped. Fable's diagnosis, from the core at
# 2026-10-17: the .so's fini_array[0] read as 0 because the file's pages under
# the mapping were replaced after the loader had relocated them.
#
# Usage: fault-in-place.sh <mode> [rounds]
#   mode = overwrite : install the way build-nif.sh used to, `cp src dst`
#   mode = atomic    : install with `cp src dst.tmp && mv -f` (new inode)
#
# For each round: start a VM that loads the NIF and waits, replace the .so while
# it waits, then let it stop and record how it exited.
set -uo pipefail

MODE="${1:?mode: overwrite | atomic}"
ROUNDS="${2:-5}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/native/mcl_chess_rules/target/release/libmcl_chess_rules.so"
DST="$ROOT/apps/play_games/priv/lib/libmcl_chess_rules.so"

[ -f "$SRC" ] || { echo "no built library at $SRC" >&2; exit 1; }
[ -f "$DST" ] || { echo "no installed library at $DST" >&2; exit 1; }

install() {
    case "$MODE" in
        overwrite)
            cp "$SRC" "$DST"
            ;;
        atomic)
            cp "$SRC" "$DST.tmp.$$"
            mv -f "$DST.tmp.$$" "$DST"
            ;;
        *)
            echo "unknown mode $MODE" >&2
            exit 2
            ;;
    esac
}

crashes=0
for round in $(seq 1 "$ROUNDS"); do
    (
        erl -noshell -pa "$ROOT/_build/test/lib"/*/ebin \
            -eval 'ok = mcl_chess_rules:validate_move(<<"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1">>, <<"e2e4">>), timer:sleep(2500), halt(0).'
    ) >/dev/null 2>&1 &
    vm=$!
    sleep 1
    install
    wait "$vm"
    code=$?
    if [ "$code" -ne 0 ]; then
        crashes=$((crashes + 1))
        echo "round $round: vm exit=$code"
    fi
done
echo "mode=$MODE rounds=$ROUNDS crashes=$crashes"
