#!/usr/bin/env bash
# Draw the demo world with the jar's own models and textures, on the CPU, and write
# the picture the CI gate compares against its reference.
#
# The jar is never committed and never published: it is whatever `tools/fetch_jar.sh`
# downloaded into build/jar at test time. The picture that comes out of this is
# evidence/jar/world.png, which CI commits so the next run has a reference to compare
# with.
#
# usage: tools/render_world.sh [jar] [out.ppm] [width] [height] [out.png] [save dir] [radius]
#
# With a save directory the picture is of *that world*, loaded the way the game's own
# chunks are, drawn with the same models and textures. That is the check that matters:
# a world nobody generated to suit the renderer, every block of it drawn from the jar.
set -euo pipefail
JAR="${1:-build/jar/client.jar}"
PPM="${2:-build/world.ppm}"
PNG="${5:-${PPM%.ppm}.png}"
SAVE="${6:-}"
RADIUS="${7:-0}"
W="${3:-960}"
H="${4:-540}"
GOOSE="${GOOSE:-build/bin/goose}"
export GOOSE_STDLIB="${GOOSE_STDLIB:-build/goose-src/stdlib}"
mkdir -p build evidence/jar

"$GOOSE" --standalone -o build/jrender.c goose/jrender.goose
${CC:-cc} -O2 -o build/umbra_jrender build/jrender.c platform/shared/umbra_glue.c -lm -lpthread

if [ -n "$SAVE" ]; then
    echo "== drawing the world in ${SAVE} with ${JAR}"
    build/umbra_jrender "$JAR" "$PPM" "$W" "$H" "$SAVE" "$RADIUS" | tee build/render-world.txt
else
    echo "== drawing the demo world with ${JAR}"
    build/umbra_jrender "$JAR" "$PPM" "$W" "$H" | tee build/render-world.txt
fi
grep -qF "jr: PASS - a world drawn with the jar's own models and textures" build/render-world.txt \
  || { echo "FAIL: the renderer did not say it drew the world" >&2; exit 1; }

mkdir -p "$(dirname "$PNG")"
python3 tools/ppm2png.py "$PPM" "$PNG"
echo "== picture: $PNG ($(wc -c < "$PNG") bytes)"
