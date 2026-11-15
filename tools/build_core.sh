#!/usr/bin/env bash
# Build the Goose core to C and link it with the C platform layer.
# Usage: tools/build_core.sh <root.goose> <out.c> <out-header.h> <out-bin>
set -euo pipefail
ROOT="$1"; OUT_C="$2"; OUT_H="$3"; OUT_BIN="$4"
: "${GOOSE:?set GOOSE to the goose compiler binary}"
CC="${CC:-cc}"
mkdir -p "$(dirname "$OUT_C")" "$(dirname "$OUT_BIN")"
"$GOOSE" --standalone --header "$OUT_H" -o "$OUT_C" "$ROOT"
$CC -O2 -o "$OUT_BIN" platform/shared/test_main.c "$OUT_C" platform/shared/umbra_glue.c -lm -lpthread
echo "built $OUT_BIN"
