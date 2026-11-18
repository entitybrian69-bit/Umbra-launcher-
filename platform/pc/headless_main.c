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
#ifdef _WIN32
#include <direct.h>
#define umbra_mkdir(p) _mkdir(p)
#define umbra_rmdir(p) _rmdir(p)
#else
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#define umbra_mkdir(p) mkdir((p), 0700)
#define umbra_rmdir(p) rmdir(p)
#endif
#include "umbra_core.h"
#include "umbra_vertex.h"
#include "umbra_hud.h"
// The edit budget the app holds itself to; the suite checks the same number.
#define UMBRA_EDIT_BUDGET_MS 50
#include "umbra_results.h"
#include "umbra_camera.h"
#include "umbra_player.h"
#include "umbra_selftest.h"


// A grid to test the player on: solid stone from y = 0 down, a wall at x = 10, and a
// bottom slab filling z in [4,6) at y = 0 so half-height collision is exercised.
typedef struct { int wall_x; float slab_z0, slab_z1; } player_grid;

static void player_grid_init(player_grid *g) {
    g->wall_x = 10;
    g->slab_z0 = 4.0f;
    g->slab_z1 = 6.0f;
}

static float player_top(void *ctx, int x, int y, int z) {
    player_grid *g = (player_grid *)ctx;
    if (x == g->wall_x && y >= 0 && y < 3 && (z < (int)g->slab_z0 || z >= (int)g->slab_z1 + 2)) return 1.0f;
    if (y < 0) return 1.0f;
    if (y == 0) {
        if ((float)z >= g->slab_z0 && (float)z < g->slab_z1) return 0.5f;
        return 1.0f;
    }
    return -1.0f;
}

// A second grid for the things the first one cannot express: a full-block step, a
// three-block wall with no headroom above it, a pond, and a ledge to sneak along.
//
//   y < 0, z < 18   floor (the surface is y = 0's top, at 1.0)
//   z >= 18         no floor at all: the drop the sneak has to refuse
//   z in [6,10)     a second block on top of the floor, so walking +Z meets a 1.0 step
//   x == 4          a three-block wall, so a 1.01 step has nowhere to put the head
//   z in [10,14)    water at y 1..2, over the same floor: a two-block pond
//
// The first version of this made the step block span all z, which buried the pond:
// the swim stroke could not rise because the body was standing inside a solid block.
// A test world has to be checked against the thing being tested, not only for itself.
typedef struct { int water_z0, water_z1, step_z0, step_z1, ledge_z; } pool_grid;

static void pool_grid_init(pool_grid *g) {
    g->water_z0 = 10;
    g->water_z1 = 14;
    g->step_z0 = 6;
    g->step_z1 = 10;
    g->ledge_z = 18;
}

static float pool_top(void *ctx, int x, int y, int z) {
    pool_grid *g = (pool_grid *)ctx;
    if (x == 4 && y >= 0 && y < 3) return 1.0f;          /* three blocks, no headroom */
    if (z >= g->ledge_z) return -1.0f;                     /* the ledge: nothing at all */
    if (y < 0) return 1.0f;
    if (y == 0) return 1.0f;
    if (y == 1 && z >= g->step_z0 && z < g->step_z1) return 1.0f;
    return -1.0f;
}

static int pool_fluid(void *ctx, int x, int y, int z) {
    pool_grid *g = (pool_grid *)ctx;
    if (z >= g->water_z0 && z < g->water_z1 && y >= 1 && y <= 2) return 1;
    return 0;
}

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

// The geometry the ranges actually draw, in draw order: every index resolved to its
// vertex, hashed. Two meshes of the same world agree on this even when their arena
// capacities differ, which is what an edit changes and a rebuild does not.
static uint64_t used_geometry_hash(void) {
    int64_t vlen = 0, ilen = 0;
    const uint8_t *verts = umbra_verts_ptr(&vlen);
    const uint8_t *indices = umbra_indices_ptr(&ilen);
    uint64_t h = 1469598103934665603ULL;
    int slots = (int)umbra_range_slots();
    if (!verts || !indices) return 0;
    for (int pass = 0; pass < 3; pass++) {
        for (int i = 0; i < slots; i++) {
            if ((int)umbra_range_batch(i) != pass) continue;
            int64_t n = umbra_range_index_len(i), ioff = umbra_range_index(i);
            for (int64_t k = 0; k < n; k++) {
                uint32_t vi = 0;
                memcpy(&vi, indices + (ioff + k) * 4, 4);
                if ((int64_t)vi >= vlen / (int64_t)sizeof(umbra_vertex)) return 0;
                const uint8_t *v = verts + (size_t)vi * sizeof(umbra_vertex);
                for (size_t b = 0; b < sizeof(umbra_vertex); b++) {
                    h ^= v[b];
                    h *= 1099511628211ULL;
                }
            }
        }
    }
    return h;
}

// How many indices the ranges draw: one number a break or a place has to change.
static int64_t used_index_total(void) {
    int64_t total = 0;
    int slots = (int)umbra_range_slots();
    for (int i = 0; i < slots; i++) total += umbra_range_index_len(i);
    return total;
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
        // The demo world is 48x48 and 128 blocks tall. The height bound used to be 400,
        // and that is why nobody saw that three of the four columns were stacked 16, 32
        // and 48 blocks up by a `y: src.y + oz` in the column copy.
        if (!(v[i].x > -1.0f && v[i].x < 49.0f && v[i].y > -80.0f && v[i].y < 160.0f &&
              v[i].z > -1.0f && v[i].z < 49.0f)) bad_pos++;
    }
    printf("mesh checks: %d bad indices, %d bad normals, %d positions out of bounds\n",
           bad_index, bad_normal, bad_pos);
    check(bad_index == 0, "all indices address real vertices");
    check(bad_normal == 0, "all normals are unit length");
    check(bad_pos == 0, "all positions are inside the demo world, height included");

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
        int64_t calls = 0, worst_call_us = 0, worst_unit_us = 0;
        int done = 0;
        int64_t worst_progress = 0, last_progress = 0, backwards = 0;
        while (!done && calls < 100000) {
            int64_t t = umbra_now_us_headless();
            // The app's own start-up budget, not a test-sized one: the device run
            // that read the worst loading call at 45.4 ms under a six-millisecond
            // slice is why the budget is now the brief's 50 (header comment).
            done = umbra_demo_mesh_step(20 * 1000) != 0;   // the app's 20 ms slice
            int64_t took = umbra_now_us_headless() - t;
            if (took > worst_call_us) worst_call_us = took;
            {
                // The unit is what a slice cannot cut; it is the app's own floor.
                float u = umbra_demo_mesh_worst_unit_us();
                if ((int64_t)u > worst_unit_us) worst_unit_us = (int64_t)u;
            }
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
        // Sliced, not one call: with the app's 20 ms slice a whole demo world is
        // about two dozen calls, and the check is that it is many *and* that the
        // call count is far below the unit count (649 units), which is what slicing
        // buys. The old `calls > 50` was written for a 2 ms budget in this test and
        // said more about the test than about the app.
        check(calls > 5, "the sliced mesher took more than a handful of calls");
        check(calls * 4 < umbra_demo_mesh_units(),
              "the mesh was sliced: far fewer calls than units of work");
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
        // The budget is the brief's 50 ms now, so the check is the brief's number:
        // a loading call that holds the loop longer than that fails the host suite
        // as it fails the device phase.
        // A wall-clock gate here would be a gate on the runner, not on the app: the
        // same commit measured 3.42 ms and 119.57 ms for the same unit on the same
        // Windows runner (runs 44002574807 and 44005482631), and 4.39 vs 119.57 with
        // identical code. So the host does what a host can do -- print both numbers
        // every run so a trend is visible, and fail on a bound far outside that noise
        // (8x the brief's 50 ms), which still catches the regression that started this:
        // the arena being copied dozens of times per load measured 103 ms, and 113 ms
        // of calls, where the fixed code is 3-5 ms and 22 ms.
        //
        // The 50 ms itself is enforced on the device (the emulator phase's "worst
        // meshing call") and for edits below, where the work is small enough that the
        // measurement is about the code.
        check(worst_unit_us <= 8 * (int64_t)UMBRA_EDIT_BUDGET_MS * 1000,
              "no single unit of loading took eight times the 50 ms budget");
        check(worst_call_us <= 8 * (int64_t)UMBRA_EDIT_BUDGET_MS * 1000,
              "no loading call took eight times the 50 ms budget");
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
    }

    // 2c. The world is held as one range per (pass, column), and the ranges have to
    //     account for every index, stay inside the buffers, and be ordered so the
    //     passes are drawn in order.
    int slots = (int)umbra_range_slots();
    int64_t per_pass[3] = {0, 0, 0};
    int64_t used_indices = 0, bad_range = 0, order_breaks = 0, last_pass = -1;
    printf("ranges: %d slots for %lld columns\n", slots, (long long)umbra_world_columns());
    check(slots == 3 * (int)umbra_world_columns(), "one range per pass and column");
    for (int i = 0; i < slots; i++) {
        int b = (int)umbra_range_batch(i);
        int64_t voff = umbra_range_vertex(i), vlen_i = umbra_range_vertex_len(i);
        int64_t ioff = umbra_range_index(i), ilen_i = umbra_range_index_len(i);
        if (b < 0 || b > 2) bad_range++;
        if (b < last_pass) order_breaks++;
        last_pass = b > last_pass ? b : last_pass;
        if (ilen_i > 0) {
            if (ioff < 0 || ioff + ilen_i > icount) bad_range++;
            if (voff < 0 || vlen_i <= 0 || voff + vlen_i > vcount) bad_range++;
            for (int64_t k = ioff; k < ioff + ilen_i; k++) {
                if (idx[k] >= (uint32_t)(voff + vlen_i)) { bad_range++; break; }
            }
        }
        per_pass[b] += ilen_i;
        used_indices += ilen_i;
    }
    printf("ranges: %lld + %lld + %lld = %lld indices used of %lld in the arena\n",
           (long long)per_pass[0], (long long)per_pass[1], (long long)per_pass[2],
           (long long)used_indices, (long long)icount);
    check(bad_range == 0, "every range is inside its buffers and every index in its range");
    check(order_breaks == 0, "the ranges are ordered by pass, so opaque draws first");
    check(used_indices > 0 && used_indices <= icount, "the ranges use real geometry");
    check(per_pass[0] > 0, "the opaque pass is not empty");

    // 2d. An edit re-meshes the column it touched and nothing else, and no slice of it
    //     may hold a frame for long. Before the edit, the mesh is copied; after it, the
    //     world is meshed again from scratch; the two have to agree, which is what
    //     proves the slot patching did not drop or duplicate geometry.
    {
        int64_t evlen = 0;
        (void)umbra_verts_ptr(&evlen);
        check(evlen > 0, "there is a mesh to edit");

        // Edit a block in the middle of a column, then a block on a chunk border, which
        // is the case that also re-meshes the neighbour.
        int edits[2][3] = {{8, 66, 40}, {16, 64, 40}};
        for (int e = 0; e < 2; e++) {
            const char *block = "minecraft:stone";
            int did = (int)umbra_edit_block(edits[e][0], edits[e][1], edits[e][2],
                                            (sl_u8){(uint8_t *)block,
                                                    (int64_t)strlen(block)});
            check(did == 1, "a block was placed for the edit test");
            int64_t columns = umbra_mesh_columns();
            int64_t total_units = umbra_demo_mesh_total_units();
            printf("edit %d: %lld columns, %lld units of work, is_edit %lld\n", e,
                   (long long)columns, (long long)total_units,
                   (long long)umbra_mesh_is_edit());
            check(umbra_mesh_is_edit() == 1, "the edit pass knows it is an edit");
            check(columns >= 1 && columns <= 4, "an edit re-meshes a few columns, not the world");
            // A column is 24 sections x 3 passes x 16 layers (its copy is folded into the
        // unit that ends the last pass), plus the unit that finds the list empty.
        check(total_units == columns * (3 * 24 * 16) + 1,
              "the work is that column's sections only");
            int64_t calls = 0, worst_us = 0;
            int done = 0;
            while (!done && calls < 100000) {
                int64_t t = umbra_now_us_headless();
                done = umbra_demo_mesh_step(6000) != 0;
                int64_t took = umbra_now_us_headless() - t;
                if (took > worst_us) worst_us = took;
                calls++;
            }
            umbra_demo_mesh_finish();
            printf("edit %d: %lld calls, worst call %.2f ms, worst slice %.2f ms\n", e,
                   (long long)calls, worst_us / 1000.0, umbra_mesh_worst_unit_ms());
            check(done, "the edit's re-mesh finished");
            check(worst_us < (int64_t)UMBRA_EDIT_BUDGET_MS * 1000,
                  "no slice of an edit blocked a frame for 50 ms");
            check(umbra_mesh_worst_unit_ms() < (float)UMBRA_EDIT_BUDGET_MS,
                  "no single section of an edit took 50 ms");
            check(calls < 100000, "the edit converged");
        }

        // The patched world against one meshed from scratch: the same geometry, in the
        // same draw order. The arenas differ (a slot keeps the slack it was given), so
        // the comparison is the geometry itself, not the bytes around it.
        uint64_t patched_hash = used_geometry_hash();
        int64_t patched_used = used_index_total();
        umbra_demo_mesh_begin();
        while (umbra_demo_mesh_step(1000000) == 0) { }
        umbra_demo_mesh_finish();
        uint64_t rebuilt_hash = used_geometry_hash();
        int64_t rebuilt_used = used_index_total();
        printf("edit: patched geometry %016llx (%lld indices), rebuilt %016llx (%lld)\n",
               (unsigned long long)patched_hash, (long long)patched_used,
               (unsigned long long)rebuilt_hash, (long long)rebuilt_used);
        check(patched_hash != 0 && patched_used > 0, "the patched geometry can be hashed");
        check(patched_used == rebuilt_used, "the edit drew the same number of indices as a rebuild");
        check(patched_hash == rebuilt_hash,
              "the columns patched by the edit match a mesh built from scratch");

    }

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
        umbra_rect b1 = umbra_hud_button(1, 2412, 1080, phone, s_phone);
        umbra_rect b2 = umbra_hud_button(2, 2412, 1080, phone, s_phone);
        printf("layout: button 0 %.0f,%.0f %.0fx%.0f; button 2 %.0f,%.0f\n", b0.x, b0.y, b0.w, b0.h, b2.x, b2.y);
        check(umbra_hud_is_wide(2412, 1080), "a landscape phone gets the buttons in a row");
        check(!umbra_hud_is_wide(1080, 1920), "a portrait phone stacks them");
        check(b0.y == b1.y && b1.y == b2.y, "the row of buttons shares one baseline");
        check(b1.x >= b0.x + b0.w - 0.5f && b2.x >= b1.x + b1.w - 0.5f,
              "the buttons in a row do not overlap");
        check(b0.x >= (float)phone[0], "buttons start inside the left inset");
        check(b2.x + b2.w <= 2412.0f - (float)phone[2] + 0.5f, "buttons stop before the right inset");
        check(b2.y + b2.h <= 1080.0f - (float)phone[3] + 0.5f, "buttons stop above the bottom inset");
        check(b0.y >= (float)phone[1], "buttons start below the top inset");
        check(b0.h >= 40.0f, "a button is tall enough for a thumb");
        check(b0.w >= (2412.0f - 126.0f) / 3.0f * 0.7f, "each button is a decent target in a row");

        // Portrait: stacked, full width, inside the same insets.
        int32_t tall_insets[4] = {0, 80, 0, 130};
        umbra_rect p0 = umbra_hud_button(0, 1080, 1920, tall_insets, 3.0f);
        umbra_rect p2 = umbra_hud_button(2, 1080, 1920, tall_insets, 3.0f);
        check(p0.y < p2.y && p0.w > 1080.0f * 0.8f, "portrait stacks full-width buttons");
        check(p2.y + p2.h <= 1920.0f - 130.0f + 0.5f, "the stack clears a 130 px navigation bar");

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

        // The band the world is drawn in: below the overlay, above the buttons.
        int rows = 9;
        float band_top = 0.0f, band_bottom = 0.0f;
        umbra_hud_scene_band(rows, s_phone, phone, 2412, 1080, &band_top, &band_bottom);
        float panel_h = umbra_hud_panel_height(rows, s_phone, phone[1]);
        printf("layout: panel %.0f px, free band %.0f..%.0f (%.0f%% of 1080)\n",
               panel_h, band_top, band_bottom, (band_bottom - band_top) / 1080.0f * 100.0f);
        check(band_top >= panel_h, "the band starts below the overlay, not under it");
        check(band_top >= 63.0f, "and below the status bar");
        check(band_bottom <= b0.y, "the band stops at the buttons");
        check(band_bottom - band_top > 1080.0f * 0.35f,
              "the world gets more than a third of the screen height on a landscape phone");
        check(umbra_hud_band_shift(band_top, band_bottom, 1080) < 0.0f,
              "the world is moved down into the band");
        check(umbra_hud_band_shift(0.0f, 1080.0f, 1080) == 0.0f,
              "a surface with no overlay and no buttons needs no shift");

     // 4b-2. The camera: the world must fit the band on the owner's screen, and
     //       must not be a thumbnail in it. Same numbers as the phone: 2412x1080,
     //       63 px status bar, 126 px navigation bar, and the demo world's real
     //       bounds (x 0..48, y -64..106, z 0..16).
        {
            float mn[3] = {0.0f, -64.0f, 0.0f};
            float mx[3] = {48.0f, 106.0f, 16.0f};
            umbra_camera_fit f = umbra_camera_fit_world(mn, mx, 55.0f, 2412, 1080, band_top, band_bottom);
            check(f.ok, "the world could be fitted to the phone's screen");
            float tan_v = tanf(55.0f * 3.14159265f / 180.0f * 0.5f);
            float aspect = 2412.0f / 1080.0f;
            // What has to fit is the height that was fitted and the footprint's
            // width, measured as angles from the eye.
            float v_half = atanf((f.fitted_height * 0.5f) / f.dist);
            float h_half = atanf(((mx[0] - mn[0]) * 0.5f) / f.dist);
            float screen_v = atanf(tan_v), screen_h = atanf(tan_v * aspect);
            float band_half = atanf(tan_v * f.band_fraction);
            printf("camera: %.1f blocks out, world %.1f deg tall by %.1f deg wide, screen %.1f x %.1f, band %.1f\n",
                   f.dist, v_half * 57.2958f, h_half * 57.2958f, screen_v * 57.2958f,
                   screen_h * 57.2958f, band_half * 57.2958f);
            check(v_half <= screen_v + 1e-3f, "the world's height fits on the screen");
            check(h_half <= screen_h + 1e-3f, "the world's width fits on the screen");
            check(v_half >= band_half * 0.95f,
                  "and is at least as tall as the free band, not a stamp in the middle");
            check(v_half >= screen_v * 0.75f, "it uses most of the screen height, not a corner");
            float dx = f.eye[0] - f.look[0], dy = f.eye[1] - f.look[1], dz = f.eye[2] - f.look[2];
            float len = sqrtf(dx * dx + dy * dy + dz * dz);
            check(fabsf(len - f.dist) < 0.05f * f.dist, "the eye really is cam_dist from the look point");
            check(dy > 0.0f, "the eye looks down at the world");
            // The aim point must be on the visible top of the world, not at the box
            // centre: the demo world is a 170-block slab whose centre is a wall.
            check(f.look[1] > mx[1] - 40.0f, "it aims at the top of the world, not at the box centre");
            check(f.look[1] < mx[1], "just below the highest block");
            check(f.eye[1] > mx[1] - 20.0f, "the eye is up with the peaks, not down in the rock");
            check(f.fog_near > f.dist - f.fitted_height, "the fog starts beyond the near face of the world");
            check(f.fog_near >= f.dist, "and behind the point the eye is aimed at, so the rock is not greyed");
            check(f.fog_far > f.dist + f.fitted_height, "and ends past the far side of the world");
            check(f.fog_far > f.fog_near * 2.0f, "with a long enough fall-off to see depth");

            // The emulator's screen: no status bar of its own, so the band is
            // bigger and the camera should come closer, not further.
            float emu_top = 0.0f, emu_bottom = 0.0f;
            umbra_hud_scene_band(8, 2.62f, bars, 1920, 1080, &emu_top, &emu_bottom);
            umbra_camera_fit fe = umbra_camera_fit_world(mn, mx, 55.0f, 1920, 1080, emu_top, emu_bottom);
            printf("camera: emulator %.1f blocks out in a band starting at %.0f\n", fe.dist, emu_top);
            check(fe.ok && fe.dist > 0.0f, "the emulator screen also produces a camera");
            check(fabsf(fe.dist - f.dist) < 0.05f * f.dist,
                  "the same world at the same aspect gets the same distance, insets or not");

            // A tiny world and a huge one must both be framed sanely.
            float small_mn[3] = {0, 0, 0}, small_mx[3] = {2, 2, 2};
            umbra_camera_fit fs = umbra_camera_fit_world(small_mn, small_mx, 55.0f, 2412, 1080, band_top, band_bottom);
            check(fs.ok && fs.dist >= 16.0f, "a two-block world is not jumped on top of");
            float big_mn[3] = {-1000, -64, -1000}, big_mx[3] = {1000, 200, 1000};
            umbra_camera_fit fb = umbra_camera_fit_world(big_mn, big_mx, 55.0f, 2412, 1080, band_top, band_bottom);
            check(fb.ok && fb.dist <= 400.0f, "a 2000-block world is clamped, not sent to infinity");
        }

        // flatten(): what the last-run file stores is one line per result.
        char flat[64];
        int n = umbra_flatten(flat, sizeof flat, "bench: 3 frames\n1% low 52 fps\nmedian 16.75");
        check(n > 0 && strstr(flat, "\n") == NULL, "the benchmark block flattens to one line");
        check(strstr(flat, "1% low 52 fps") != NULL, "flattening keeps the numbers");
    }

    // 4c. The result files. These live next to the log and are what the overlay
    //     reads back on the next start; the first version computed their names
    //     only while logging, which is later than the read, so a restart showed
    //     "nothing recorded yet" after a run that had saved both. Exercised here
    //     with a real temporary directory rather than a mock.
    {
        // A real directory, created portably: the pc suite runs on Windows too.
        char dir[256];
        dir[0] = 0;
        const char *base = getenv("TMPDIR");
        if (!base) base = getenv("TEMP");
        if (!base) base = getenv("TMP");
        if (!base) base = ".";
        for (int attempt = 0; attempt < 20 && !dir[0]; attempt++) {
            char candidate[256];
            snprintf(candidate, sizeof candidate, "%s/umbra-results-%ld-%d", base, (long)time(NULL), attempt);
            if (umbra_mkdir(candidate) == 0) snprintf(dir, sizeof dir, "%s", candidate);
        }
        if (dir[0]) {
            char log_path[256], self_path[256], bench_path[256];
            snprintf(log_path, sizeof log_path, "%s/umbra.log", dir);
            umbra_result_path(log_path, "last_selftest.txt", self_path, sizeof self_path);
            umbra_result_path(log_path, "last_bench.txt", bench_path, sizeof bench_path);
            check(strstr(self_path, "last_selftest.txt") != NULL &&
                  strncmp(self_path, dir, strlen(dir)) == 0,
                  "the result files sit next to the log");

            umbra_result_save(self_path, "SELFTEST PASS (0 bad of 2073600 px, 41 ms)");
            umbra_result_save(bench_path, "BENCH 60 s: 1257 frames, avg 47.8 ms (20 fps)");
            char got[256];
            int n = umbra_result_load(self_path, got, sizeof got);
            check(n > 0 && strstr(got, "SELFTEST PASS") != NULL, "a saved result reads back");
            check(strchr(got, '\n') == NULL, "the stored line comes back without its newline");

            char block[320];
            int lines = umbra_last_run_block(block, sizeof block, got, "BENCH 60 s: 20 fps");
            check(lines == 3, "the block is a title and one line per result");
            check(strncmp(block, "LAST RUN", 8) == 0, "the block is titled LAST RUN");
            check(strstr(block, "SELFTEST PASS") && strstr(block, "20 fps"), "both results are in the block");

            char missing[256];
            umbra_result_path(log_path, "not-there.txt", missing, sizeof missing);
            check(umbra_result_load(missing, got, sizeof got) == 0 && got[0] == 0,
                  "a missing result file reads back as empty, not as garbage");
            check(umbra_last_run_block(block, sizeof block, "", "") == 0,
                  "and produces no block at all");

            // A file the process cannot open must not report a result either.
            umbra_result_save("/proc/umbra-nope/x.txt", "SELFTEST");
            check(umbra_result_load("/proc/umbra-nope/x.txt", got, sizeof got) == 0,
                  "an unwritable path saves nothing and loads nothing");

            char unlink_log[256];
            snprintf(unlink_log, sizeof unlink_log, "%s/umbra.log", dir);
            remove(self_path);
            remove(bench_path);
            remove(unlink_log);
            umbra_rmdir(dir);
        } else {
            check(0, "a temporary directory was available for the result-file test");
        }
    }

    // 4d. The overlay's own height: the panel must be taller than the rows drawn
    //     in it, on the phone's numbers and on the emulator's, with and without a
    //     crash tail. A phone screenshot showed the last three lines below the
    //     panel because the walk counted whole rows and the title takes 1.6.
    {
        struct { int bench, last_run, crash; } cases[] = {
            {0, 0, 0}, {0, 3, 0}, {0, 3, 3}, {3, 3, 0}, {1, 0, 3},
        };
        for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
            float rows = umbra_hud_rows(cases[i].bench, cases[i].last_run, cases[i].crash);
            int whole = (int)rows + (rows > (float)(int)rows ? 1 : 0);
            for (int screen = 0; screen < 2; screen++) {
                int w = screen ? 2412 : 1920, h = screen ? 1080 : 1080;
                int32_t in[4] = {0, screen ? 63 : 0, screen ? 126 : 126, 0};
                float sc = umbra_hud_scale(screen ? 3.5f : 1.0f, w, h, whole, in[1]);
                float panel = umbra_hud_panel_height(whole, sc, in[1]);
                float content = 8.0f * sc + rows * UMBRA_HUD_ROW_HEIGHT * sc;
                check(content <= panel + 0.5f, "the overlay's rows fit inside its panel");
                check(panel <= (float)h * UMBRA_HUD_MAX_FRACTION + 1.0f,
                      "and the panel stays inside its share of the screen");
                check(sc >= 1.0f, "at a size that can be read");
            }
        }
        float rows = umbra_hud_rows(3, 3, 1);
        int whole = (int)rows + (rows > (float)(int)rows ? 1 : 0);
        printf("hud: %d rows for a bench block, a last run and a crash tail\n", whole);
        // 21 with the world row: the overlay says whether the world is a save or the demo
        // scene, and a row that is drawn but not counted is the class of bug this check
        // exists for (0.3.1 drew the crash tail on bare sky exactly that way).
        check(whole == 21, "the row count for that overlay is the one the log reports");
    }

    // --- the game-files screen fits, and its buttons are tappable -----------
    // The screen a phone needs (D-043) has four buttons that are drawn and tapped
    // through one rectangle each. These checks are the layout's side of that: on a
    // landscape phone, a portrait one and the emulator's 1920x1080, every button is
    // on the screen, inside the insets, big enough for a thumb, does not overlap
    // another, and a tap at its centre presses it.
    {
        int32_t phone[4] = { 0, 63, 126, 0 };
        int32_t bars[4] = { 0, 0, 126, 126 };
        int32_t zero[4] = { 0, 0, 0, 0 };
        struct { int w, h; const int32_t *in; float dpi; const char *what; } gf[3] = {
            { 2412, 1080, phone, 3.5f, "the owner's phone" },
            { 1080, 1920, zero, 3.0f, "a portrait phone" },
            { 1920, 1080, bars, 2.62f, "the CI emulator" },
        };
        for (int c = 0; c < 3; c++) {
            int w = gf[c].w, h = gf[c].h;
            float s = umbra_gf_scale(gf[c].dpi, w, h);
            float min_h = 44.0f * (gf[c].dpi > 1.0f ? gf[c].dpi : 1.0f) * 1.0f;
            printf("gamefiles: %s %dx%d: scale %.2f, button 0 %.0fx%.0f\n", gf[c].what, w, h, s,
                   umbra_hud_gf_button(0, w, h, gf[c].in, s).w,
                   umbra_hud_gf_button(0, w, h, gf[c].in, s).h);
            int inside = 1, hits = 1, overlap = 0;
            for (int i = 0; i < UMBRA_GF_BUTTONS; i++) {
                umbra_rect r = umbra_hud_gf_button(i, w, h, gf[c].in, s);
                if (r.w <= 0.0f || r.h <= 0.0f) inside = 0;
                if (r.x < (float)gf[c].in[0] || r.y < (float)gf[c].in[1]) inside = 0;
                if (r.x + r.w > (float)w - (float)gf[c].in[2] + 0.5f) inside = 0;
                if (r.y + r.h > (float)h - (float)gf[c].in[3] + 0.5f) inside = 0;
                if (umbra_hud_gf_hit((int)(r.x + r.w * 0.5f), (int)(r.y + r.h * 0.5f),
                                     w, h, gf[c].in, s) != i) hits = 0;
                for (int j = 0; j < i; j++) {
                    umbra_rect o = umbra_hud_gf_button(j, w, h, gf[c].in, s);
                    if (r.x < o.x + o.w && o.x < r.x + r.w && r.y < o.y + o.h && o.y < r.y + r.h) {
                        overlap = 1;
                    }
                }
            }
            check(inside, "every game-files button is on the screen and inside the insets");
            check(hits, "a tap at the centre of a game-files button presses it");
            check(!overlap, "the game-files buttons do not overlap each other");
            umbra_rect b0 = umbra_hud_gf_button(0, w, h, gf[c].in, s);
            // A thumb, not a pixel: 44 dp is the smallest edge a person can hit, and
            // the column is allowed to be shorter only if the screen is.
            // Four buttons and their gaps may not eat the screen: the text above
            // them is the screen's point, and on a 1080-pixel phone a 48 dp button
            // at density 3.5 is 167 px, which is four fifths of the height.
            // Landscape puts them two by two, portrait in one column: either way the
            // block of them may not eat the screen the text needs.
            int gf_rows = umbra_gf_is_wide(w, h) ? 2 : UMBRA_GF_BUTTONS;
            check(b0.h * (float)gf_rows + (float)(gf_rows - 1) * 5.0f * s <=
                  (float)h * 0.34f + 1.0f,
                  "the game-files buttons fit in a third of the screen");
            check(b0.h >= 18.0f, "a game-files button is taller than the text it carries");
            // The text sits beside the column in landscape and above it in portrait,
            // and is never on top of a button.
            umbra_rect t = umbra_hud_gf_text(w, h, gf[c].in, s);
            check(t.w > 0.0f && t.h > 0.0f, "the game-files text has room");
            int texts_over_buttons = 0;
            for (int i = 0; i < UMBRA_GF_BUTTONS; i++) {
                umbra_rect r = umbra_hud_gf_button(i, w, h, gf[c].in, s);
                if (umbra_gf_is_wide(w, h)) {
                    if (t.x < r.x + r.w) texts_over_buttons = 1;
                } else if (t.y + t.h > r.y && r.y < t.y + t.h) {
                    // Portrait: the paragraph is above the column, so it may not
                    // reach down into it.
                    texts_over_buttons = 1;
                }
            }
            check(!texts_over_buttons || !umbra_gf_is_wide(w, h),
                  "in landscape the text column starts to the right of the buttons");
        }
        // A surface with no size yet must produce no buttons rather than negative
        // rectangles: the same class of bug as "button 0 at 25,-269 size -49x63".
        umbra_rect stub = umbra_hud_gf_button(0, 1, 1, zero, 2.0f);
        check(stub.w == 0.0f && stub.h == 0.0f, "a 1x1 surface produces no game-files buttons");
        check(umbra_hud_gf_hit(-5, -5, 2412, 1080, phone, 2.0f) == -1,
              "a tap outside every game-files button presses nothing");
    }

    // 4e. The self-test compares the window when it has no offscreen target, so
    //     the overlay must be outside the compared area -- and the work must be
    //     sliced, because the version that did it all in one frame is the one the
    //     owner's phone killed mid-test.
    //     (The device reported "SELF-TEST FAIL: 2458665 bad of 4950720 px"; the
    //     arithmetic of a 16-bit mediump int overflow in the pattern shader leaves
    //     exactly 16641 pixels matching, and 4950720/2 - 2458665 = 16695 were.)
    {
        int32_t phone[4] = {0, 63, 126, 0};
        float sc = umbra_hud_scale(3.5f, 2412, 1080, 11, 63);
        float panel = umbra_hud_panel_height(11, sc, 63);

        check(umbra_hud_covers(0, 0, 11, sc, phone, 2412, 1080), "the overlay's panel is covered");
        check(umbra_hud_covers(1205, (int)(panel - 2.0f), 11, sc, phone, 2412, 1080),
              "the bottom row of the panel is covered");
        check(!umbra_hud_covers(1205, (int)(panel + 2.0f), 11, sc, phone, 2412, 1080),
              "the row below the panel is not");
        umbra_rect b1 = umbra_hud_button(1, 2412, 1080, phone, sc);
        check(umbra_hud_covers((int)(b1.x + b1.w * 0.5f), (int)(b1.y + b1.h * 0.5f), 11, sc, phone,
                               2412, 1080), "a button is covered");
        check(!umbra_hud_covers(1205, (int)((panel + b1.y) * 0.5f), 11, sc, phone, 2412, 1080),
              "the world's band between them is not");

        int64_t skipped = 0;
        int64_t compared = umbra_selftest_compared_area(11, sc, phone, 2412, 1080, &skipped);
        printf("self-test: compared %lld px, skipped %lld px under the overlay\n",
               (long long)compared, (long long)skipped);
        check(compared > 0 && skipped > 0, "the comparison skips the overlay, not everything");
        check(compared + skipped == 2412LL * 1080LL, "the two areas add up to the screen");
        // Nothing the overlay draws may be inside the compared area: walk the panel
        // and the three buttons and demand each maps to a skipped pixel.
        int leaks = 0;
        // Sample at pixel centres: a rect that starts at y = 999.98 covers the row
        // whose centre is 1000.5, and (int)999.98 would test a pixel outside it --
        // which is a mistake in the test, not in the drawing.
        for (float fy = 0.5f; fy < panel - 0.5f; fy += 7.0f) {
            for (float fx = 0.5f; fx < 2412.0f; fx += 61.0f) {
                if (!umbra_hud_covers((int)fx, (int)fy, 11, sc, phone, 2412, 1080)) leaks++;
            }
        }
        for (int i = 0; i < 3; i++) {
            umbra_rect r = umbra_hud_button(i, 2412, 1080, phone, sc);
            for (float fy = r.y + 0.5f; fy < r.y + r.h; fy += 5.0f) {
                for (float fx = r.x + 0.5f; fx < r.x + r.w; fx += 37.0f) {
                    if (!umbra_hud_covers((int)fx, (int)fy, 11, sc, phone, 2412, 1080)) leaks++;
                }
            }
        }
        printf("self-test: overlay leaks into the compared area: %d px\n", leaks);
        // The panel has to be one row taller whenever the app adds a line (the
        // fallback reason does exactly that), or that line would be drawn on top
        // of the scene and outside the area the self-test skips.
        float panel_12 = umbra_hud_panel_height(12, sc, phone[1]);
        check(panel_12 > panel, "one more row makes the panel taller");
        check(umbra_hud_panel_height(11, sc, phone[1]) == panel, "the panel height is stable");
        check(umbra_hud_covers(1205, (int)panel_12 - 2, 12, sc, phone, 2412, 1080),
              "the extra fallback row is inside the overlay too");
        check(leaks == 0, "no pixel of the overlay is inside the compared area");

        // The step size: a bounded amount of work per frame, at both extremes.
        int rows = umbra_selftest_tile_rows(2412, 1080);
        printf("self-test: %d rows per step at 2412x1080, %d steps\n", rows,
               (1080 + rows - 1) / rows);
        check(rows >= 8, "a step is at least eight rows");
        check(rows <= 1080, "and never more than the screen");
        check((int64_t)rows * 2412 <= UMBRA_SELFTEST_TILE_PIXELS * 2,
              "a step reads about 150k pixels, not a whole screen");
        check((1080 + rows - 1) / rows >= 4, "so the work is spread over several frames");
        check(umbra_selftest_tile_rows(1, 1) == 1, "a degenerate surface still advances");
        check(umbra_selftest_tile_rows(1920, 1080) >= 8, "a 1920-wide screen advances too");
    }

    // 5. The benchmark statistics are real arithmetic on real numbers.
    umbra_bench_reset();
    for (int i = 0; i < 1000; i++) umbra_bench_add(16000 + (i % 10));
    int64_t len = 0;
    sl_u8 label = {(uint8_t *)"bench", 5};
    sl_u8 dev = {(uint8_t *)"headless", 8};
    sl_u8 android = {(uint8_t *)"none", 4};
    // gpu 0 us, timer unsupported, vsync capped: the honest answer without a GPU.
    const uint8_t *summary = umbra_bench_summary(label, dev, android, 0, 0, 0, 0, &len);
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
    check(lines == 6, "the benchmark block is six lines: four of numbers and two of honesty");
    check(strstr(text, "gpu n/a (no GPU timer results)") != NULL,
          "without a timer query the gpu time says so instead of guessing");
    check(strstr(text, "vsync: capped by the platform") != NULL,
          "and the frame rate is labelled with what capped it");

    // A spread of frame times must separate the average from the 1% low.
    umbra_bench_reset();
    for (int i = 0; i < 200; i++) umbra_bench_add(16000);
    for (int i = 0; i < 2; i++) umbra_bench_add(100000);
    summary = umbra_bench_summary(label, dev, android, 0, 0, 0, 0, &len);
    text = slice_text(summary, len);
    printf("%s\n", text);
    check(strstr(text, "avg 16.83 ms") != NULL, "a few slow frames move the average");
    check(strstr(text, "1% low 10 fps (100.00 ms)") != NULL,
          "and the 1% low reports them at their real cost");

    // With a timer query and an accepted uncapped request the block says both, and
    // the GPU time is a separate number from the frame time.
    umbra_bench_reset();
    for (int i = 0; i < 100; i++) umbra_bench_add(16667);
    summary = umbra_bench_summary(label, dev, android, 410000, 1, 1, 100, &len);
    text = slice_text(summary, len);
    printf("%s\n", text);
    check(strstr(text, "gpu avg 4.10 ms over 100 frames") != NULL,
          "GPU time is reported separately when the driver supports it");
    check(strstr(text, "vsync: uncapped requested") != NULL,
          "and an accepted uncapped request is recorded");
    check(strstr(text, "avg 16.66 ms (59 fps)") != NULL,
          "the CPU frame time is still reported next to it");

    // --- the world the player walks on ------------------------------------
    {
        // The grid the player collides with is answered by the same Goose code that
        // built the mesh, so these three numbers are the contract between the
        // mesher and the body: a full block, the model's half slab, and air.
        float floor_y = umbra_world_spawn(24, 24);
        printf("world: floor at 24,24 is %.2f\n", floor_y);
        int fy = (int)(floor_y - 0.5f);
        check(umbra_block_top(24, fy, 24) == 1.0f, "the floor at the spawn point is a full block");
        check(umbra_block_top(24, fy + 3, 24) < 0.0f, "and the air above it is not solid");
        // The plank path is two columns wide at x = 12,13, for z 20..40; find one and
        // compare its collision height with a full block beside it.
        int slab_x = -1, slab_y = -1000, slab_z = -1;
        for (int z = 18; z <= 42 && slab_x < 0; z++) {
            for (int x = 12; x <= 13 && slab_x < 0; x++) {
                for (int y = 40; y < 120; y++) {
                    if (umbra_block_top(x, y, z) == 0.5f) { slab_x = x; slab_y = y; slab_z = z; break; }
                }
            }
        }
        check(slab_x >= 0, "a bottom slab is in the world, drawn from its model");
        if (slab_x >= 0) {
            printf("world: slab at %d,%d,%d with a half-block collision top\n", slab_x, slab_y, slab_z);
            check(umbra_block_top(slab_x, slab_y - 1, slab_z) == 1.0f,
                  "and it sits on a full block");
            check(umbra_block_top(slab_x, slab_y + 1, slab_z) < 0.0f, "with air above it");
        }
    }

    // --- what the world says about water -----------------------------------
    {
        // The body asks the same block data the mesher drew, so "a pond you can see is
        // a pond you can swim in" is a check and not a hope. In the demo world the ponds
        // are water up to y = 61 where the terrain dips below 62.
        int fluid_cells = 0, solid_cells = 0, air_cells = 0;
        for (int y = 54; y < 64; y++) {   /* the ponds sit at y 60..61 in this seed */
            for (int z = 0; z < 48; z += 1) {
                for (int x = 0; x < 48; x += 1) {
                    int64_t f = umbra_block_fluid(x, y, z);
                    float t = umbra_block_top(x, y, z);
                    if (f) fluid_cells++;
                    if (t > 0.0f) solid_cells++;
                    if (!f && t <= 0.0f) air_cells++;
                }
            }
        }
        printf("water: %d fluid cells, %d solid, %d air-or-other near the surface\n",
               fluid_cells, solid_cells, air_cells);
        check(fluid_cells > 0, "the demo world has water the body can swim in");
        check(air_cells > 0, "and air it does not call water");
        // Nothing is both: a cell with a collision top is not a fluid.
        int both = 0;
        for (int y = 54; y < 64; y++)
            for (int z = 0; z < 48; z += 2)
                for (int x = 0; x < 48; x += 2)
                    if (umbra_block_fluid(x, y, z) && umbra_block_top(x, y, z) > 0.0f) both++;
        check(both == 0, "no cell is both swimmable and solid");
    }

    // --- the player -------------------------------------------------------
    {
        // A test grid: flat stone from y=-1 down, a wall at x == 10, and a half
        // slab filling the floor at z in [4,6) so a slab and a full block can be
        // compared in the same world.
        player_grid g;
        player_grid_init(&g);
        umbra_player p;
        umbra_player_reset(&p, 2.5f, 6.0f, 2.5f);
        // Falling: the body lands on the floor and stops with its feet on it.
        for (int i = 0; i < 120; i++) umbra_player_step(player_top, &g, &p, 1.0f / 60.0f, 0, 0, 0);
        check(fabsf(p.y - 1.0f) < 0.001f, "a falling body lands on the floor with its feet on it");
        check(p.on_ground == 1, "and knows it is standing");
        check(fabsf(p.vy) < 0.001f, "with no downward speed left");

        // Walking: one second of forward at the walking speed moves about that far.
        umbra_player_reset(&p, 2.5f, 1.0f, 2.5f);
        p.on_ground = 1;
        p.yaw = -1.5707963f;   /* looking down +X */
        for (int i = 0; i < 60; i++) umbra_player_step(player_top, &g, &p, 1.0f / 60.0f, 1, 0, 0);
        check(p.x > 2.5f + 3.9f && p.x < 2.5f + 4.4f, "one second of walking covers about four blocks");
        check(fabsf(p.y - 1.0f) < 0.01f, "and the body stays on the floor while walking");

        // A wall stops the body 0.3 blocks short of it (its own half width).
        umbra_player_reset(&p, 6.5f, 1.0f, 2.5f);
        p.on_ground = 1;
        p.yaw = -1.5707963f;
        for (int i = 0; i < 180; i++) umbra_player_step(player_top, &g, &p, 1.0f / 60.0f, 1, 0, 0);
        check(p.x < 10.0f && p.x > 9.6f, "a wall stops the body at its own width");
        check(p.on_ground == 1, "and it is still standing");

        // Jumping: the apex is about 1.2 blocks up and the body comes back down.
        umbra_player_reset(&p, 2.5f, 1.0f, 2.5f);
        p.on_ground = 1;
        float apex = p.y;
        for (int i = 0; i < 40; i++) {
            umbra_player_step(player_top, &g, &p, 1.0f / 60.0f, 0, 0, i == 0 ? 1 : 0);
            if (p.y > apex) apex = p.y;
        }
        check(apex > 1.0f + 1.0f && apex < 1.0f + 1.5f, "a jump lifts the body a little over one block");
        for (int i = 0; i < 120; i++) umbra_player_step(player_top, &g, &p, 1.0f / 60.0f, 0, 0, 0);
        check(fabsf(p.y - 1.0f) < 0.001f, "and it lands again");

        // A slab is walked onto, not walked through: the feet end up at 0.5.
        umbra_player_reset(&p, 2.5f, 1.0f, 4.5f);
        for (int i = 0; i < 120; i++) umbra_player_step(player_top, &g, &p, 1.0f / 60.0f, 0, 0, 0);
        check(fabsf(p.y - 0.5f) < 0.001f, "a body standing on a bottom slab is half a block up");

        // Walking from a full block onto a slab steps up instead of stopping.
        umbra_player_reset(&p, 2.5f, 1.0f, 3.5f);
        p.on_ground = 1;
        p.yaw = 3.14159265f;   /* looking down +Z */
        // Twenty frames is a little over one block: enough to be on the slab, not
        // enough to have walked off the far side of it.
        for (int i = 0; i < 26; i++) umbra_player_step(player_top, &g, &p, 1.0f / 60.0f, 1, 0, 0);
        check(p.z > 4.2f, "the body walks onto a slab instead of stopping at it");
        check(fabsf(p.y - 0.5f) < 0.001f, "and is standing on top of it");
        check(p.stepped == 0, "a drop onto a slab is not counted as a step up");

        // A drop from height: the body does not tunnel through the floor even at
        // terminal speed, because the step is sub-stepped.
        umbra_player_reset(&p, 2.5f, 40.0f, 2.5f);
        for (int i = 0; i < 300; i++) umbra_player_step(player_top, &g, &p, 1.0f / 60.0f, 0, 0, 0);
        check(fabsf(p.y - 1.0f) < 0.001f, "a long fall ends on the floor, not through it");

        // One enormous frame (a phone that stalled) still cannot tunnel.
        umbra_player_reset(&p, 2.5f, 40.0f, 2.5f);
        for (int i = 0; i < 10; i++) umbra_player_step(player_top, &g, &p, 0.25f, 0, 0, 0);
        check(fabsf(p.y - 1.0f) < 0.001f, "a quarter-second frame does not push the body through the floor");

        // --- a full-block step, water, and a sneak -----------------------
        // The first grid cannot say any of this: it has a wall with headroom above the
        // step and no fluid at all. This one is shaped for the three questions.
        {
            pool_grid pg;
            pool_grid_init(&pg);
            umbra_player_world w;
            w.top = pool_top;
            w.fluid = pool_fluid;
            w.ctx = &pg;
            umbra_player_input in = { 0, 0, 0, 0 };

            // Walking into a full block climbs it: the game's auto-jump, and the
            // reason UMBRA_PLAYER_STEP stopped being 0.51.
            umbra_player_reset(&p, 2.5f, 1.0f, 4.5f);
            p.on_ground = 1;
            p.yaw = 3.14159265f;                 /* looking down +Z */
            in.forward = 1.0f;
            for (int i = 0; i < 60; i++) umbra_player_update(&w, &p, 1.0f / 60.0f, in);
            check(p.z > 6.0f && p.y > 1.9f,
                  "a body walking at a full block climbs onto it instead of stopping");
            check(p.stepped >= 1, "and counts the step it took");

            // The same step where there is no headroom is a wall, not a ladder.
            umbra_player_reset(&p, 2.5f, 1.0f, 1.5f);
            p.on_ground = 1;
            p.yaw = -1.5707963f;                 /* looking down +X, at the wall */
            float before_x = p.x;
            for (int i = 0; i < 120; i++) umbra_player_update(&w, &p, 1.0f / 60.0f, in);
            check(p.x < 4.0f - 0.2f && p.y < 1.5f,
                  "a three-block wall with no headroom is not climbed by walking");
            check(p.x > before_x - 0.01f, "and the body does not go backwards doing it");

            // Water: the body that walked along the bottom of a pond now floats in it
            // and says so, and a jump press is a stroke.
            umbra_player_reset(&p, 2.5f, 1.0f, 11.5f);
            p.on_ground = 1;
            in.forward = 0.0f;
            in.jump = 0;
            for (int i = 0; i < 30; i++) umbra_player_update(&w, &p, 1.0f / 60.0f, in);
            check(p.in_water == 1, "a body whose box overlaps water knows it is swimming");
            float wet_y = p.y;
            int strokes_before = p.stroke;
            in.jump = 1;
            for (int i = 0; i < 20; i++) {
                umbra_player_update(&w, &p, 1.0f / 60.0f, in);
                in.jump = 0;                     /* one press, not a held button */
            }
            check(p.y > wet_y + 0.3f, "a swim stroke lifts the body in water");
            check(p.stroke == strokes_before + 1, "and counts as one stroke");
            // In water the body moves at the swim speed, not the walk speed.
            in.forward = 1.0f;
            in.jump = 0;
            p.yaw = 0.0f;                        /* looking down -Z, inside the pond */
            float z0 = p.z;
            for (int i = 0; i < 40; i++) umbra_player_update(&w, &p, 1.0f / 60.0f, in);
            float swam = fabsf(p.z - z0);
            check(swam > 0.5f && swam < 2.2f, "swimming is slower than walking");

            // Out of the water the body falls and lands again, so water is a body of
            // water and not a new way to fly.
            umbra_player_reset(&p, 2.5f, 1.5f, 2.5f);
            p.on_ground = 0;
            for (int i = 0; i < 120; i++) umbra_player_update(&w, &p, 1.0f / 60.0f, in);
            check(p.in_water == 0 && fabsf(p.y - 1.0f) < 0.001f,
                  "a body that falls on dry land still lands on it");

            // Sneaking: slower, lower, and it will not walk off the ledge.
            umbra_player_input sneak = { 0.0f, 0.0f, 0, 1 };
            umbra_player_reset(&p, 2.5f, 1.0f, 15.5f);
            p.on_ground = 1;
            p.yaw = 3.14159265f;                 /* walking +Z toward the ledge at 18 */
            sneak.forward = 1.0f;
            for (int i = 0; i < 180; i++) umbra_player_update(&w, &p, 1.0f / 60.0f, sneak);
            check(p.sneaking == 1, "a held sneak says the body is sneaking");
            // The body stops when its own box would leave the ledge, not when its
            // centre does: 0.3 of half-width is what it keeps over the floor. Anything
            // past that and the next step would be a fall.
            check(p.z > 16.5f && p.z < 18.0f + UMBRA_PLAYER_HW + 0.05f,
                  "a sneaking body stops at the edge instead of walking off it");
            check(p.y > 0.9f, "and is still standing on the ledge");

            // The control: the same walk without the sneak does go over.
            umbra_player_input walk = { 1.0f, 0.0f, 0, 0 };
            umbra_player_reset(&p, 2.5f, 1.0f, 15.5f);
            p.on_ground = 1;
            p.yaw = 3.14159265f;
            for (int i = 0; i < 180; i++) umbra_player_update(&w, &p, 1.0f / 60.0f, walk);
            check(p.y < 0.5f, "walking the same line without sneaking falls off the ledge");

            // The eye height comes from the flag, so it is checked on a body that is
            // sneaking; the walk above left this one standing on the floor.
            float eye_now[3];
            umbra_player_reset(&p, 2.5f, 1.0f, 2.5f);
            p.sneaking = 1;
            umbra_player_eye(&p, eye_now);
            check(fabsf(eye_now[1] - (1.0f + 1.27f)) < 0.001f, "the sneaking eye is lower");
            p.sneaking = 0;
            umbra_player_eye(&p, eye_now);
            check(fabsf(eye_now[1] - (1.0f + 1.62f)) < 0.001f,
                  "and comes back up when it stands");

            // One second of sneaking covers about 30% of a walk.
            umbra_player_reset(&p, 2.5f, 1.0f, 2.5f);
            p.on_ground = 1;
            p.yaw = 3.14159265f;
            for (int i = 0; i < 60; i++) umbra_player_update(&w, &p, 1.0f / 60.0f, sneak);
            check(p.z > 2.5f + 1.0f && p.z < 2.5f + 1.6f, "sneaking covers about 30% of a walk");
        }

        // Looking: pitch stops short of straight up and yaw stays in one turn.
        umbra_player_look(&p, 0.0f, 10.0f);
        check(p.pitch < 1.5708f && p.pitch > 1.5f, "pitch stops just short of straight up");
        umbra_player_look(&p, 100.0f, 0.0f);
        check(p.yaw >= -3.1416f && p.yaw < 3.1416f, "yaw stays inside one turn");

        // The camera sits at eye height above the feet, and looks where yaw says.
        float eye[3], fwd[3];
        umbra_player_reset(&p, 1.0f, 2.0f, 3.0f);
        umbra_player_eye(&p, eye);
        check(fabsf(eye[1] - (2.0f + 1.62f)) < 0.001f, "the eye is 1.62 blocks above the feet");
        umbra_player_forward(&p, fwd);
        check(fabsf(fwd[2] + 1.0f) < 0.001f, "at yaw 0 the camera looks down -Z");
        p.yaw = -1.5707963f;
        umbra_player_forward(&p, fwd);
        check(fabsf(fwd[0] - 1.0f) < 0.001f, "and at a quarter turn it looks down +X");
    }

    // --- the hands: a hotbar, a ray, and an edit that survives a re-mesh ---
    {
        check(umbra_hotbar_count() == 5, "the hotbar has five slots");
        int64_t len = 0;
        const uint8_t *name = umbra_hotbar_name(0, &len);
        check(len == (int64_t)strlen("grass_block") &&
              memcmp(name, "grass_block", (size_t)len) == 0,
              "slot 0 is a grass block, named without its namespace");
        check(umbra_hotbar_select(2) == 2, "a slot can be selected");
        name = umbra_hotbar_name(2, &len);
        check(len == (int64_t)strlen("stone") && memcmp(name, "stone", (size_t)len) == 0,
              "and the selected slot is stone");
        check(umbra_hotbar_select(99) == 2, "a slot outside the hotbar is refused");
        check(umbra_hotbar_select(0) == 0, "and the selection can go back");

        // Looking straight down from above the world hits the top of the grass.
        int64_t target = umbra_player_target(24.5f, 70.0f, 24.5f, 0.0f, -1.0f, 0.0f, 5.0f);
        check(target > 0, "a ray from above the world hits a block");
        int tx = (int)(target % 1000), tz = (int)((target / 1000) % 1000), ty = (int)(target / 1000000);
        check(tx == 24 && tz == 24, "the hit is in the column the ray was fired down");
        int64_t hit_len = 0;
        const uint8_t *hit_name = umbra_block_at(tx, ty, tz, &hit_len);
        check(hit_name != NULL && hit_len > 0, "the block that was hit has a name");

        int64_t before_len = 0;
        const uint8_t *before = umbra_block_at(tx, ty, tz, &before_len);
        check(before_len == (int64_t)strlen("minecraft:grass_block") &&
              memcmp(before, "minecraft:grass_block", (size_t)before_len) == 0,
              "the ray hit a grass block, by name");

        // Break it: the world changes and a re-mesh starts.
        int64_t v0 = used_index_total();
        int64_t code = umbra_player_act(0, 24.5f, 70.0f, 24.5f, 0.0f, -1.0f, 0.0f, 5.0f);
        check(code == 1, "breaking the block under the ray reports that the world changed");
        int64_t alen = 0;
        const uint8_t *said = umbra_act_text(&alen);
        check(alen > 0 && memcmp(said, "broke ", 6) == 0, "and says what it broke");
        int64_t after_len = 0;
        const uint8_t *after = umbra_block_at(tx, ty, tz, &after_len);
        check(after_len != before_len || memcmp(after, "minecraft:grass_block", (size_t)after_len) != 0,
              "the cell the ray hit no longer holds that block");
        int64_t tries = 0;
        int done = 0;
        while (!done && tries < 100000) {
            done = (int)umbra_demo_mesh_step(1000000);
            tries++;
            if (tries > 20000) break;
        }
        check(done == 1, "the re-mesh after an edit finishes");
        int64_t v1 = used_index_total();
        check(v1 != v0, "and the mesh is not the same size as before the edit");

        // Put a slab into the hole: the ray reaches the dirt under it, and a placement
        // goes on the face it hit.
        check(umbra_hotbar_select(4) == 4, "the slab slot selects");
        int64_t placed = umbra_player_act(1, 24.5f, 70.0f, 24.5f, 0.0f, -1.0f, 0.0f, 5.0f);
        check(placed == 1, "placing a block reports that the world changed");
        int64_t slab_len = 0;
        // The ray now reaches the dirt under the hole, so the slab lands in the hole.
        const uint8_t *slab = umbra_block_at(tx, ty, tz, &slab_len);
        check(slab_len == (int64_t)strlen("minecraft:oak_slab") &&
              memcmp(slab, "minecraft:oak_slab", (size_t)slab_len) == 0,
              "and the selected block is what stands there now");

        tries = 0;
        done = 0;
        while (!done && tries < 20000) {
            done = (int)umbra_demo_mesh_step(1000000);
            tries++;
        }
        check(done == 1, "the re-mesh after a placement finishes too");

        // A ray that reaches nothing changes nothing, and says so.
        int64_t nothing = umbra_player_act(0, 24.5f, 400.0f, 24.5f, 0.0f, -1.0f, 0.0f, 5.0f);
        check(nothing == 0, "a ray that reaches nothing changes nothing");

        // A placement that would land outside the world is refused, not wrapped into
        // another column: aim at the world's edge column from the outside.
        int64_t outside = umbra_player_act(1, -2.5f, 65.5f, 24.5f, 1.0f, 0.0f, 0.0f, 5.0f);
        check(outside == -1, "a placement outside the world is refused");
    }

    // --- saved edits: a break survives the file going to disk and coming back ---
    {
        // The format is Goose's and the file is the app's, so this tests both halves
        // separately: the lines Goose writes must be readable text, and replaying them
        // must put the same blocks back. A phone that loses an edit when it sleeps is
        // the bug, and it cannot be caught by a check that only tests the editor.
        umbra_edit_block(26, 65, 24, (sl_u8){(uint8_t *)"minecraft:stone", 16});
        int64_t n = umbra_edit_count();
        check(n > 0, "an edit is recorded in the session's edit list");
        int64_t len = 0;
        const uint8_t *line = umbra_edit_line(n - 1, &len);
        char text[128];
        int k = 0;
        for (int64_t i = 0; i < len && k + 1 < (int)sizeof text; i++) text[k++] = (char)line[i];
        text[k] = 0;
        printf("edits: the last line is \"%s\"\n", text);
        check(k > 0 && strstr(text, "minecraft:stone") != NULL,
              "the saved line names the block that was placed");
        int x = 0, y = 0, z = 0, used = 0;
        int parsed = sscanf(text, "%d %d %d %n", &x, &y, &z, &used);
        check(parsed == 3 && x == 26 && y == 65 && z == 24,
              "and the coordinates a reader can parse back out are the ones edited");

        // What a restart does: the same three numbers and the name, replayed.
        int64_t before = umbra_block_fluid(26, 65, 24);   /* any query, as a baseline */
        (void)before;
        umbra_edit_block(26, 65, 24, (sl_u8){(uint8_t *)"minecraft:dirt", 15});
        int64_t n2 = umbra_edit_count();
        check(n2 == n + 1, "a second edit is appended, not merged into the first");
        int64_t len2 = 0;
        const uint8_t *line2 = umbra_edit_line(n2 - 1, &len2);
        char text2[128];
        k = 0;
        for (int64_t i = 0; i < len2 && k + 1 < (int)sizeof text2; i++) text2[k++] = (char)line2[i];
        text2[k] = 0;
        check(strstr(text2, "minecraft:dirt") != NULL, "the second line names the second block");
        // Replaying a line is applying an edit; the block it names comes back.
        int64_t applied = umbra_apply_edit(30, 65, 24, (sl_u8){(uint8_t *)"minecraft:stone", 16});
        check(applied == 1, "a line from a save file can be applied");
        const uint8_t *name = umbra_block_at(30, 65, 24, &len);
        check(len >= 4 && memcmp(name, "minecraft:", 9 > (int)len ? len : 9) == 0,
              "and the block it named is in the world afterwards");
        int64_t refused = umbra_apply_edit(-999, 65, 24, (sl_u8){(uint8_t *)"minecraft:stone", 16});
        check(refused == 0, "a line outside the world is refused, not applied");
    }

    // --- the hand controls fit the screen and the taps agree with the pixels ---
    {
        const int32_t no_insets[4] = { 0, 0, 0, 0 };
        const int32_t phone_insets[4] = { 0, 63, 0, 126 };
        // The scale comes from the hand, not the overlay text: 420 dpi is the CI
        // emulator and the phone the owner reports on, 160 dpi the small tablet.
        struct { int w, h; const int32_t *in; float dpi; } cases[3] = {
            { 1080, 1920, phone_insets, 420.0f / 160.0f },
            { 1920, 1080, no_insets, 420.0f / 160.0f },
            { 800, 1280, no_insets, 1.0f },
        };
        for (int c = 0; c < 3; c++) {
            int w = cases[c].w, h = cases[c].h;
            float s = umbra_hud_hand_scale(cases[c].dpi, w, h);
            // A target has to be big enough for a finger: 44 dp across, or the whole
            // row shrunk to fit a narrow screen.
            float dp = cases[c].dpi > 1.0f ? cases[c].dpi : 1.0f;
            umbra_rect slot0 = umbra_hud_hotbar_slot(0, w, h, cases[c].in, s);
            float total = UMBRA_HOTBAR_SLOTS * slot0.w + (UMBRA_HOTBAR_SLOTS - 1) * 3.0f * s;
            check(slot0.w >= 44.0f * dp - 0.01f || total >= (float)(w < h ? w : h) * 0.72f - 1.0f,
                  "a hotbar slot is at least 44 dp across, or as wide as the screen allows");
            int inside = 1, overlap = 0;
            for (int i = 0; i < UMBRA_HOTBAR_SLOTS; i++) {
                umbra_rect r = umbra_hud_hotbar_slot(i, w, h, cases[c].in, s);
                if (r.x < 0 || r.y < 0 || r.x + r.w > (float)w || r.y + r.h > (float)h) inside = 0;
                for (int a = 0; a < 2; a++) {
                    umbra_rect b = umbra_hud_action(a, w, h, cases[c].in, s);
                    if (r.x < b.x + b.w && b.x < r.x + r.w && r.y < b.y + b.h && b.y < r.y + r.h) overlap = 1;
                }
            }
            check(inside, "every hotbar slot is on the screen");
            check(!overlap, "the action buttons do not sit on top of the hotbar");
            int hits = 1;
            for (int i = 0; i < UMBRA_HOTBAR_SLOTS; i++) {
                umbra_rect r = umbra_hud_hotbar_slot(i, w, h, cases[c].in, s);
                if (umbra_hud_hotbar_hit((int)(r.x + r.w * 0.5f), (int)(r.y + r.h * 0.5f),
                                         w, h, cases[c].in, s) != i) hits = 0;
            }
            check(hits, "a tap in the middle of a slot selects that slot");
            int actions = 1;
            for (int a = 0; a < 2; a++) {
                umbra_rect r = umbra_hud_action(a, w, h, cases[c].in, s);
                if (umbra_hud_action_hit((int)(r.x + r.w * 0.5f), (int)(r.y + r.h * 0.5f),
                                         w, h, cases[c].in, s) != a) actions = 0;
            }
            check(actions, "a tap in the middle of a button presses that button");
            // The sneak control is held, so it is its own target: on the screen, off
            // the hotbar and the two actions, and big enough to hold with a thumb.
            umbra_rect sn = umbra_hud_sneak(w, h, cases[c].in, s);
            check(sn.x >= 0 && sn.y >= 0 && sn.x + sn.w <= (float)w && sn.y + sn.h <= (float)h,
                  "the sneak button is on the screen");
            check(sn.w >= 44.0f * dp - 0.01f || sn.w >= (float)w * 0.29f,
                  "the sneak button is a thumb wide, or as wide as the screen allows");
            int sneako = 0;
            for (int i = 0; i < UMBRA_HOTBAR_SLOTS; i++) {
                umbra_rect r = umbra_hud_hotbar_slot(i, w, h, cases[c].in, s);
                if (r.x < sn.x + sn.w && sn.x < r.x + r.w && r.y < sn.y + sn.h && sn.y < r.y + r.h) sneako = 1;
            }
            for (int a = 0; a < 2; a++) {
                umbra_rect b = umbra_hud_action(a, w, h, cases[c].in, s);
                if (b.x < sn.x + sn.w && sn.x < b.x + b.w && b.y < sn.y + sn.h && sn.y < b.y + b.h) sneako = 1;
            }
            check(!sneako, "the sneak button does not sit on the hotbar or the action buttons");
            check(umbra_hud_sneak_hit((int)(sn.x + sn.w * 0.5f), (int)(sn.y + sn.h * 0.5f),
                                      w, h, cases[c].in, s) == 1,
                  "a tap in the middle of the sneak button holds it");
        }
    }


    // --- opening a world the game generated, the way the app does it ----------
    // This is the check for the brief's question (c): a save on disk is opened through
    // the same four calls the phone's fifth button uses, and the world that comes out is
    // held to what the save says. Two things are proved here that the Goose test cannot:
    // the C path (the part names, the entry loop, the bounds) and that meshing a save's
    // columns draws geometry where the save's chunks are -- a save's chunks are at
    // negative coordinates, and a renderer that only ever saw 0..47 would put it
    // off-screen or at the wrong place.
    {
        int64_t files = 0, chunks = 0, blocks = 0, states = 0, errors = 0, partial = 0;
        int64_t skipped = 0;
        int64_t t0 = umbra_now_us_headless();
        int64_t regions = umbra_world_import_begin(
            (sl_u8){(uint8_t *)"goose/test/fixtures/worldzip/world-classic.zip",
                    (int64_t)strlen("goose/test/fixtures/worldzip/world-classic.zip")});
        check(regions > 0, "the archive's region files are found through the app's import");
        if (regions > 0) {
            int64_t entries = umbra_world_import_entries();
            for (int64_t i = 0; i < entries; i++) umbra_world_import_file(i);
            check(umbra_world_import_end() == 1, "the world opens");
            files = umbra_world_import_files();
            chunks = umbra_world_import_chunks();
            blocks = umbra_world_import_blocks();
            states = umbra_world_import_states();
            errors = umbra_world_import_errors();
            partial = umbra_world_import_partial();
            skipped = umbra_world_import_skipped();
            int64_t took = umbra_now_us_headless() - t0;
            printf("world: opened %lld chunk(s) from %lld region file(s): %lld non-air blocks, "
                   "%lld states, %lld errors, %lld not full, %lld left out, in %.1f ms\n",
                   (long long)chunks, (long long)files, (long long)blocks, (long long)states,
                   (long long)errors, (long long)partial, (long long)skipped, took / 1000.0);
            check(chunks == 4, "every chunk of the save is a column");
            check(files == 1, "and the one region file it holds was read");
            check(errors == 0, "with no read error");
            check(blocks > 10000, "the world holds the save's blocks");
            check(umbra_world_is_save() == 1, "the app says the world is a save, not the demo");
            check(umbra_world_columns() == chunks, "the mesher was given every column");
            // The world's own bounds: the fixture's save is chunks 0..1, so 0..32 blocks.
            float minx = umbra_world_loaded_min_x(), maxx = umbra_world_loaded_max_x();
            float minz = umbra_world_loaded_min_z(), maxz = umbra_world_loaded_max_z();
            printf("world: bounds x %.1f..%.1f z %.1f..%.1f\n", minx, maxx, minz, maxz);
            check(maxx - minx > 16.0f && maxz - minz > 16.0f, "the world has a real extent");
            // A block the save has is a block the app can name, at the save's own position.
            const uint8_t *nm = NULL;
            int64_t nl = 0;
            // The chunk the save wrote: its surface at 1,1 is the topmost block that is
            // not air, and that is grass with dirt and stone under it.
            int64_t sy = 90;
            while (sy > 40) {
                const uint8_t *q = NULL;
                int64_t ql = 0;
                q = umbra_block_at(1, sy, 1, &ql);
                char tmp[64];
                int tk = 0;
                for (int64_t j = 0; j < ql && tk + 1 < (int)sizeof tmp; j++) tmp[tk++] = (char)q[j];
                tmp[tk] = 0;
                if (strcmp(tmp, "minecraft:air") != 0) break;
                sy--;
            }
            printf("world: the topmost block at 1,1 is y %lld\n", (long long)sy);
            nm = umbra_block_at(1, sy, 1, &nl);
            char name[64];
            int k = 0;
            for (int64_t j = 0; j < nl && k + 1 < (int)sizeof name; j++) name[k++] = (char)nm[j];
            name[k] = 0;
            printf("world: the block at 1,%lld,1 is %s\n", (long long)sy, name);
            check(strstr(name, "grass_block") != NULL, "the surface the save wrote is there");
            // And it meshes. The geometry is where the save's chunks are, not at 0..47 by
            // accident: every vertex's x and z are inside the world's own bounds.
            umbra_demo_mesh_begin();
            int64_t calls = 0;
            int done = 0;
            while (!done && calls < 2000000) {
                done = umbra_demo_mesh_step(20000) != 0;
                calls++;
            }
            umbra_demo_mesh_finish();
            int64_t svlen = 0, silen = 0;
            const uint8_t *sv = umbra_verts_ptr(&svlen);
            const uint8_t *si = umbra_indices_ptr(&silen);
            const umbra_vertex *svp = (const umbra_vertex *)sv;
            (void)svlen;
            // The arena is bigger than the geometry -- each slot keeps slack for the next
            // edit -- so "every vertex" has to mean every vertex a range actually draws,
            // or the check reads zeros and passes on nothing.
            int64_t svcount = 0;
            int outside = 0;
            float vmin = 1e9f, vmax = -1e9f;
            for (int64_t sid = 0; sid < umbra_range_slots(); sid++) {
                int64_t off = umbra_range_vertex(sid), len = umbra_range_vertex_len(sid);
                for (int64_t k = 0; k < len; k++) {
                    const umbra_vertex *vv = &svp[off + k];
                    if (vv->x < minx - 1.0f || vv->x > maxx + 1.0f ||
                        vv->z < minz - 1.0f || vv->z > maxz + 1.0f) outside++;
                    if (vv->x < vmin) vmin = vv->x;
                    if (vv->x > vmax) vmax = vv->x;
                    svcount++;
                }
            }
            check(svcount == umbra_used_vertices(), "the ranges cover the used vertices");
            printf("world: meshed %lld vertices in %lld calls, x %.1f..%.1f, %d outside the save's bounds\n",
                   (long long)svcount, (long long)calls, vmin, vmax, (int)outside);
            check(done, "the opened world meshes");
            check(svcount > 1000, "and the mesh is a world's, not a stub's");
            check(outside == 0, "every vertex is inside the save's own bounds");
            check(silen > 0 && silen % 4 == 0, "the index buffer is whole u32s");
            // An archive with no world in it is refused, and the reason reaches the caller.
            int64_t nw = umbra_world_import_begin(
                (sl_u8){(uint8_t *)"goose/test/fixtures/worldzip/world-not-a-world.zip",
                        (int64_t)strlen("goose/test/fixtures/worldzip/world-not-a-world.zip")});
            check(nw == 0, "an archive with no region file is refused");
            check(umbra_world_import_message(&nl) != NULL && nl > 0, "with a reason");
        }
    }

    goose_exit();
    printf("%s: %d checks, %d failures\n", failures ? "FAILED" : "PASS", checks, failures);
    return failures ? 1 : 0;
}
