#!/usr/bin/env bash
# Read a real world twice - once with the loader the renderer uses, once with an
# independent Python implementation - and compare them block by block.
#
# usage: tools/check_real_world.sh [world dir] [out dir] [detail radius]
set -euo pipefail
WORLD="${1:-build/server/run/world}"
OUT="${2:-build/world}"
# Both readers dump every block within this many chunks of the origin; the block the
# server itself reported (`tools/probe_server_blocks.py`) is compared against it, so the
# real-world run asks for a radius that covers the sampled grid.
RADIUS="${3:-1}"
GOOSE="${GOOSE:-build/bin/goose}"
export GOOSE_STDLIB="${GOOSE_STDLIB:-build/goose-src/stdlib}"
mkdir -p "$OUT"

echo "== building the loader"
"$GOOSE" --standalone -o build/worldload.c goose/worldload.goose
${CC:-cc} -O2 -o build/umbra_worldload build/worldload.c platform/shared/umbra_glue.c -lm -lpthread

echo "== reading $WORLD with the loader the renderer uses"
build/umbra_worldload "$WORLD" "$OUT/goose.txt" "$RADIUS" | tee "$OUT/goose.log"

echo "== reading the same world with the independent reader"
python3 tools/world_oracle.py "$WORLD" "$OUT/oracle.txt" "$RADIUS" | tee "$OUT/oracle.log"

echo "== comparing"
python3 tools/check_world.py "$OUT/goose.txt" "$OUT/oracle.txt" | tee "$OUT/compare.txt"
grep -qF "PASS: two independent readers agree on every block" "$OUT/compare.txt"
echo "PASS: the world the server generated is read the same way twice"
