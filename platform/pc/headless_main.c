// PC headless self-test: runs the Goose core with no window and no GPU, so CI
// can prove that the same C the APK ships works on x86_64 and Windows x64.
//
// It builds the demo world, meshes it, checks the mesh invariants, runs the
// format round trips on the fixture files, and prints PASS/FAIL.
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <stdlib.h>
#include "umbra_core.h"
#include "umbra_vertex.h"
#include "umbra_hud.h"

static int failures = 0;
static int checks = 0;

static void check(int cond, const char *what) {
    checks++;
    if (!cond) {
        failures++;
        printf("FAIL: %s\n", what);
    }
}

// Monotonic microseconds on the host; the core has its own clock, but this file
// measures the C side of the budget contract.
static int64_t umbra_now_us_headless(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

static const char *slice_text(const uint8_t *p, int64_t n) {
    static char buf[512];
    int k = n < 511 ? (int)n : 511;
    memcpy(buf, p, k);
    buf[k] = 0;
    return buf;
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    printf("umbra headless self-test\n");
    goose_init(argc, argv);

    int64_t vlen = 0, ilen = 0;
    // Two statements on purpose: reading vlen as an argument beside the call
    // that writes it is unspecified evaluation order.
    const uint8_t *version_bytes = umbra_version(&vlen);
    const char *version = slice_text(version_bytes, vlen);
    printf("core version: %s\n", version);
    check(vlen > 0, "version string is non-empty");

    // 1. The demo world builds and meshes with real geometry.
    umbra_demo_build(20261114);
    umbra_demo_mesh();
    const uint8_t *verts = umbra_verts_ptr(&vlen);
    const uint8_t *indices = umbra_indices_ptr(&ilen);
    printf("mesh: %llu vertex bytes, %llu index bytes\n", (unsigned long long)vlen,
           (unsigned long long)ilen);
    check(vlen > 0 && vlen % sizeof(umbra_vertex) == 0, "vertex buffer is whole vertices");
    check(ilen > 0 && ilen % 4 == 0, "index buffer is whole u32s");
    int64_t vcount = umbra_vert_count();
    int64_t icount = umbra_index_count();
    check(vcount == vlen / (int64_t)sizeof(umbra_vertex), "vertex count matches the byte length");
    check(icount == ilen / 4, "index count matches the byte length");

    // 2. Every index addresses a real vertex, every normal is unit length, and
    //    every coordinate is finite and inside the demo world's bounds.
    const umbra_vertex *v = (const umbra_vertex *)verts;
    const uint32_t *idx = (const uint32_t *)indices;
    int bad_index = 0, bad_normal = 0, bad_pos = 0;
    for (int64_t i = 0; i < icount; i++) {
        if (idx[i] >= (uint32_t)vcount) bad_index++;
    }
    for (int64_t i = 0; i < vcount; i++) {
        float len = sqrtf(v[i].nx*v[i].nx + v[i].ny*v[i].ny + v[i].nz*v[i].nz);
        if (fabsf(len - 1.0f) > 1e-3f) bad_normal++;
        if (!(v[i].x > -64.0f && v[i].x < 128.0f && v[i].y > -80.0f && v[i].y < 400.0f &&
              v[i].z > -64.0f && v[i].z < 128.0f)) bad_pos++;
    }
    printf("mesh checks: %d bad indices, %d bad normals, %d positions out of bounds\n",
           bad_index, bad_normal, bad_pos);
    check(bad_index == 0, "all indices address real vertices");
    check(bad_normal == 0, "all normals are unit length");
    check(bad_pos == 0, "all positions are inside the demo world");

    // 2b. The sliced mesher (what the phone runs) must produce exactly the same
    //     bytes as the all-at-once path (what the tools run), and it must respect
    //     its time budget: the whole point of slicing is that no call blocks the
    //     frame loop for long.
    {
        int64_t wvlen = 0, wilen = 0;
        const uint8_t *wv = umbra_verts_ptr(&wvlen);
        const uint8_t *wi = umbra_indices_ptr(&wilen);
        // 18 MB of vertices: heap, not the stack.
        uint8_t *whole_verts = (uint8_t *)malloc((size_t)wvlen);
        uint8_t *whole_indices = (uint8_t *)malloc((size_t)wilen);
        int fits = whole_verts && whole_indices && wvlen > 0 && wilen > 0;
        check(fits, "the whole mesh was copied for comparison");
        if (fits) {
            memcpy(whole_verts, wv, (size_t)wvlen);
            memcpy(whole_indices, wi, (size_t)wilen);
        }

        umbra_demo_mesh_begin();
        int64_t calls = 0, worst_call_us = 0;
        int done = 0;
        int64_t worst_progress = 0, last_progress = 0, backwards = 0;
        while (!done && calls < 100000) {
            int64_t t = umbra_now_us_headless();
            done = umbra_demo_mesh_step(2000) != 0;   // a 2 ms budget per call
            int64_t took = umbra_now_us_headless() - t;
            if (took > worst_call_us) worst_call_us = took;
            calls++;
            // The phone showed "LOADING WORLD 224%": progress is watched at every
            // step now, not just at the end.
            int64_t p = umbra_demo_mesh_progress();
            // Before the last step, progress must not claim to be finished.
            if (!done && p > worst_progress) worst_progress = p;
            if (p < last_progress) backwards++;
            last_progress = p;
        }
        umbra_demo_mesh_finish();
        check(done, "the sliced mesher finished");
        check(calls > 50, "the sliced mesher took many calls, not one");
        check(umbra_demo_mesh_progress() == 1000, "progress reaches 1000 when done");
        check(worst_progress < 1000, "progress is under 100% until the mesh is done");
        check(backwards == 0, "progress never goes backwards");
        printf("progress: worst %lld permille; units %lld, total %lld\n",
               (long long)worst_progress, (long long)umbra_demo_mesh_units(),
               (long long)umbra_demo_mesh_total_units());
        check(umbra_demo_mesh_units() == umbra_demo_mesh_total_units(),
              "the unit total is the count the stepper actually performs");
        printf("sliced mesh: %lld calls, worst call %.2f ms, worst unit %.2f ms\n",
               (long long)calls, worst_call_us / 1000.0,
               umbra_demo_mesh_worst_unit_us() / 1000.0);
        // A budget of 2 ms cannot promise a hard ceiling once single units are
        // themselves long, but every call must still be far under a second.
        check(worst_call_us < 900000, "no sliced mesher call blocked for a second");
        check(umbra_demo_mesh_units() > 100, "the sliced mesher made real units of work");

        int64_t svlen = 0, silen = 0;
        const uint8_t *sv = umbra_verts_ptr(&svlen);
        const uint8_t *si = umbra_indices_ptr(&silen);
        check(svlen == wvlen && silen == wilen, "the sliced mesh has the same byte lengths");
        check(fits && svlen == wvlen && memcmp(sv, whole_verts, (size_t)wvlen) == 0,
              "the sliced mesh has the same vertices as the whole-mesh path");
        check(fits && silen == wilen && memcmp(si, whole_indices, (size_t)wilen) == 0,
              "the sliced mesh has the same indices as the whole-mesh path");
        free(whole_verts);
        free(whole_indices);
        for (int b = 0; b < 3; b++) {
            check(umbra_batch_start(b) == umbra_batch_start(b), "batch starts are stable");
        }
    }

    // 3. The batches partition the index buffer.
    int64_t total = 0;
    for (int b = 0; b < 3; b++) total += umbra_batch_count(b);
    printf("batches: %lld + %lld + %lld = %lld of %lld indices\n",
           (long long)umbra_batch_count(0), (long long)umbra_batch_count(1),
           (long long)umbra_batch_count(2), (long long)total, (long long)icount);
    check(total == icount, "batches cover every index");
    check(umbra_batch_count(0) > 0, "the opaque batch is not empty");

    // 4. The self-test's expected pattern is deterministic and non-trivial.
    umbra_selftest_reset();
    umbra_selftest_pattern_pixel(0, 0, 640, 480, 0, 0, 64);
    check(umbra_selftest_mismatches() == 0, "a correct pattern pixel is accepted");
    umbra_selftest_pattern_pixel(639, 479, 640, 480, 255, 0, 64);
    check(umbra_selftest_mismatches() > 0, "a wrong pattern pixel is rejected");

    // 4b. The GPU self-test is only as good as the formula it compares with, so
    // the formula is run here over a whole small screen: every pixel the
    // fragment shader would produce must be accepted, and a shifted pixel must
    // not be. This is the CPU half of "test the tests".
    {
        const int w = 64, h = 48;
        umbra_selftest_reset();
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                int u = (x * 255) / (w - 1);
                int v = (y * 255) / (h - 1);
                umbra_selftest_pattern_pixel(x, y, w, h, (u ^ v) & 255, (u + v) & 255, 64);
            }
        }
        check(umbra_selftest_checked() == (int64_t)w * h, "the pattern check sees every pixel");
        check(umbra_selftest_mismatches() == 0, "the shader formula and Goose agree on every pixel");
        umbra_selftest_pattern_pixel(17, 23, w, h, 3, 3, 3);
        check(umbra_selftest_mismatches() > 0, "a pixel shifted away from the pattern is rejected");
    }

    // 4c. The cube verdict, tested on made-up pixels: background in the middle
    // must fail, a coloured pixel far outside must fail, and a coloured pixel
    // in the middle must pass. Without this the cube test could pass by
    // judging nothing at all.
    {
        umbra_selftest_reset();
        umbra_selftest_cube_pixel(960, 540, 1920, 1080, 5, 8, 15);
        check(umbra_selftest_mismatches() == 1, "background where the cube should be is a failure");
        umbra_selftest_reset();
        umbra_selftest_cube_pixel(960, 540, 1920, 1080, 120, 30, 30);
        check(umbra_selftest_mismatches() == 0, "a shaded cube face in the middle passes");
        umbra_selftest_reset();
        umbra_selftest_cube_pixel(20, 20, 1920, 1080, 120, 30, 30);
        check(umbra_selftest_mismatches() == 1, "colour outside the cube silhouette is a failure");
    }

    // 4b. The overlay's geometry. This is the code that put text under the status
    //     bar on the owner's phone (the emulator reports a top inset of 0), so the
    //     case is simulated here, on a screen with a 63 px status bar, a 126 px
    //     navigation bar and a 2412x1080 landscape frame at density 3.5.
    {
        int32_t phone[4] = {0, 63, 126, 0};      // left, top, right, bottom
        int32_t bars[4] = {0, 0, 126, 126};      // the emulator's answer
        int32_t zero[4] = {0, 0, 0, 0};
        float s_phone = umbra_hud_scale(3.5f, 2412, 1080, 12, 63);
        float s_desktop = umbra_hud_scale(1.0f, 1920, 1080, 12, 0);
        printf("layout: phone scale %.2f, desktop scale %.2f\n", s_phone, s_desktop);
        check(s_desktop == 1.0f, "a desktop screen keeps scale 1, so its reference does not move");
        check(s_phone >= 2.0f, "a 560 dpi phone gets readable text");
        float panel = umbra_hud_panel_height(12, s_phone, phone[1]);
        check(panel <= 1080.0f * UMBRA_HUD_MAX_FRACTION + 1.0f,
              "the overlay never eats more than 45% of a phone screen");
        check(panel >= 63.0f, "the overlay starts below a 63 px status bar");

        umbra_rect b0 = umbra_hud_button(0, 2412, 1080, phone, s_phone);
        umbra_rect b2 = umbra_hud_button(2, 2412, 1080, phone, s_phone);
        printf("layout: button 0 %.0f,%.0f %.0fx%.0f; button 2 %.0f,%.0f\n", b0.x, b0.y, b0.w, b0.h, b2.x, b2.y);
        check(b0.x >= (float)phone[0], "buttons start inside the left inset");
        check(b0.x + b0.w <= 2412.0f - (float)phone[2] + 0.5f, "buttons stop before the right inset");
        check(b2.y + b2.h <= 1080.0f - (float)phone[3] + 0.5f, "buttons stop above the bottom inset");
        check(b0.y >= (float)phone[1], "buttons start below the top inset");
        check(b0.h >= 40.0f, "a button is tall enough for a thumb");

        // A cutout on the left (a punch-hole phone held in landscape) must not be
        // covered either, and a surface that is not there yet must not produce a
        // negative rectangle (that was "button 0 at 25,-269 size -49x63").
        int32_t cut[4] = {112, 63, 126, 0};
        umbra_rect bc = umbra_hud_button(1, 2412, 1080, cut, s_phone);
        check(bc.x >= 112.0f, "a left display cutout is kept clear");
        umbra_rect stub = umbra_hud_button(0, 1, 1, zero, s_phone);
        check(stub.w == 0.0f && stub.h == 0.0f, "a 1x1 surface produces no buttons, not negative ones");
        umbra_rect emu = umbra_hud_button(0, 1920, 1080, bars, 2.62f);
        check(emu.x + emu.w <= 1920.0f - 126.0f + 0.5f, "the emulator's 126 px navigation bar is kept clear");

        // The scene is pushed down by the fraction the panel covers, so the world
        // is centred in what is left rather than behind the overlay.
        float shift = umbra_hud_scene_shift(panel, 1080);
        check(shift < 0.0f, "the world moves down out from under the overlay");
        check(shift >= -0.6f, "and never by more than 60% of the screen");
        check(umbra_hud_scene_shift(0.0f, 1080) == 0.0f, "no overlay means no shift");

        // flatten(): what the last-run file stores is one line per result.
        char flat[64];
        int n = umbra_flatten(flat, sizeof flat, "bench: 3 frames\n1% low 52 fps\nmedian 16.75");
        check(n > 0 && strstr(flat, "\n") == NULL, "the benchmark block flattens to one line");
        check(strstr(flat, "1% low 52 fps") != NULL, "flattening keeps the numbers");
    }

    // 5. The benchmark statistics are real arithmetic on real numbers.
    umbra_bench_reset();
    for (int i = 0; i < 1000; i++) umbra_bench_add(16000 + (i % 10));
    int64_t len = 0;
    sl_u8 label = {(uint8_t *)"bench", 5};
    sl_u8 dev = {(uint8_t *)"headless", 8};
    sl_u8 android = {(uint8_t *)"none", 4};
    const uint8_t *summary = umbra_bench_summary(label, dev, android, &len);
    printf("%s\n", slice_text(summary, len));
    check(len > 20, "benchmark summary is formatted");
    // The numbers are arithmetic, not decoration: check them digit by digit.
    const char *text = slice_text(summary, len);
    check(strstr(text, "1000 frames") != NULL, "the summary counts the frames");
    check(strstr(text, "avg 16.00 ms (62 fps)") != NULL,
          "the average frame time and its fps are right");
    check(strstr(text, "1% low 62 fps (16.00 ms)") != NULL,
          "the 1% low is the mean of the slowest frames");
    check(strstr(text, "median 16.00 ms") != NULL, "the median frame is reported");
    check(strstr(text, "worst 16.00 ms") != NULL, "the worst frame is reported");
    int lines = 1;
    for (const char *q = text; *q; q++) {
        if (*q == '\n') lines++;
    }
    check(lines == 4, "the benchmark block is four lines on a phone screen");

    // A spread of frame times must separate the average from the 1% low.
    umbra_bench_reset();
    for (int i = 0; i < 200; i++) umbra_bench_add(16000);
    for (int i = 0; i < 2; i++) umbra_bench_add(100000);
    summary = umbra_bench_summary(label, dev, android, &len);
    text = slice_text(summary, len);
    printf("%s\n", text);
    check(strstr(text, "avg 16.83 ms") != NULL, "a few slow frames move the average");
    check(strstr(text, "1% low 10 fps (100.00 ms)") != NULL,
          "and the 1% low reports them at their real cost");

    goose_exit();
    printf("%s: %d checks, %d failures\n", failures ? "FAILED" : "PASS", checks, failures);
    return failures ? 1 : 0;
}
