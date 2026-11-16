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

# --- the comparison has to be like for like ------------------------------------
# Run 43847395025 is why this is here. The save was read while the server was still
# generating: 529 chunks and 44 states at read time, 1089 chunks and 76 states in the
# same save after the stop. Then the probe force-loaded the very chunks it was about to
# ask about, which completed their generation - carvers, ores, plants - and turned the
# stone Umbra had honestly read out of the file into the caves the game then held. Ten of
# the seventeen denials were `stone` at y=54, confirmed at that same height 26 times:
# that is a world that moved between the read and the question, not a reader that lies.
#
# So: force the sample area to generate first, then wait until two consecutive reads of
# the flushed save agree in every total. Only a save that has stopped changing can be
# compared with the game.
RADIUS="${UMBRA_PROBE_RADIUS:-10}"
# The detail window is RADIUS chunks around the origin; that, and nothing else, is what
# the probe may be asked about.
BOX0=$(( -RADIUS * 16 ))
BOX1=$(( RADIUS * 16 + 15 ))

echo "== forcing the sample area to generate before anything is read"
# This has to happen first and nowhere else. Forceloading a chunk completes its
# generation: carvers cut caves, ores and plants are placed. Doing it after the read (as
# the probe used to) meant the file Umbra had read was not the world the server was
# answering about, and the difference looked like the reader lying.
#
# The server caps a single `forceload add` at 256 chunks and answers "Too many chunks in
# the specified area (maximum 256, but specified 441)" for a radius-10 box. Run
# 43855851186 ignored that reply, went on to compare 529 half-generated chunks, and the
# only reason it was caught is that the loader now counts unfinished chunks. So the box is
# covered in strips that fit, and every reply is read.
# The count the server caps is the number of *chunk columns the block box touches*, which
# for a box on chunk boundaries is just its width and depth in chunks. The first version
# of this divided the block range into 256-block slices and asked for 336 chunks, and the
# server said so; this works in chunks and never asks for more than the cap.
CHUNKS_ACROSS=$(( (BOX1 - BOX0 + 1) / 16 ))
STRIP=$(( 256 / CHUNKS_ACROSS ))
[ "$STRIP" -lt 1 ] && STRIP=1
CHUNKS_DOWN=$(( (BOX1 - BOX0 + 1) / 16 ))
FORCELOADED=0
row=0
while [ "$row" -lt "$CHUNKS_DOWN" ]; do
    rows=$(( CHUNKS_DOWN - row ))
    [ "$rows" -gt "$STRIP" ] && rows="$STRIP"
    # Chunk (0,0) starts at block 0, so column c of the box is chunk c.
    z0=$(( BOX0 + row * 16 ))
    z1=$(( z0 + rows * 16 - 1 ))
    reply="$(python3 "$TOOLS/rcon.py" "$HOST" "$PORT" "$PW" \
             "forceload add $BOX0 $z0 $BOX1 $z1" 2>&1)"
    case "$reply" in
        *"Too many chunks"*|*"FAIL"*|"")
            echo "compare: FAIL forceload $BOX0 $z0 $BOX1 $z1 was refused: $reply"
            exit 1
            ;;
    esac
    echo "compare: forceload $BOX0 $z0 $BOX1 $z1 ($CHUNKS_ACROSS x $rows chunks) -> $reply"
    FORCELOADED=$((FORCELOADED + 1))
    row=$((row + rows))
done
echo "compare: force-loaded the sample area in $FORCELOADED strips of at most 256 chunks"

if [ ! -x "$ROOT/build/umbra_worldload" ] || [ "$ROOT/goose/worldload.goose" -nt "$ROOT/build/umbra_worldload" ]; then
    "$GOOSE" --standalone -o "$ROOT/build/worldload.c" "$ROOT/goose/worldload.goose" || exit 1
    ${CC:-cc} -O2 -o "$ROOT/build/umbra_worldload" "$ROOT/build/worldload.c" \
        "$ROOT/platform/shared/umbra_glue.c" -lm -lpthread || exit 1
fi

flush() {
    python3 "$TOOLS/rcon.py" "$HOST" "$PORT" "$PW" "save-all flush" || return 1
    sleep 3
}

# A world that is still generating keeps growing, and the growth is not smooth: chunks
# appear in bursts, so two reads in a row can agree in a lull and still be followed by
# hundreds more. Three consecutive readings that agree, with the region files' size and
# newest modification time unchanged as well, is the evidence that the ground has stopped
# moving. It takes about ten seconds and it goes into the log, so a run shows what it did.
fingerprint() {
    local totals bytes newest
    totals="$(grep -oE 'chunks [0-9]+, non-air blocks [0-9]+, states [0-9]+' \
        "$RUN/settle.log" | head -1)"
    bytes="$(find "$RUN/world" -name '*.mca' -printf '%s\n' 2>/dev/null \
        | awk '{s+=$1} END{print s+0}')"
    newest="$(find "$RUN/world" -name '*.mca' -printf '%T@\n' 2>/dev/null \
        | sort -n | tail -1)"
    echo "$totals|$bytes|$newest"
}

settled=0
prev=""
same=0
for attempt in 1 2 3 4 5 6; do
    if ! flush; then
        echo "compare: FAIL the server did not accept save-all flush"
        exit 1
    fi
    # `--incomplete-ok` because a save that is still being written has to be readable to
    # be measured; the loop below is what decides whether it is finished.
    "$ROOT/build/umbra_worldload" "$RUN/world" "$RUN/goose-settle.txt" "$RADIUS" \
        --incomplete-ok > "$RUN/settle.log" 2>&1
    now="$(fingerprint)"
    totals="${now%%|*}"
    if grep -q "chunks are not .minecraft:full. yet" "$RUN/settle.log"; then
        # The world is not finished, so it does not matter that it has stopped changing:
        # its carvers have not run and more blocks are still to come. Keep waiting.
        unfinished="$(grep -oE "[0-9]+ of [0-9]+ chunks are not" "$RUN/settle.log" | head -1)"
        echo "compare: attempt $attempt: ${totals:-no totals} - not finished (${unfinished:-?})"
        prev=""
        same=0
        sleep 5
        continue
    fi
    echo "compare: attempt $attempt: ${totals:-no totals}, every chunk finished"
    if [ "$now" = "$prev" ]; then
        same=$((same + 1))
        if [ "$same" -ge 2 ]; then
            settled=1
            echo "compare: the save is settled - three readings in a row agree: $totals"
            break
        fi
    else
        same=0
    fi
    prev="$now"
    sleep 3
done
if [ "$settled" = 0 ]; then
    echo "compare: FAIL the save never reached a state where every chunk was finished"
    echo "compare:      and had stopped changing, so a comparison would be against a"
    echo "compare:      world that is not the one that was read"
    grep "chunks are not" "$RUN/settle.log" 2>/dev/null | sed 's/^/compare: /'
    exit 1
fi

echo "== reading the save with Umbra's loader"
"$ROOT/build/umbra_worldload" "$RUN/world" "$RUN/goose-dump.txt" "$RADIUS" || exit 1
# The renderer later reads this same save at radius 6, and its `jr: save` line reports a
# chunk and block total for that window. Reading the window here too is what makes the two
# numbers mean the same thing. The earlier version compared the renderer's radius-6 total
# against the loader's *whole-save* total and read the 169-vs-529 difference as a reader
# bug; it was never the same question.
"$ROOT/build/umbra_worldload" "$RUN/world" "$RUN/goose-dump6.txt" 6 \
    | grep "^worldload: detail lines" | sed 's/^/compare: at radius 6 /'

grep -c '^detail ' "$RUN/goose-dump.txt" | sed 's/^/compare: detail lines for the grid: /'

echo "== asking the server about every claim"
python3 "$TOOLS/probe_server_blocks.py" "$HOST" "$PORT" "$PW" \
    "$RUN/goose-dump.txt" "$RUN/server-blocks.txt"
