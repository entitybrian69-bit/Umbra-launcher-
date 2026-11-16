#!/usr/bin/env bash
# Ask the running server whether the blocks Umbra read are where Umbra says they are,
# while that server still holds the world in memory.
#
# usage: tools/compare_with_server.sh <run dir> <host> <port> <password>
#
# Why this shape: gate 6b's second half wants the real client rendered in CI, and it
# cannot be. The brief allows the alternative it names -- compare the block data with
# what the real server reports -- and this is that comparison, with the one caveat that
# decides how it has to work: this server version's `/data get block` answers only for
# block *entities* ("The target block is not a block entity"), so the server cannot be
# asked "what is at x y z?". It can be asked the other way round, which is just as good
# an oracle: `execute if block x y z <state>` is true only if the block and all its
# properties match. So Umbra reads the save, and the game confirms or denies each of
# those claims.
#
# The world is flushed to disk first (`save-all flush`) so the files Umbra reads are the
# state the server is about to be asked about.
set -uo pipefail
RUN="${1:?run dir}"
HOST="${2:-127.0.0.1}"
PORT="${3:-25575}"
PW="${4:-umbra-ci}"
TOOLS="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TOOLS/.." && pwd)"
GOOSE="${GOOSE:-$ROOT/build/bin/goose}"
export GOOSE_STDLIB="${GOOSE_STDLIB:-$ROOT/build/goose-src/stdlib}"

echo "== flushing the world to disk so the reader sees what the server holds"
if ! python3 "$TOOLS/rcon.py" "$HOST" "$PORT" "$PW" "save-all flush"; then
    echo "compare: FAIL the server did not accept save-all flush"
    exit 1
fi
sleep 3

echo "== reading the save with Umbra's loader"
if [ ! -x "$ROOT/build/umbra_worldload" ] || [ "$ROOT/goose/worldload.goose" -nt "$ROOT/build/umbra_worldload" ]; then
    "$GOOSE" --standalone -o "$ROOT/build/worldload.c" "$ROOT/goose/worldload.goose" || exit 1
    ${CC:-cc} -O2 -o "$ROOT/build/umbra_worldload" "$ROOT/build/worldload.c" \
        "$ROOT/platform/shared/umbra_glue.c" -lm -lpthread || exit 1
fi
# Radius 10 chunks around the origin: the detail lines only exist for chunks that are in
# the save, and a radius-3 dump of this world came back with none of them.
"$ROOT/build/umbra_worldload" "$RUN/world" "$RUN/goose-dump.txt" 10 || exit 1
# The renderer reads the same save at radius 6 and prints its own non-air total. Reading it
# here at the same radius is what makes the two numbers comparable: they come from the same
# files, and a difference between them is a reader difference, not a window difference.
"$ROOT/build/umbra_worldload" "$RUN/world" "$RUN/goose-dump6.txt" 6 \
    | grep "^worldload: chunks" | sed 's/^/compare: at radius 6 /'

grep -c '^detail ' "$RUN/goose-dump.txt" | sed 's/^/compare: detail lines for the grid: /'

echo "== asking the server about every claim"
python3 "$TOOLS/probe_server_blocks.py" "$HOST" "$PORT" "$PW" \
    "$RUN/goose-dump.txt" "$RUN/server-blocks.txt"
