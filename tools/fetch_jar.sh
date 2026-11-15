#!/usr/bin/env bash
# Download the official client jar for one pinned version, verify it against the
# manifest, and report what was obtained.
#
# The jar itself is NEVER committed: only the version, its sha1, its size and the
# checker's output are (under evidence/jar/). This script runs in CI, where the
# network reaches Mojang; the sandbox that writes the code does not.
#
# usage: tools/fetch_jar.sh [destination.jar]
#   MC_VERSION  the version to pin (default: the one in DECISIONS.md, D-023)
set -euo pipefail
MC_VERSION="${MC_VERSION:-26.3}"
DEST="${1:-build/jar/client.jar}"
WORK="$(dirname "$DEST")"
mkdir -p "$WORK"

MANIFEST_URL="https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
echo "manifest: $MANIFEST_URL"
curl -fsSL --retry 3 --retry-delay 2 -o "$WORK/version_manifest_v2.json" "$MANIFEST_URL"
python3 tools/pin_version.py "$WORK/version_manifest_v2.json" "$MC_VERSION" > "$WORK/pin.env"
# shellcheck disable=SC1091
. "$WORK/pin.env"
echo "version: $MC_VERSION_ID ($MC_VERSION_TYPE, released $MC_VERSION_TIME)"

# The manifest entry's sha1 covers the version JSON. The client jar has its own
# identity inside that JSON, under downloads.client: fetch the JSON first, check
# it, and only then ask it where the jar is.
curl -fsSL --retry 3 --retry-delay 2 -o "$WORK/version.json" "$MC_VERSION_URL"
JSON_SHA1=$(sha1sum "$WORK/version.json" | cut -d' ' -f1)
if [ "$JSON_SHA1" != "$MC_VERSION_SHA1" ]; then
    echo "ERROR: version JSON sha1 mismatch: manifest says $MC_VERSION_SHA1, got $JSON_SHA1" >&2
    exit 1
fi
python3 tools/pin_client.py "$WORK/version.json" > "$WORK/client.env"
# shellcheck disable=SC1091
. "$WORK/client.env"
echo "client jar in the version JSON: $MC_CLIENT_SIZE bytes, sha1 $MC_CLIENT_SHA1"

echo "downloading: $MC_CLIENT_URL"
curl -fsSL --retry 3 --retry-delay 2 -o "$DEST" "$MC_CLIENT_URL"
SIZE=$(wc -c < "$DEST")
GOT=$(sha1sum "$DEST" | cut -d' ' -f1)
echo "client jar: $SIZE bytes, sha1 $GOT"
if [ "$GOT" != "$MC_CLIENT_SHA1" ]; then
    echo "ERROR: client jar sha1 mismatch: the version JSON says $MC_CLIENT_SHA1" >&2
    exit 1
fi
if [ "$SIZE" != "$MC_CLIENT_SIZE" ]; then
    echo "ERROR: client jar size mismatch: the version JSON says $MC_CLIENT_SIZE" >&2
    exit 1
fi
mkdir -p evidence/jar
{
    echo "version: $MC_VERSION_ID"
    echo "type: $MC_VERSION_TYPE"
    echo "released: $MC_VERSION_TIME"
    echo "client jar: $SIZE bytes"
    echo "sha1: $GOT"
    echo "version json sha1: $JSON_SHA1"
    echo "asset index: $MC_ASSET_INDEX"
    echo "java: $MC_JAVA"
    echo "verified against: $MANIFEST_URL"
    echo "downloaded by: tools/fetch_jar.sh (the jar is not committed)"
} > evidence/jar/pin.txt
cat evidence/jar/pin.txt
