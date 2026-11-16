#!/usr/bin/env bash
# Download the official *server* jar for the pinned version, verify it against the
# version JSON, and leave it in build/server/server.jar.
#
# The jar itself is never committed and never published: it exists only inside the CI
# run that generates a world with it. Only what the readers made of that world (counts,
# hashes, match rates) is committed.
#
# usage: tools/fetch_server.sh [destination.jar]
#   MC_VERSION  the version to pin (default: the one in DECISIONS.md, D-023)
set -euo pipefail
MC_VERSION="${MC_VERSION:-26.3}"
DEST="${1:-build/server/server.jar}"
WORK="$(dirname "$DEST")"
mkdir -p "$WORK"

MANIFEST_URL="https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
curl -fsSL --retry 3 --retry-delay 2 -o "$WORK/version_manifest_v2.json" "$MANIFEST_URL"
python3 tools/pin_version.py "$WORK/version_manifest_v2.json" "$MC_VERSION" > "$WORK/pin.env"
# shellcheck disable=SC1091
. "$WORK/pin.env"
echo "version: $MC_VERSION_ID ($MC_VERSION_TYPE, released $MC_VERSION_TIME)"

curl -fsSL --retry 3 --retry-delay 2 -o "$WORK/version.json" "$MC_VERSION_URL"
JSON_SHA1=$(sha1sum "$WORK/version.json" | cut -d' ' -f1)
if [ "$JSON_SHA1" != "$MC_VERSION_SHA1" ]; then
    echo "ERROR: version JSON sha1 mismatch: manifest says $MC_VERSION_SHA1, got $JSON_SHA1" >&2
    exit 1
fi
python3 tools/pin_server.py "$WORK/version.json" > "$WORK/server.env"
# shellcheck disable=SC1091
. "$WORK/server.env"
echo "server jar in the version JSON: $MC_SERVER_SIZE bytes, sha1 $MC_SERVER_SHA1"
echo "server needed Java $MC_SERVER_JAVA"
# Persisted, because the runner has to install that version and the hard-coded 21 in the
# workflow was wrong: 26.3's bundler is class file version 69 (Java 25), so the server
# died on the first line with UnsupportedClassVersionError and the log said only that it
# had exited. The version JSON knows; this file carries it to the setup step.
mkdir -p "$(dirname "$DEST")"
printf '%s\n' "$MC_SERVER_JAVA" > "$(dirname "$DEST")/java_major.txt"

echo "downloading: $MC_SERVER_URL"
curl -fsSL --retry 3 --retry-delay 2 -o "$DEST" "$MC_SERVER_URL"
GOT_SHA1=$(sha1sum "$DEST" | cut -d' ' -f1)
GOT_SIZE=$(wc -c < "$DEST")
if [ "$GOT_SHA1" != "$MC_SERVER_SHA1" ]; then
    echo "ERROR: server jar sha1 mismatch: expected $MC_SERVER_SHA1, got $GOT_SHA1" >&2
    exit 1
fi
if [ "$GOT_SIZE" != "$MC_SERVER_SIZE" ]; then
    echo "ERROR: server jar size mismatch: expected $MC_SERVER_SIZE, got $GOT_SIZE" >&2
    exit 1
fi
echo "PASS: server $MC_VERSION_ID downloaded and verified ($GOT_SIZE bytes, sha1 $GOT_SHA1)"
