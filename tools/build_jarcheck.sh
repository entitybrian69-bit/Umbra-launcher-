#!/usr/bin/env bash
# Build the jar checker (Goose -> C -> native) and hand it the jar path.
# Usage: tools/build_jarcheck.sh <client.jar>
set -euo pipefail
GOOSE="${GOOSE:-build/bin/goose}"
JAR="${1:?usage: tools/build_jarcheck.sh <client.jar>}"
OUT="${OUT:-build/umbra_jarcheck}"
mkdir -p build
"$GOOSE" --standalone --header build/jarcheck.h -o build/jarcheck.c goose/jarcheck.goose
${CC:-cc} -O2 -o "$OUT" platform/shared/test_main.c build/jarcheck.c platform/shared/umbra_glue.c -lm -lpthread
echo "built $OUT"
"$OUT" "$JAR"
