#!/usr/bin/env bash
# The jar checker, tested against a synthetic jar: the good one must pass and the
# broken one must fail for the right reasons. No network and no game data, so
# this runs on every push; tools/fetch_jar.sh is what brings the real jar.
set -euo pipefail
GOOSE="${GOOSE:-build/bin/goose}"
OUT="${OUT:-build/umbra_jarcheck}"
mkdir -p build
python3 tools/gen_fake_jar.py build/fake-client.jar >/dev/null
python3 tools/gen_fake_jar.py build/fake-broken.jar --broken >/dev/null
GOOSE="$GOOSE" OUT="$OUT" bash -c 'true'   # keep the flags visible in the log
"$GOOSE" --standalone --header build/jarcheck.h -o build/jarcheck.c goose/jarcheck.goose
${CC:-cc} -O2 -o "$OUT" platform/shared/test_main.c build/jarcheck.c platform/shared/umbra_glue.c -lm -lpthread

echo "== a well-formed jar: must pass"
"$OUT" build/fake-client.jar | tee build/jar-good.txt

echo "== a jar with four deliberate breaks: must fail, and name them"
if "$OUT" build/fake-broken.jar > build/jar-broken.txt 2>&1; then
    echo "FAILED: the checker accepted a broken jar" >&2
    cat build/jar-broken.txt >&2
    exit 1
fi
cat build/jar-broken.txt
for want in \
    "a blockstate referencing a model that does not exist" \
    "a texture file that does not exist" \
    "a box with from > to on an axis" \
    "a texture variable that resolves nowhere"; do
    if ! grep -qF "$want" build/jar-broken.txt; then
        echo "FAILED: the broken jar did not report: $want" >&2
        exit 1
    fi
done
echo "PASS: the jar checker accepts a good jar and names every break in a broken one"
