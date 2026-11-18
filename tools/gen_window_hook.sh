#!/usr/bin/env bash
# Make sure the save the phone is about to open has finished generating.
#
# This is tools/compare_with_server.sh's settling loop, without the comparison: flush the
# server's chunks to disk, read the save with the project's own world reader
# (`build/umbra_worldload`, the one the world gate has compared block for block against the
# real server for weeks), and repeat until the window is finished and its block count has
# stopped moving. Only then let the server be stopped, which is what writes the save the
# phone gets.
#
# Why it exists, in three failures:
#
#   44251941145  the archive held the save's *entities* files (fixed: the zip takes only
#                */region/*.mca, and the import refuses a world with no blocks)
#   44253779192  the save held proto-chunks: valid chunks, every palette air, Status not
#                minecraft:full, at exactly the coordinates the phone opens
#   44260043266  a first version of this hook asked the server `execute if loaded`, which
#                answers true for a chunk that is loaded *and still generating*, so it
#                passed in a second and the save was written two seconds later
#
# "Loaded" is not "finished", and asking the game is not the same as reading the file it
# wrote. The world gate had already learned both lessons; this is that knowledge, reused.
#
# usage: tools/gen_window_hook.sh <run dir> <host> <port> <password>
set -uo pipefail
TOOLS="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TOOLS/.." && pwd)"
RUN="${1:-build/server/run}"
HOST="${2:-127.0.0.1}"
PORT="${3:-25575}"
PW="${4:-umbra-ci}"
# The import opens a window of 2 chunks around the origin (25 chunks). The detail radius
# here is 4, so the four chunks that share a face with the window are finished too: a
# neighbour that is still a proto-chunk has no blocks, and the mesher would cull faces
# against it as though it were air.
RADIUS="${UMBRA_PROBE_RADIUS:-4}"

cd "$ROOT" || exit 1

# The reader, built the same way tools/check_real_world.sh builds it.
if [ ! -x build/umbra_worldload ]; then
    echo "window: building the world reader the gate uses"
    GOOSE_BIN="${GOOSE:-$ROOT/build/bin/goose}"
    GOOSE_STDLIB="${GOOSE_STDLIB:-$ROOT/build/goose-src/stdlib}" \
        "$GOOSE_BIN" --standalone -o build/worldload.c goose/worldload.goose > build/worldload-build.log 2>&1 \
        && ${CC:-cc} -O2 -o build/umbra_worldload build/worldload.c platform/shared/umbra_glue.c \
             -lm -lpthread >> build/worldload-build.log 2>&1
fi
if [ ! -x build/umbra_worldload ]; then
    echo "window: FAIL the reader could not be built, so the save cannot be checked:"
    tail -20 build/worldload-build.log 2>/dev/null
    exit 1
fi

flush() {
    python3 "$TOOLS/rcon.py" "$HOST" "$PORT" "$PW" "save-all flush" || return 1
    sleep 3
}

# What the window holds, as the reader sees it. The reader prints
# "detail lines for chunks within N of the origin: <chunks> chunks, <blocks> non-air blocks"
# and names any chunk whose Status is not minecraft:full.
window() {
    grep -oE 'detail lines for chunks within [0-9]+ of the origin: [0-9]+ chunks, [0-9]+ non-air blocks' \
        "$RUN/settle.log" 2>/dev/null | head -1 | sed 's/.*: //'
}
unfinished() {
    grep -oE '\([0-9]+ of them within [0-9]+ of the origin\)' "$RUN/settle.log" 2>/dev/null | head -1
}

echo "window: settling the save at radius $RADIUS before it is handed to the phone"
prev=""
same=0
ok=0
for attempt in $(seq 1 12); do
    if ! flush; then
        echo "window: FAIL the server did not accept save-all flush"
        exit 1
    fi
    # --incomplete-ok because a save that is still being written has to be readable to be
    # measured; the loop is what decides whether it is finished.
    build/umbra_worldload "$RUN/world" "$RUN/settle.txt" "$RADIUS" --incomplete-ok \
        > "$RUN/settle.log" 2>&1
    now="$(window)"
    un="$(unfinished)"
    if [ -n "$un" ] && ! printf '%s' "$un" | grep -q '(0 of them'; then
        echo "window: attempt $attempt: ${now:-no window totals} - not finished ${un}"
        prev=""
        same=0
        sleep 4
        continue
    fi
    # No blocks in the window is not a window. This is the exact reading that went wrong
    # twice, and the reader can see it before the phone does.
    case "$now" in
        *"0 non-air blocks"*)
            echo "window: attempt $attempt: ${now:-no totals} - the window still has no blocks"
            prev=""
            same=0
            sleep 4
            continue
            ;;
    esac
    if [ -z "$now" ]; then
        echo "window: attempt $attempt: the reader printed no window totals; log tail:"
        tail -6 "$RUN/settle.log" 2>/dev/null
        sleep 4
        continue
    fi
    if [ "$now" = "$prev" ]; then
        same=$((same + 1))
    else
        same=0
    fi
    prev="$now"
    echo "window: attempt $attempt: $now (stable readings: $same)"
    if [ "$same" -ge 2 ]; then
        ok=1
        break
    fi
    sleep 4
done

if [ "$ok" != 1 ]; then
    echo "window: FAIL the window never settled at ${prev:-nothing}; the save would hold proto-chunks"
    tail -20 "$RUN/settle.log" 2>/dev/null
    exit 1
fi
echo "window: PASS the window is finished and its block count is stable: $prev"
echo "window: the save the phone gets is this one; the server stops next, which writes it"
