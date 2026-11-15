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
# The generator is left to CMake unless the caller names one (MSYS2 needs
# Ninja, because there is no "make" on a bare Windows runner).
GEN_ARGS=()
if [ -n "${GOOSE_CMAKE_GENERATOR:-}" ]; then GEN_ARGS=(-G "$GOOSE_CMAKE_GENERATOR"); fi
cmake -S "$CACHE" -B "$CACHE/build" -DCMAKE_BUILD_TYPE=Release "${GEN_ARGS[@]}" >/dev/null
cmake --build "$CACHE/build" --config Release -j"$(nproc 2>/dev/null || echo 4)" >/dev/null
mkdir -p build/bin
# Windows builds produce goose.exe; keep the name the platform expects.
GOOSE_BIN="$CACHE/build/goose"
[ -f "$GOOSE_BIN" ] || GOOSE_BIN="$CACHE/build/goose.exe"
cp "$GOOSE_BIN" "build/bin/$(basename "$GOOSE_BIN")"
echo "built $(build/bin/$(basename "$GOOSE_BIN") --version 2>&1 | head -1)"
# The identity check from the brief: the Go/Notion tool of the same name has
# subcommands called providers and up. This one must not.
if "build/bin/$(basename "$GOOSE_BIN")" --help 2>&1 | grep -qiE 'providers|goose up|migrat'; then
  echo "ERROR: this is not aardappel/goose" >&2
  exit 1
fi
echo "identity check: this is aardappel/goose (no providers/up commands)"
