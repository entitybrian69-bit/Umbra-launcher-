#!/usr/bin/env bash
# Build and run the PC headless self-test (Linux x64 natively, Windows x64 via
# mingw-w64 in CI).
set -euo pipefail
GOOSE="${GOOSE:-build/bin/goose}"
CC="${CC:-cc}"
OUT="${OUT:-build/pc/umbra_headless}"
EXTRA="${EXTRA:-}"
mkdir -p build/gen "$(dirname "$OUT")"
"$GOOSE" --standalone --header build/gen/umbra_core.h -o build/gen/umbra_core.c goose/main.goose
$CC -O2 -o "$OUT" platform/pc/headless_main.c build/gen/umbra_core.c -Ibuild/gen -Iplatform/shared \
    platform/shared/umbra_glue.c -lm -lpthread $EXTRA
echo "built $OUT"
"$OUT"
