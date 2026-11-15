// The self-test's arithmetic that is worth testing without a GPU: how much of a
// readback one frame may handle, and exactly which pixels a comparison covers.
//
// Why this exists: the first self-test did two full-screen readbacks and five
// million pixel comparisons inside one frame, which is long enough for Android to
// decide the app has stopped responding -- and the owner's phone logged
// "SELF-TEST: BEGIN (2292x1080)" and then nothing, reported as a crash. It also
// compared the window when the offscreen target was unavailable, which means it
// compared its own overlay. Both are arithmetic problems before they are GL
// problems, so both live here where the host suite can check them.
#ifndef UMBRA_SELFTEST_H
#define UMBRA_SELFTEST_H

#include <stdint.h>
#include "umbra_hud.h"

// One step reads and compares about this many pixels: 150k is under 2 ms of
// comparison on a phone and under a megabyte of readback, so a frame that hosts a
// step still draws and still polls input.
#define UMBRA_SELFTEST_TILE_PIXELS 150000

// How many rows of a width x height readback one step handles, at least one and
// never more than the whole image.
static int umbra_selftest_tile_rows(int width, int height) {
    if (width < 1 || height < 1) return 1;
    int rows = UMBRA_SELFTEST_TILE_PIXELS / width;
    if (rows < 8) rows = 8;          // a very wide screen still advances
    if (rows > height) rows = height;
    return rows;
}

// Does the comparison cover this pixel? It does not when the overlay is drawn on
// top of it: in the fallback path the test reads the window, and the overlay is
// part of the window. `skipped` is incremented for those pixels so the log can say
// how many were left out and why.
static int umbra_selftest_compares(int x, int y, int hud_rows, float hud_scale,
                                   const int32_t insets[4], int width, int height,
                                   int64_t *skipped) {
    if (umbra_hud_covers(x, y, hud_rows, hud_scale, insets, width, height)) {
        if (skipped) (*skipped)++;
        return 0;
    }
    return 1;
}

// The number of pixels a window readback would compare, and the number it would
// skip, without touching a framebuffer. Used by the host suite to prove that no
// overlay pixel is inside the compared area.
static int64_t umbra_selftest_compared_area(int hud_rows, float hud_scale,
                                            const int32_t insets[4], int width, int height,
                                            int64_t *skipped) {
    int64_t compared = 0;
    int64_t skipped_local = 0;
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            if (umbra_hud_covers(x, y, hud_rows, hud_scale, insets, width, height)) {
                skipped_local++;
            } else {
                compared++;
            }
        }
    }
    if (skipped) *skipped = skipped_local;
    return compared;
}

#endif
