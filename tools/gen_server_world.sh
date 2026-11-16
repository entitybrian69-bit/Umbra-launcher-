#!/usr/bin/env bash
# Run the real server once, let it generate the spawn area of a real world, then ask it
# to stop and leave the save where the readers expect it.
#
# The world it writes is game data and never enters the repository: it lives under
# build/, is read by `goose/worldload.goose` and by `tools/world_oracle.py` inside the
# same run, and only their numbers are committed.
#
# Stopping: the server saves the world in its shutdown hook, so SIGTERM is enough and a
# console fifo is not: the first attempt at this wired a fifo into stdin and the write
# broke because the server was already gone, which told us nothing about the world.
#
# usage: tools/gen_server_world.sh <server.jar> <run dir>
set -uo pipefail
# Absolute paths, because the script changes directory into the run dir and a relative
# jar path would then point at nothing: the first version of this did exactly that and
# java exited at once with "Unable to access jarfile", which is not a fact about the
# world.
JAR="$(realpath "${1:-build/server/server.jar}")"
RUN="$(realpath -m "${2:-build/server/run}")"
WAIT="${WORLD_WAIT:-600}"

tidy() {
    if [ -f "$RUN/server.log" ]; then
        echo "== last lines of the server's log"
        tail -40 "$RUN/server.log"
    fi
}

rm -rf "$RUN"
mkdir -p "$RUN"
cd "$RUN"

echo "eula=true" > eula.txt
cat > server.properties <<'EOF'
level-seed=umbra
online-mode=false
max-players=1
spawn-protection=0
view-distance=6
simulation-distance=4
enable-command-block=false
motd=umbra world
EOF

[ -f "$JAR" ] || { echo "ERROR: no server jar at $JAR"; exit 1; }
java -Xmx1600M -jar "$JAR" nogui < /dev/null > server.log 2>&1 &
PID=$!
echo "server pid $PID, waiting up to ${WAIT}s for it to finish generating"

waited=0
ready=0
while [ "$waited" -lt "$WAIT" ]; do
    if ! kill -0 "$PID" 2>/dev/null; then
        echo "ERROR: the server exited before it said it was done"
        tidy
        exit 1
    fi
    if grep -q 'Done (' server.log 2>/dev/null; then
        ready=1
        break
    fi
    sleep 2
    waited=$((waited + 2))
done

if [ "$ready" = 0 ]; then
    echo "ERROR: the server did not finish starting in ${WAIT}s"
    kill -TERM "$PID" 2>/dev/null || true
    tidy
    exit 1
fi

echo "world generated after ${waited}s; stopping the server so it saves"
kill -TERM "$PID" 2>/dev/null || true
for i in $(seq 1 60); do
    kill -0 "$PID" 2>/dev/null || break
    sleep 1
done
kill -KILL "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null
status=$?
echo "server exit status $status"

tidy
regions=$(ls world/region/*.mca 2>/dev/null | wc -l)
echo "region files written: $regions"
if [ "$regions" -lt 1 ]; then
    echo "ERROR: the server wrote no region files"
    find . -maxdepth 2 -name '*.mca' -o -maxdepth 2 -name 'level.dat' | head
    exit 1
fi
du -sh world | tail -1
echo "PASS: the real server generated a world with $regions region file(s)"
