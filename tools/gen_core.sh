#!/usr/bin/env bash
# Generate the C for the Goose core into build/gen, for the Android/PC builds.
set -euo pipefail
GOOSE="${GOOSE:-build/bin/goose}"
ROOT="${ROOT:-.}"
if [ ! -x "$GOOSE" ]; then echo "no goose at $GOOSE (run tools/pin_goose.sh)" >&2; exit 1; fi
mkdir -p build/gen
"$GOOSE" --standalone --header build/gen/umbra_core.h -o build/gen/umbra_core.c "$ROOT/goose/main.goose"
echo "generated build/gen/umbra_core.c ($(wc -l < build/gen/umbra_core.c) lines of C from Goose)"
