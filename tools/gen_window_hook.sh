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

# Every reading is also written where it survives: evidence/ci/, which the job commits.
# The step's own stdout is not always readable afterwards through the API (run
# 44266341903 returned an empty body), and a hook that fails before its first reading
# leaves nothing to explain the failure -- which is exactly what happened when this file
# set up its log *after* building the reader, so a failed build exited silently.
mkdir -p "$ROOT/evidence/ci"
WLOG="$ROOT/evidence/ci/world-window.log"
: > "$WLOG"
say() { echo "window: $*" | tee -a "$WLOG"; }
trap 'rc=$?; [ "$rc" -ne 0 ] && say "FAIL the hook exited $rc"; cp "$WLOG" ./world-window.log 2>/dev/null || true' EXIT

say "hook: $ROOT/tools/gen_window_hook.sh, save directory $RUN, radius $RADIUS"

# rcon.py answers a malformed call by printing its usage and exiting non-zero. That is a bug
# in *this* file, not a fact about the server, and the first version of this file reported
# it as "the server did not accept save-all flush" -- a sentence about the wrong thing.
# Every reply is checked for the usage text before it is believed.
rcon_sane() {
    case "$1" in
        *"usage: tools/rcon.py"*)
            say "FAIL rcon.py was called wrongly, so this hook is broken: $(printf '%s' "$1" | head -1)"
            return 1
            ;;
    esac
    return 0
}

# The reader, built the same way tools/check_real_world.sh builds it.
if [ ! -x build/umbra_worldload ]; then
    say "building the world reader the gate uses"
    GOOSE_BIN="${GOOSE:-$ROOT/build/bin/goose}"
    # The android job builds the compiler with tools/pin_goose.sh, which leaves the stdlib
    # in build/goose-src/stdlib; a checkout that has it somewhere else can say so.
    STDLIB="${GOOSE_STDLIB:-}"
    if [ -z "$STDLIB" ]; then
        for d in "$ROOT/build/goose-src/stdlib" "$ROOT/stdlib"; do
            [ -d "$d" ] && STDLIB="$d" && break
        done
    fi
    say "reader build: goose ${GOOSE_BIN}, stdlib ${STDLIB:-<not found>}"
    GOOSE_STDLIB="$STDLIB" \
        "$GOOSE_BIN" --standalone -o build/worldload.c goose/worldload.goose > build/worldload-build.log 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        say "FAIL goose could not compile goose/worldload.goose (exit $rc)"
        tail -20 build/worldload-build.log 2>/dev/null | tee -a "$WLOG"
        exit 1
    fi
    ${CC:-cc} -O2 -o build/umbra_worldload build/worldload.c platform/shared/umbra_glue.c \
        -lm -lpthread >> build/worldload-build.log 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        say "FAIL the reader did not link (exit $rc)"
        tail -20 build/worldload-build.log 2>/dev/null | tee -a "$WLOG"
        exit 1
    fi
fi
if [ ! -x build/umbra_worldload ]; then
    say "FAIL there is no reader at build/umbra_worldload, so the save cannot be checked"
    exit 1
fi

flush() {
    # host, port, password, command -- the password is not optional, and the command is
    # unquoted because rcon.py joins its trailing arguments. The first version of this file
    # omitted the password, so rcon.py printed its usage and every flush "failed", which
    # read as a server that would not save.
    local reply
    # shellcheck disable=SC2086
    reply="$(python3 "$TOOLS/rcon.py" "$HOST" "$PORT" "$PW" save-all flush 2>&1)"
    rcon_sane "$reply" || return 1
    # A `rcon:` line is an error: unreachable, refused password, or a malformed call. Any of
    # those means the save was not flushed, and a hook that shrugged at "cannot reach" would
    # loop twelve times and then blame the world.
    case "$reply" in *"rcon: "*|*FAIL*|"") say "flush failed: $(printf '%s' "$reply" | head -1)"; return 1 ;; esac
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

# Generate the window first. This is the step the first version of this file left out,
# and leaving it out is why the block count was frozen at 101 105 for twelve attempts:
# flushing a save whose chunks have never been generated writes the same proto-chunks
# every time. A server that has just said "Preparing spawn area: 100%" has finished its
# *spawn* area and nothing else; chunks the phone will open but which nobody has walked
# into stay at the proto stage until something asks for them.
#
# `forceload add` is that ask, and it is exactly what tools/compare_with_server.sh does
# before its own settle loop. The server caps one call at 256 chunks, so the box goes in
# strips and every reply is read.
BOX0=$(( -RADIUS * 16 ))
BOX1=$(( RADIUS * 16 + 15 ))
ACROSS=$(( (BOX1 - BOX0 + 1) / 16 ))
STRIP=$(( 256 / ACROSS ))
[ "$STRIP" -lt 1 ] && STRIP=1
say "force-loading chunk -${RADIUS}..${RADIUS} (${ACROSS}x${ACROSS} chunks) so it is generated"
fl_load_ok=1
row=0
while [ "$row" -lt "$ACROSS" ]; do
    rows=$(( ACROSS - row ))
    [ "$rows" -gt "$STRIP" ] && rows="$STRIP"
    z0=$(( BOX0 + row * 16 ))
    z1=$(( z0 + rows * 16 - 1 ))
    # host, port, password, command -- the password is not optional, and the command is
    # unquoted because rcon.py joins its trailing arguments.
    # shellcheck disable=SC2086
    reply="$(python3 "$TOOLS/rcon.py" "$HOST" "$PORT" "$PW" forceload add $BOX0 $z0 $BOX1 $z1 2>&1)"
    rcon_sane "$reply" || { say "FAIL the forceload call is malformed; this is a bug in the hook"; exit 1; }
    case "$reply" in
        *"Too many chunks"*|*FAIL*|"")
            say "FAIL forceload $BOX0 $z0 $BOX1 $z1 was refused: $reply"
            fl_load_ok=0
            ;;
        *) say "forceload $BOX0 $z0 $BOX1 $z1 -> $reply" ;;
    esac
    row=$(( row + rows ))
done
[ "$fl_load_ok" = 1 ] || exit 1

say "settling the save at radius $RADIUS before it is handed to the phone"
say "reader: $ROOT/build/umbra_worldload, save: $RUN/world"
prev=""
same=0
ok=0
for attempt in $(seq 1 12); do
    if ! flush; then
        say "FAIL the server did not accept save-all flush"
        exit 1
    fi
    # --incomplete-ok because a save that is still being written has to be readable to be
    # measured; the loop is what decides whether it is finished.
    build/umbra_worldload "$RUN/world" "$RUN/settle.txt" "$RADIUS" --incomplete-ok \
        > "$RUN/settle.log" 2>&1
    # Where the reader looked, and what the archive it read was. Run 44274426747's log
    # showed "region dir .../dimensions/minecraft/overworld/region" for a server that had
    # written 81 proto-chunks: a save can hold more than one region directory, and the one
    # the reader picks decides whether it is reading terrain or generation bookkeeping.
    case "$attempt" in
        1|4|8|12)
            grep -E "^worldload: region dir|^worldload: chunks|^worldload: [0-9]+ of" "$RUN/settle.log" \
                2>/dev/null | sed 's/^/window:   /' | tee -a "$WLOG"
            ;;
    esac
    now="$(window)"
    un="$(unfinished)"
    if [ -n "$un" ] && ! printf '%s' "$un" | grep -q '(0 of them'; then
        say "attempt $attempt: ${now:-no window totals} - not finished ${un}"
        prev=""
        same=0
        sleep 4
        continue
    fi
    # No blocks in the window is not a window. This is the exact reading that went wrong
    # twice, and the reader can see it before the phone does.
    case "$now" in
        *"0 non-air blocks"*)
            say "attempt $attempt: ${now:-no totals} - the window still has no blocks"
            prev=""
            same=0
            sleep 4
            continue
            ;;
    esac
    if [ -z "$now" ]; then
        say "attempt $attempt: the reader printed no window totals; log tail:"
        tail -6 "$RUN/settle.log" 2>/dev/null | tee -a "$WLOG"
        sleep 4
        continue
    fi
    if [ "$now" = "$prev" ]; then
        same=$((same + 1))
    else
        same=0
    fi
    prev="$now"
    say "attempt $attempt: $now (stable readings: $same)"
    if [ "$same" -ge 2 ]; then
        ok=1
        break
    fi
    sleep 4
done

if [ "$ok" != 1 ]; then
    say "FAIL the window never settled at ${prev:-nothing}; the save would hold proto-chunks"
    tail -20 "$RUN/settle.log" 2>/dev/null | tee -a "$WLOG"
    exit 1
fi
say "PASS the window is finished and its block count is stable: $prev"
say "the save the phone gets is this one; the server stops next, which writes it"
# The reader's own account, next to the verdict.
cp "$RUN/settle.log" "$ROOT/evidence/ci/world-window-read.txt" 2>/dev/null || true
