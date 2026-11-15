#pragma once
// Pure HUD arithmetic: where the overlay goes, how big it is, and where the 3D
// scene is drawn so it is not hidden behind it.
//
// Nothing here touches GL, JNI or the platform layer, so `platform/pc/headless_main.c`
// compiles the same functions and checks them on the desktop -- including cases
// the emulator cannot produce (a 63 px status bar, a display cutout, a 2412x1080
// phone at density 3.5). Run 43696083945 could not catch the status-bar overlap
// because the emulator reports a top inset of zero; this file is how that becomes
// a tested case instead of a hope.

#include <stdint.h>
#include <stddef.h>

typedef struct {
    float x, y, w, h;
} umbra_rect;

// The font is an 8-pixel bitmap. Text at scale 1 on a 420 dpi phone is about
// three density-independent pixels tall, which nobody can read, so the overlay is
// scaled with the display density -- and then shrunk again if the block would eat
// more than UMBRA_HUD_MAX_FRACTION of the screen, because on a 2412x1080 phone at
// density 3.5 the first attempt covered the whole world.
#define UMBRA_HUD_MAX_FRACTION 0.45f
#define UMBRA_HUD_ROW_HEIGHT 12.0f

static float umbra_hud_scale(float dpi_scale, int width, int height, int rows, int32_t top_inset) {
    float s = (dpi_scale > 1.0f) ? dpi_scale * 1.2f : 1.0f;
    if (s < 1.0f) s = 1.0f;
    if (s > 5.0f) s = 5.0f;
    if (width < 16 || height < 16 || rows <= 0) return s;
    // Shrink until the block fits, never below the readability floor. The status
    // bar is part of the block: on the owner's phone 63 px of it plus a full-size
    // overlay took half the screen.
    float budget = (float)height * UMBRA_HUD_MAX_FRACTION - (float)(top_inset > 0 ? top_inset : 0);
    if (budget < 32.0f) budget = 32.0f;
    float block = (float)rows * UMBRA_HUD_ROW_HEIGHT * s + 16.0f * s;
    if (block > budget) {
        s = budget / ((float)rows * UMBRA_HUD_ROW_HEIGHT + 16.0f);
    }
    if (s < 2.0f && dpi_scale > 1.6f) s = 2.0f;
    return s;
}

// How tall the backdrop is, given how many rows the overlay will draw. The top
// inset is part of it: with the status bar drawn over the app the panel must start
// below the clock, not behind it.
static float umbra_hud_panel_height(int rows, float scale, int32_t top_inset) {
    if (rows < 1) rows = 1;
    return (float)top_inset + (float)rows * UMBRA_HUD_ROW_HEIGHT * scale + 16.0f * scale;
}

// Where the 3D view should be centred in normalised device coordinates: the panel
// covers the top of the screen, so the scene moves down by half the covered
// fraction. Returns 0 when there is no panel worth compensating for.
static float umbra_hud_scene_shift(float panel_height, int height) {
    if (height < 16 || panel_height <= 0.0f) return 0.0f;
    float covered = panel_height / (float)height;
    if (covered < 0.05f) return 0.0f;
    if (covered > 0.6f) covered = 0.6f;
    return -covered;   // negative: NDC y grows upward, the panel is above
}

// One of the three buttons, in pixels, inside all four insets. The drawing code
// and the touch test both call this, so they cannot disagree -- and a phone with a
// 126 px navigation bar on the right and a 63 px status bar at the top gets
// buttons that are inside both.
static umbra_rect umbra_hud_button(int i, int width, int height, const int32_t insets[4],
                                   float scale) {
    umbra_rect r = {0, 0, 0, 0};
    if (width < 16 || height < 16 || i < 0 || i > 2) return r;
    float bh = 20.0f * scale;
    float gap = 6.0f * scale;
    float margin = 8.0f * scale;
    r.h = bh;
    r.x = margin + (float)insets[0];
    r.w = (float)width - r.x - (float)insets[2] - margin;
    if (r.w < 0.0f) r.w = 0.0f;
    float bottom = (float)height - (float)insets[3];
    r.y = bottom - 3.0f * (bh + gap) - margin + (float)i * (bh + gap) + gap * 0.5f;
    if (r.y < (float)insets[1]) r.y = (float)insets[1];
    return r;
}

// Copy src into dst, turning newlines into spaces and stopping before cap; returns
// the number of bytes written (excluding the terminator). Used to store the
// multi-line benchmark block on one line of a one-line-per-result file.
static int umbra_flatten(char *dst, size_t cap, const char *src) {
    if (!dst || cap == 0) return 0;
    size_t n = 0;
    for (const char *p = src; p && *p && n + 1 < cap; p++) {
        char c = (*p == '\n' || *p == '\r' || *p == '\t') ? ' ' : *p;
        dst[n++] = c;
    }
    dst[n] = 0;
    return (int)n;
}
