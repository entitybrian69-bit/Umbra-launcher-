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
# The platform mains were not checked here until 0.3.1, and the JNI inset code
# that crashed the emulator lived in one of them. clang rejects an implicit
# function declaration in C99 mode and gcc only warns, so the warning is an
# error here: the local check now fails on exactly what the APK build fails on.
CFLAGS=(-std=gnu11 -fsyntax-only -Wall -Wextra -Wno-unused-parameter -Wno-sign-compare
        -Werror=implicit-function-declaration -Werror=incompatible-pointer-types)
echo "== desktop main"
$CC "${CFLAGS[@]}" -I"$INC" -I"$GEN" -Iplatform/shared "$@" platform/pc/headless_main.c
echo "== android main"
$CC "${CFLAGS[@]}" -D__ANDROID__ -I"$INC" -I"$GEN" -Iplatform/shared -Iplatform/android "$@" \
    platform/android/android_main.c
# Finding (a) of 0.3.1 was a shader that compiled, linked and drew the wrong
# thing: int is mediump (16 bits) by default in a fragment shader on Mali, so
# x * 255 overflowed and the self-test pattern matched only a 129x129 corner.
# The declared precision is now part of the contract, and it is checked here
# because no compiler on a desktop GL driver would ever complain about it.
if ! grep -A28 '^static const char .FS_PATTERN =' platform/shared/umbra_app.c 2>/dev/null \
        | grep -q 'precision highp int;';
then
    echo "check_c: FS_PATTERN no longer declares precision highp int (0.3.1 finding a)" >&2
    exit 1
fi
echo "check_c: FS_PATTERN declares precision highp int"
# Requirement (4): every device-specific check is logged, and a failure falls back.
# The device checks were written, reviewed and never called for two commits --
# nothing in a desktop build notices a missing call, so it is checked here.
if ! sed -n '/^int umbra_app_init/,/^}/p' platform/shared/umbra_app.c | grep -q 'device_checks(app);';
then
    echo "check_c: umbra_app_init never calls device_checks (it did not, in 0.3.2)" >&2
    exit 1
fi
echo "check_c: umbra_app_init runs the device checks"
# The platform fills in the game-files screen's hooks (and the directory the app's
# own jar lives in) *before* calling init, and init starts with a blanket memset.
# It erased all five, so the phone believed it had no download and no picker, and
# the screen the feature exists for never opened (emulator run 43946503664). No
# desktop build can notice that, so the save/restore pairs are checked here.
INIT_BODY="$(sed -n '/^int umbra_app_init/,/^}/p' platform/shared/umbra_app.c)"
BEFORE_MEMSET="$(printf '%s\n' "$INIT_BODY" | sed -n '1,/memset(app, 0, sizeof \*app);/p')"
AFTER_MEMSET="$(printf '%s\n' "$INIT_BODY" | sed -n '/memset(app, 0, sizeof \*app);/,$p')"
for field in files_dir download_fn pick_file_fn progress_fn net_ctx; do
    if ! printf '%s\n' "$BEFORE_MEMSET" | grep -q "app->$field"; then
        echo "check_c: umbra_app_init does not save app->$field before its memset" >&2
        exit 1
    fi
    if ! printf '%s\n' "$AFTER_MEMSET" | grep -qE "(app->$field =|memcpy\(app->$field,)"; then
        echo "check_c: umbra_app_init erases app->$field: it is not restored after the memset" >&2
        exit 1
    fi
done
echo "check_c: umbra_app_init keeps the platform's game-files hooks and files dir"
echo "check_c: both branches parse and type-check, and both platform mains do too"
