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
    // A readability floor, but a low one: refusing to shrink means text on bare
    // sky, which is worse than small text.
    if (s < 1.6f && dpi_scale > 1.6f) s = 1.6f;
    return s;
}

// How many rows the overlay draws: the title, four facts, the mesh line, the
// camera line and the self-test line, then the benchmark block, a blank, the
// last-run block, a blank, and the crash tail. One function, called by the drawing
// code and by the tests, because the first version counted whole rows and forgot
// that the title is spaced at 1.6 -- which put the crash tail on bare sky.
#define UMBRA_HUD_TITLE_ROWS 1.6f
static float umbra_hud_rows(int bench_lines, int last_run_lines, int crashed) {
    float rows = UMBRA_HUD_TITLE_ROWS + 4.0f + 1.0f + 1.0f + 1.0f;
    rows += (float)(bench_lines > 0 ? bench_lines : 0);
    rows += 1.0f;
    rows += (float)(last_run_lines > 0 ? last_run_lines : 0);
    rows += 1.0f;
    if (crashed) rows += 3.0f;
    return rows;
}

// How tall the backdrop is, given how many rows the overlay will draw. The top
// inset is part of it: with the status bar drawn over the app the panel must start
// below the clock, not behind it.
static float umbra_hud_panel_height(int rows, float scale, int32_t top_inset) {
    if (rows < 1) rows = 1;
    return (float)top_inset + (float)rows * UMBRA_HUD_ROW_HEIGHT * scale + 16.0f * scale;
}

// A landscape surface puts the three buttons in a row, a portrait one stacks
// them. Three stacked buttons on a 1080-pixel-high phone took 250 of them out of
// the band the world is drawn in, and the world ended up a thumbnail between two
// walls of interface.
static int umbra_hud_is_wide(int width, int height) {
    return height > 0 && (float)width / (float)height > 1.5f;
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
    float bottom = (float)height - (float)insets[3];
    r.h = bh;
    if (umbra_hud_is_wide(width, height)) {
        float left = margin + (float)insets[0];
        float usable = (float)width - left - (float)insets[2] - margin;
        float slot = (usable - 2.0f * gap) / 3.0f;
        if (slot < 1.0f) slot = 1.0f;
        r.x = left + (float)i * (slot + gap);
        r.w = slot;
        r.y = bottom - margin - bh;
        if (r.y < (float)insets[1]) r.y = (float)insets[1];
        return r;
    }
    r.x = margin + (float)insets[0];
    r.w = (float)width - r.x - (float)insets[2] - margin;
    if (r.w < 0.0f) r.w = 0.0f;
    r.y = bottom - 3.0f * (bh + gap) - margin + (float)i * (bh + gap) + gap * 0.5f;
    if (r.y < (float)insets[1]) r.y = (float)insets[1];
    return r;
}

// The strip of screen the world is actually visible in: below the overlay, above
// the buttons. Both the camera fit and the scene shift use it, so "framed" means
// framed in what is left rather than in the full screen.
static void umbra_hud_scene_band(int rows, float scale, const int32_t insets[4], int width,
                                 int height, float *top, float *bottom) {
    float t = umbra_hud_panel_height(rows, scale, insets[1]) + 4.0f * scale;
    umbra_rect b0 = umbra_hud_button(0, width, height, insets, scale);
    float b = b0.y - 4.0f * scale;
    if (b <= t + 8.0f) {
        // No room between the two: split what there is, so the world still has a
        // centre to be aimed at instead of collapsing to a point.
        float mid = (float)height * 0.5f;
        t = mid - (float)height * 0.15f;
        b = mid + (float)height * 0.15f;
    }
    if (t < 0.0f) t = 0.0f;
    if (b > (float)height) b = (float)height;
    *top = t;
    *bottom = b;
}

// Where the 3D view should be centred, in normalised device coordinates: the
// middle of the band above, moved to the middle of the screen. Negative moves the
// world down, because NDC y grows upward and the band sits below the panel.
static float umbra_hud_band_shift(float band_top, float band_bottom, int height) {
    if (height < 16 || band_bottom <= band_top) return 0.0f;
    float centre = (band_top + band_bottom) * 0.5f;
    float shift = (centre - (float)height * 0.5f) * 2.0f / (float)height;
    if (shift > 0.6f) shift = 0.6f;
    if (shift < -0.6f) shift = -0.6f;
    return -shift;
}

// Kept for the overlay's own backdrop maths: how much of the screen the panel
// covers, as a fraction, clamped.
static float umbra_hud_scene_shift(float panel_height, int height) {
    if (height < 16 || panel_height <= 0.0f) return 0.0f;
    float covered = panel_height / (float)height;
    if (covered < 0.05f) return 0.0f;
    if (covered > 0.6f) covered = 0.6f;
    return -covered;
}

// The hotbar: five square slots at the bottom of the screen, centred, above the
// navigation inset. The selected one is drawn larger and brighter. Its arithmetic is
// here so the taps and the pixels cannot disagree: the emulator taps the same rect the
// app drew, and the host suite checks a phone, a tablet and a landscape window.
#define UMBRA_HOTBAR_SLOTS 5

// The hand controls are tapped, so their size comes from a finger and not from the
// overlay text, which has to shrink to fit its rows: on the CI emulator that shrink left
// a hotbar slot 23 px across, which is not a target anybody can hit. A slot is 44 dp
// across (the smallest edge a person can reliably tap) unless that would take most of the
// screen's short side, in which case the row is shrunk to fit.
static float umbra_hud_hand_scale(float dpi_scale, int width, int height) {
    float dp = (dpi_scale > 1.0f) ? dpi_scale : 1.0f;
    float row = UMBRA_HOTBAR_SLOTS * 14.0f + (UMBRA_HOTBAR_SLOTS - 1) * 3.0f;
    float s = 44.0f * dp / 14.0f;
    float limit = (float)(width < height ? width : height) * 0.72f;
    if (row * s > limit) s = limit / row;
    if (s < 1.0f) s = 1.0f;
    return s;
}

static umbra_rect umbra_hud_hotbar_slot(int i, int width, int height, const int32_t insets[4],
                                        float scale) {
    umbra_rect r = { 0, 0, 0, 0 };
    if (i < 0 || i >= UMBRA_HOTBAR_SLOTS) return r;
    float size = 14.0f * scale;
    float gap = 3.0f * scale;
    float total = UMBRA_HOTBAR_SLOTS * size + (UMBRA_HOTBAR_SLOTS - 1) * gap;
    float x0 = ((float)width - total) * 0.5f;
    float y0 = (float)height - (float)insets[3] - size - 8.0f * scale;
    if (x0 < 4.0f) x0 = 4.0f;
    r.x = x0 + (float)i * (size + gap);
    r.y = y0;
    r.w = size;
    r.h = size;
    return r;
}

static int umbra_hud_hotbar_hit(int x, int y, int width, int height, const int32_t insets[4],
                                float scale) {
    // A finger is not a pixel: grow each slot by a few pixels so a tap that lands on the
    // gap still selects the slot next to it, and never returns -1 for a near miss.
    float pad = 4.0f * scale;
    for (int i = 0; i < UMBRA_HOTBAR_SLOTS; i++) {
        umbra_rect r = umbra_hud_hotbar_slot(i, width, height, insets, scale);
        if ((float)x >= r.x - pad && (float)x <= r.x + r.w + pad &&
            (float)y >= r.y - pad && (float)y <= r.y + r.h + pad) {
            return i;
        }
    }
    return -1;
}

// Two action buttons above the hotbar, on the right: break and place. They are buttons
// rather than gestures on the world because one finger already means look, walk and
// jump, and a fourth meaning would be a mode nobody can see.
static umbra_rect umbra_hud_action(int which, int width, int height, const int32_t insets[4],
                                   float scale) {
    umbra_rect r = { 0, 0, 0, 0 };
    if (which < 0 || which > 1) return r;
    float w = 34.0f * scale;
    if (w > (float)width * 0.45f) w = (float)width * 0.45f;
    float h = 16.0f * scale;
    float gap = 3.0f * scale;
    float x1 = (float)width - (float)insets[2] - 8.0f * scale;
    // Above the hotbar row, not on it: at 44 dp a slot the two would otherwise overlap on
    // a 1080-wide screen, and an overlap is a tap that means two things.
    float row_top = (float)height - (float)insets[3] - 14.0f * scale - 8.0f * scale;
    float y0 = row_top - 6.0f * scale - 2.0f * (h + gap);
    r.x = x1 - w;
    r.y = y0 + (float)which * (h + gap);
    r.w = w;
    r.h = h;
    if (r.x < 4.0f) r.x = 4.0f;
    return r;
}

static int umbra_hud_action_hit(int x, int y, int width, int height, const int32_t insets[4],
                                float scale) {
    for (int i = 0; i < 2; i++) {
        umbra_rect r = umbra_hud_action(i, width, height, insets, scale);
        if ((float)(x + 1) > r.x && (float)x < r.x + r.w &&
            (float)(y + 1) > r.y && (float)y < r.y + r.h) {
            return i;
        }
    }
    return -1;
}

// Is this pixel inside something the overlay draws -- its backdrop panel or one
// of its buttons? The self-test compares the window when it cannot have an
// offscreen target, and the overlay is part of that window; a comparison that
// includes it fails on the app's own interface, which is what a phone screenshot
// of "2458665 bad" could have been. This is the predicate the comparison uses and
// the host suite checks.
static int umbra_hud_covers(int x, int y, int rows, float scale, const int32_t insets[4],
                            int width, int height) {
    if (width < 16 || height < 16 || x < 0 || y < 0 || x >= width || y >= height) return 0;
    float panel = umbra_hud_panel_height(rows, scale, insets[1]);
    if ((float)y < panel) return 1;                 // the backdrop spans the full width
    for (int i = 0; i < 3; i++) {
        // Overlap, not containment: a button whose edge falls at x = 775.3 covers
        // part of pixel 775, and a comparison that kept that pixel would be
        // comparing the interface. A pixel counts as covered if any of it is.
        umbra_rect r = umbra_hud_button(i, width, height, insets, scale);
        if ((float)(x + 1) > r.x && (float)x < r.x + r.w &&
            (float)(y + 1) > r.y && (float)y < r.y + r.h) {
            return 1;
        }
    }
    return 0;
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

// --- the "get game files" screen ----------------------------------------
//
// A phone has no way to receive a file the way the CI harness pushes one to
// /data/local/tmp, so the app grows a screen that asks for it: download the pinned
// client jar from Mojang, or import a jar the owner already has. The layout is
// here, with the rest of the pure HUD arithmetic, because the taps are tested
// against the same rectangles that are drawn -- the emulator run taps by reading
// these numbers back out of the log.
//
// Four buttons, in a column on the left of the panel area, because the screen has
// no world to look at yet and there is room. The bounds are checked by the host
// suite on a landscape phone, a portrait one and the emulator's 1920x1080.
#define UMBRA_GF_BUTTONS 4

static int umbra_gf_is_wide(int width, int height) {
    return height > 0 && (float)width / (float)height > 1.5f;
}

// The button's scale: a finger, not the overlay's text.
static float umbra_gf_scale(float dpi_scale, int width, int height) {
    float dp = (dpi_scale > 1.0f) ? dpi_scale : 1.0f;
    // 22 units tall, so 48 dp is s = 48 * dp / 22 -- and the ceiling is the
    // vertical budget, not a fraction of the short side: a 22-unit button at scale
    // 7.6 on a 1080-pixel screen was 167 px tall and four of them were 668 px,
    // which is two thirds of the screen. Four buttons plus their gaps must fit in
    // a third of the height, so the scale is capped by that.
    float s = 48.0f * dp / 22.0f;
    if (width < 16 || height < 16) return (s < 1.0f) ? 1.0f : s;
    // Landscape lays the four buttons out two by two, portrait stacks them: the
    // budget is a third of the height either way, and two rows is what lets a
    // button be a thumb's size (48 dp) on a phone instead of a label's.
    float budget = (float)height * 0.34f;
    int rows = (width / (height > 0 ? height : 1) > 1.5f) ? 2 : 4;
    float limit = budget / ((float)rows * 22.0f + (float)(rows - 1) * 5.0f);
    if (s > limit) s = limit;
    if (s < 1.0f) s = 1.0f;
    return s;
}

static umbra_rect umbra_hud_gf_button(int i, int width, int height, const int32_t insets[4],
                                      float scale) {
    umbra_rect r = { 0, 0, 0, 0 };
    if (i < 0 || i >= UMBRA_GF_BUTTONS || width < 16 || height < 16) return r;
    float bh = 22.0f * scale;
    float gap = 5.0f * scale;
    float margin = 10.0f * scale;
    float top = (float)insets[1] + margin;
    if (umbra_gf_is_wide(width, height)) {
        // A column on the left, under the panel, so the text of the screen has the
        // right-hand side to itself.
        // Two by two in the left half: the headline and the paragraph run down the
        // right-hand side, and two rows is what lets each button be 48 dp tall on a
        // phone without eating the screen.
        float col_gap = gap;
        float half = ((float)width * 0.5f - (float)insets[0] - 2.0f * margin - col_gap) * 0.5f;
        if (half < 40.0f) half = 40.0f;
        float stack = 2.0f * bh + gap;
        float room_top = (float)insets[1] + margin;
        float room_bottom = (float)height - (float)insets[3] - margin;
        float y0 = room_top + ((room_bottom - room_top) - stack) * 0.5f;
        if (y0 < room_top) y0 = room_top;
        r.x = margin + (float)insets[0] + (float)(i % 2) * (half + col_gap);
        r.w = half;
        r.y = y0 + (float)(i / 2) * (bh + gap);
        r.h = bh;
        return r;
    }
    // Portrait: full width, in the lower half, so the paragraph above it has the
    // top of the screen to itself.
    float w = (float)width - (float)insets[0] - (float)insets[2] - 2.0f * margin;
    if (w < 1.0f) w = 1.0f;
    r.x = margin + (float)insets[0];
    r.w = w;
    r.h = bh;
    float stack = (float)UMBRA_GF_BUTTONS * bh + (float)(UMBRA_GF_BUTTONS - 1) * gap;
    float room_bottom = (float)height - (float)insets[3] - margin;
    float y0 = room_bottom - stack;
    if (y0 < (float)height * 0.42f) y0 = (float)height * 0.42f;
    if (y0 + stack > room_bottom) y0 = room_bottom - stack;
    r.y = y0 + (float)i * (bh + gap);
    return r;
}

static int umbra_hud_gf_hit(int x, int y, int width, int height, const int32_t insets[4],
                            float scale) {
    for (int i = 0; i < UMBRA_GF_BUTTONS; i++) {
        umbra_rect r = umbra_hud_gf_button(i, width, height, insets, scale);
        // Overlap, not containment: a thumb is not a pixel.
        if ((float)(x + 1) > r.x && (float)x < r.x + r.w &&
            (float)(y + 1) > r.y && (float)y < r.y + r.h) {
            return i;
        }
    }
    return -1;
}

// The paragraph's left edge and the width it may use: the screen's own text, kept
// inside the insets and, in landscape, to the right of the button column.
static umbra_rect umbra_hud_gf_text(int width, int height, const int32_t insets[4], float scale) {
    umbra_rect r = { 0, 0, 0, 0 };
    if (width < 16 || height < 16) return r;
    float margin = 10.0f * scale;
    if (umbra_gf_is_wide(width, height)) {
        // The right-hand button of the top row: the text starts past both columns.
        umbra_rect b = umbra_hud_gf_button(1, width, height, insets, scale);
        r.x = b.x + b.w + margin;
        r.w = (float)width - (float)insets[2] - margin - r.x;
        r.y = (float)insets[1] + margin;
        r.h = (float)height - (float)insets[3] - margin - r.y;
    } else {
        r.x = margin + (float)insets[0];
        r.w = (float)width - (float)insets[0] - (float)insets[2] - 2.0f * margin;
        r.y = (float)insets[1] + margin;
        r.h = (float)height - (float)insets[3] - margin - r.y;
    }
    return r;
}
