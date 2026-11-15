#!/usr/bin/env bash
# Build the Goose core test program (Goose -> C -> native) and run it.
set -euo pipefail
GOOSE="${GOOSE:-build/bin/goose}"
if [ ! -x "$GOOSE" ]; then echo "no goose at $GOOSE; run tools/pin_goose.sh" >&2; exit 1; fi
GOOSE="$GOOSE" tools/build_core.sh goose/tests.goose build/tests.c build/tests.h build/umbra_tests
./build/umbra_tests
