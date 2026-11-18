#!/usr/bin/env bash
# Ask the still-running server to finish generating the chunk window the phone will open.
#
# Why this exists. `gen_server_world.sh` starts the server, waits for `Done (…)` and then
# asks it to stop, which is what makes it write its region files. A server that has just
# finished starting has written the *spawn area* and, in 26.3, proto-chunks at chunk
# coordinates whose only content is biome and structure-start data: `Status` is not
# `minecraft:full`, every palette is air, and a reader sees chunks that hold no blocks.
# The phone's window is chunk -2..2, and on 2026-11-18 run 44253779192 opened exactly that
# window and got "25 chunk(s), non-air blocks 0, states 600, not-full chunks 25" — the
# import then refused it, correctly, and the job went red for a reason that was about
# world generation and not about Umbra.
#
# world.yml gets a generated window from `tools/compare_with_server.sh`, which force-loads a
# radius-10 box before reading anything. The android job does not need a comparison, only a
# world with blocks in it, so this is the same idea without the oracle: force-load the
# window, read back how many chunks the server says it completed, and let the save happen.
#
# usage: tools/gen_window_hook.sh <run dir> <host> <port> <password>
set -uo pipefail
TOOLS="$(cd "$(dirname "$0")" && pwd)"
RUN="${1:-build/server/run}"
HOST="${2:-127.0.0.1}"
PORT="${3:-25575}"
PW="${4:-umbra-ci}"
# A little wider than the import's window (25 chunks, radius 2), so the four chunks that
# share a section face with it are finished too: a neighbour that is still a proto-chunk
# has no blocks, and the mesher would cull faces against it as if it were air.
RADIUS="${UMBRA_PROBE_RADIUS:-4}"

BOX0=$(( -RADIUS * 16 ))
BOX1=$(( RADIUS * 16 + 15 ))
ACROSS=$(( (BOX1 - BOX0 + 1) / 16 ))
STRIP=$(( 256 / ACROSS ))
[ "$STRIP" -lt 1 ] && STRIP=1

echo "window: forceloading chunk -${RADIUS}..${RADIUS} (${ACROSS}x${ACROSS} chunks) so it is finished"
fail=0
row=0
while [ "$row" -lt "$ACROSS" ]; do
    rows=$(( ACROSS - row ))
    [ "$rows" -gt "$STRIP" ] && rows="$STRIP"
    z0=$(( BOX0 + row * 16 ))
    z1=$(( z0 + rows * 16 - 1 ))
    reply="$(python3 "$TOOLS/rcon.py" "$HOST" "$PORT" \
             "forceload add $BOX0 $z0 $BOX1 $z1" 2>&1)"
    case "$reply" in
        *"Too many chunks"*|*FAIL*|"")
            echo "window: FAIL forceload $BOX0 $z0 $BOX1 $z1 was refused: $reply"
            fail=1
            ;;
        *) echo "window: forceload $BOX0 $z0 $BOX1 $z1 -> $reply" ;;
    esac
    row=$(( row + rows ))
done

# Force-loading queues the work; it does not wait for it. This is the part that went wrong
# first time: `execute if loaded` answers true for a chunk that is *loaded and still
# generating*, which is exactly a proto-chunk, so the hook passed in a second, the server
# saved two seconds later, and the phone got "25 chunks, non-air blocks 0, not-full chunks
# 25" a second run in a row. "Loaded" is not "generated".
#
# The probe is a block that only exists once the generator has finished: the bedrock layer
# at y -60. A proto-chunk has no block there at all, so `execute if block` fails until the
# chunk is real, and passes for ever after. Four points, one near each corner of the
# window, so a single slow corner cannot pass for the whole area.
echo "window: waiting until the window has blocks in it, not merely chunks that load"
ok=0
probes=0
for _ in $(seq 1 90); do
    probes=$((probes + 1))
    done_count=0
    for pz in "$BOX0" "0" "$BOX1"; do
        for px in "$BOX0" "0" "$BOX1"; do
            answer="$(python3 "$TOOLS/rcon.py" "$HOST" "$PORT" \
                      "execute if block $px -60 $pz minecraft:bedrock" 2>&1)"
            case "$answer" in
                *"Test passed"*) done_count=$((done_count + 1)) ;;
            esac
        done
    done
    if [ "$done_count" -eq 9 ]; then
        ok=1
        break
    fi
    [ $((probes % 5)) -eq 0 ] && echo "window: ${done_count}/9 probes have bedrock so far after ${probes} tries"
    sleep 2
done
if [ "$ok" = 1 ]; then
    echo "window: the window is generated -- bedrock at y -60 under all 9 probe points, after ${probes} tries"
else
    echo "window: FAIL only ${done_count:-0}/9 probes have bedrock after ${probes} tries; the save would hold proto-chunks"
    exit 1
fi

# The number that matters, said by the server: how many chunks are in the force-load set.
echo "window: $(python3 "$TOOLS/rcon.py" "$HOST" "$PORT" "forceload query" 2>&1 | head -3)"
[ "$fail" = 0 ] && exit 0 || exit 1
