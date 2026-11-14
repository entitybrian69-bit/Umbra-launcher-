#!/usr/bin/env bash
# Build the pinned Goose compiler (aardappel/goose) from source.
# The pin is the v2026.4 tag commit recorded in DECISIONS.md. Bump it there
# first if you change this.
set -euo pipefail
GOOSE_REPO="${GOOSE_REPO:-https://github.com/aardappel/goose}"
GOOSE_COMMIT="${GOOSE_COMMIT:-6c1fbc788f6eb1f17db4cab998353d7540ed825d}"
CACHE="${1:-build/goose-src}"
if [ ! -d "$CACHE/.git" ]; then
  rm -rf "$CACHE"
  git clone --quiet "$GOOSE_REPO" "$CACHE"
fi
git -C "$CACHE" fetch --quiet origin "$GOOSE_COMMIT" 2>/dev/null || true
git -C "$CACHE" checkout --quiet "$GOOSE_COMMIT"
echo "goose source: $CACHE at $(git -C "$CACHE" rev-parse HEAD)"
cmake -S "$CACHE" -B "$CACHE/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$CACHE/build" --config Release -j"$(nproc)" >/dev/null
mkdir -p build/bin
cp "$CACHE/build/goose" build/bin/goose
echo "built $(build/bin/goose --version 2>&1 | head -1)"
# The identity check from the brief: the Go/Notion tool of the same name has
# subcommands called providers and up. This one must not.
if build/bin/goose --help 2>&1 | grep -qiE 'providers|goose up|migrat'; then
  echo "ERROR: this is not aardappel/goose" >&2
  exit 1
fi
echo "identity check: this is aardappel/goose (no providers/up commands)"
