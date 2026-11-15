#!/usr/bin/env bash
# The model parser, driven over a whole jar: the smoke test runs on the synthetic
# jar (no network, no game data), and the jar workflow runs the same binary over the
# real client jar.
set -euo pipefail
GOOSE="${GOOSE:-build/bin/goose}"
OUT="${OUT:-build/umbra_modelcheck}"
mkdir -p build
python3 tools/gen_fake_jar.py build/fake-client.jar >/dev/null
"$GOOSE" --standalone -o build/modelcheck.c goose/modelcheck.goose
${CC:-cc} -O2 -o "$OUT" build/modelcheck.c platform/shared/umbra_glue.c -lm -lpthread
echo "== a well-formed jar: every model must parse"
"$OUT" build/fake-client.jar "${MIN_MODELS:-1}" | tee build/models-good.txt
grep -qF "PASS: every block model in the jar parses" build/models-good.txt
echo "PASS: the model parser accepts every model in the jar"
