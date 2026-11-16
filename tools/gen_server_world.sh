#!/usr/bin/env bash
# Run the real server once, let it generate the spawn area of a real world, then stop
# it and leave the save where the readers expect it.
#
# The world it writes is game data and never enters the repository: it lives under
# build/, is read by `goose/worldload.goose` and by `tools/world_oracle.py` inside the
# same run, and only their numbers are committed.
#
# usage: tools/gen_server_world.sh <server.jar> <run dir>
set -euo pipefail
JAR="${1:-build/server/server.jar}"
RUN="${2:-build/server/run}"
WAIT="${WORLD_WAIT:-600}"

rm -rf "$RUN"
mkdir -p "$RUN"
cd "$RUN"

echo "eula=true" > eula.txt
cat > server.properties <<'EOF'
level-seed=umbra
level-type=minecraft\:normal
online-mode=false
max-players=1
spawn-protection=0
view-distance=6
simulation-distance=4
enable-command-block=false
motd=umbra world
EOF

# The console has to be fed through a fifo: the server reads commands from stdin and
# exits on `stop`, and a `while` loop on the log is the only way to know it is ready.
mkfifo console
( java -Xmx1600M -jar "$JAR" nogui < console > server.log 2>&1; echo $? > exit.code ) &
SERVER=$!
exec 3> console

echo "waiting for the server to finish generating (up to ${WAIT}s)"
started=0
while [ "$started" -lt "$WAIT" ]; do
    if grep -q 'Done (' server.log 2>/dev/null; then
        started=1
        break
    fi
    if [ -s exit.code ]; then
        break
    fi
    sleep 2
    started=$((started + 2))
done

if [ "$started" = 0 ]; then
    echo "ERROR: the server did not finish starting; last lines of its log:" >&2
    tail -30 server.log >&2 || true
    echo stop >&3 2>/dev/null || true
    exit 1
fi

echo "generated; asking for a flush and a clean stop"
echo "save-all flush" >&3
sleep 5
echo stop >&3
exec 3>&-
wait "$SERVER" 2>/dev/null || true
sleep 2

tail -6 server.log
regions=$(ls world/region/*.mca 2>/dev/null | wc -l)
echo "region files written: $regions"
if [ "$regions" -lt 1 ]; then
    echo "ERROR: the server wrote no region files" >&2
    tail -40 server.log >&2 || true
    exit 1
fi
du -sh world | tail -1
