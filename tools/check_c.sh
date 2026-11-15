#!/usr/bin/env bash
# Compile-check the shared C (syntax and types, no link) without the NDK.
#
# The GLES3/EGL/KHR headers under tools/localcheck/include are the Khronos ones;
# the android/*.h files beside them are stubs holding only the few declarations
# umbra_app.c uses. This catches the mistakes that otherwise cost a ten-minute CI
# round trip; it is not a substitute for the real NDK build.
#
# Usage: tools/check_c.sh            # checks platform/shared/umbra_app.c
set -euo pipefail
CC="${CC:-cc}"
INC="tools/localcheck/include"
GEN="${GEN:-build/gen}"
if [ ! -f "$GEN/umbra_core.h" ]; then
    echo "no $GEN/umbra_core.h: run tools/gen_core.sh first" >&2
    exit 1
fi
# Both the Android and the desktop branches of the #ifdefs are checked: the app
# is compiled one way in the APK and the other way on PC.
echo "== desktop branch"
$CC -std=gnu11 -fsyntax-only -Wall -Wextra -Wno-unused-parameter -Wno-sign-compare \
    -I"$INC" -I"$GEN" -Iplatform/shared "$@" platform/shared/umbra_app.c
echo "== android branch"
$CC -std=gnu11 -fsyntax-only -Wall -Wextra -Wno-unused-parameter -Wno-sign-compare \
    -D__ANDROID__ -I"$INC" -I"$GEN" -Iplatform/shared "$@" platform/shared/umbra_app.c
echo "check_c: both branches parse and type-check"
