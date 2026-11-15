// Umbra's Android/PC application shell: the C half of the engine.
//
// C owns the window, the EGL/GL context, input, files and JNI. Goose owns what
// the game does (formats, world data, meshing, the self-test's verdict, the
// benchmark statistics). The boundary is declared in umbra_core.h, generated
// from goose/main.goose.
#pragma once

#include <stdint.h>
#include <stdbool.h>

#ifdef __ANDROID__
#include <android/native_window.h>
#include <android/asset_manager.h>
#endif

#include "umbra_vertex.h"

typedef enum {
    UMBRA_SCREEN_HOME = 0,
    UMBRA_SCREEN_SELFTEST,
    UMBRA_SCREEN_BENCH,
    UMBRA_SCREEN_LOADING,
} umbra_screen;

// The app's own version, next to the git commit the build records. Bumped with
// the tag that publishes it (see .github/workflows/release.yml).
#define UMBRA_APP_VERSION "0.3.2"

// How much meshing a frame may do before it must draw and poll input again.
// Android starts warning about an unresponsive app after about five seconds; six
// milliseconds leaves the loop responsive by three orders of magnitude.
#define UMBRA_MESH_BUDGET_MS 6

typedef struct umbra_app umbra_app;

struct umbra_app {
    int32_t width, height;
    int32_t insets[4];        // left, top, right, bottom, in pixels
    float dpi_scale;

    // GL objects
    unsigned prog_mesh, prog_hud, prog_pattern, prog_cube;
    unsigned vao_mesh, vbo_mesh, ibo_mesh;
    unsigned vao_hud, vbo_hud, ibo_hud;
    unsigned vao_cube, vbo_cube, ibo_cube;
    unsigned vao_full;
    unsigned tex_font;

    // Demo scene, built and meshed by Goose
    int32_t vert_count, index_count;
    int64_t batch_start[3], batch_count[3];
    float center[3];
    // Extent of the demo mesh, in blocks, used to frame the camera and to set
    // a sane near/far range instead of a guess.
    float span[3];
    float cam_dist;
    float look[3];      // the point the home view is aimed at
    float eye[3];       // where the camera is; shown in the HUD and logged
    float fov_y;
    float fog_near, fog_far;        // vertical field of view, degrees

    // Runtime state
    umbra_screen screen;
    // The self-test renders into its own framebuffer: the window's back buffer
    // contents are undefined after a swap, and a readback of a fresh buffer
    // has to mean something.
    unsigned fbo_selftest, tex_selftest, rb_selftest;
    bool selftest_requested;
    // The self-test runs as a state machine, a bounded step per frame: two
    // full-frame readbacks and five million comparisons in one frame is a stall
    // long enough for Android to kill the app, which is what "SELF-TEST: BEGIN"
    // followed by silence was.
    int st_state;              // see the ST_* constants in umbra_app.c
    int64_t st_start_us;
    int st_w, st_h;            // the size the test ran at
    int st_row;                // first row of the next step
    int st_tile_rows;
    int st_offscreen;          // 1: the offscreen target was usable
    unsigned st_fbo_status;    // its status, for the log when it was not
    int64_t st_skip_px;        // pixels not compared because the overlay covers them
    int64_t st_pattern_bad, st_pattern_checked, st_cube_bad, st_cube_checked;
    unsigned char *st_frame;   // whole-frame readback, window fallback only
    unsigned char *st_tile;    // one step's readback
    size_t st_frame_bytes, st_tile_bytes;
    char st_reason[160];       // why the test was skipped, when it was
    char st_bad_text[128];     // the first mismatch, copied out of Goose
    int st_steps;              // steps taken, so the log can say how many

    // What the device answered at start-up, and what the app did about it.
    bool render_fallback;      // drawing without the full pipeline
    char fallback_reason[160];
    bool gpu_timer_supported;  // GL_EXT_disjoint_timer_query, i.e. real GPU time
    int gpu_timer_disjoint;   // a query result was thrown away after a GPU reset
    char gpu_timer_note[96];
    int64_t gpu_time_us;       // summed elapsed GPU time during the benchmark
    int64_t gpu_frames;        // frames that produced a GPU time
    int bench_vsync;           // 0 capped, 1 uncapped requested, 2 refused
    // Set by the platform: change the swap interval, returning 1 if it took.
    // Null when the platform has no such thing.
    int (*swap_interval_fn)(void *ctx, int interval);
    void *swap_interval_ctx;
    char gl_renderer[128], gl_vendor[128], gl_version[128];
    int depth_bits;
    char highp_vertex[32], highp_fragment[32];
    bool selftest_ran, selftest_ok;
    int64_t selftest_mismatches, selftest_checked, selftest_max_diff, selftest_first_bad;
    char selftest_text[192];

    bool benching;
    double bench_start_time;
    int bench_seconds;
    char bench_text[512];

    char status_text[256];
    char build_text[128];
    char log_path[512];
    char marker_path[512];
    char tail_text[1024];
    bool previous_run_crashed;

    // Meshing is time-sliced: the frame loop lends it a few milliseconds per
    // frame instead of blocking for seconds, so the activity never looks dead
    // enough for the system to show "app isn't responding".
    int mesh_state;            // 0 idle, 1 running, 2 done
    int mesh_progress;         // permille
    int64_t mesh_calls, mesh_worst_call_us, mesh_total_us;
    bool mesh_uploaded;

    // Frame timing
    double last_frame_time;
    int64_t frame_us;
    int64_t max_frame_us;      // the longest frame this run has drawn
    int64_t frames_drawn;
    int64_t long_frames;       // frames over 250 ms, i.e. visible stalls
    int64_t selftest_us;
    int32_t hud_logged_width;  // the width the HUD layout was last logged at
    int32_t draw_calls;        // batches actually drawn in the last frame
    int32_t last_run_lines;    // lines in last_run_text, 0 when there is none
    int32_t hud_rows_logged;   // the row count the fit was last logged for
    bool hud_fits;             // did the overlay's content fit inside its panel
    char last_run_text[320];   // the previous run's self-test and benchmark
    char selftest_path[256];   // where the last self-test verdict is kept
    char bench_path[256];      // where the last benchmark numbers are kept

#ifdef __ANDROID__
    ANativeWindow *window;
    void *java_vm;
    void *activity;       // ANativeActivity*
    int32_t touch_x, touch_y;
    bool touch_down;
#endif
};

// The app's own entry points, called by whichever platform shell is hosting it.
int umbra_app_init(umbra_app *app);
void umbra_app_shutdown(umbra_app *app);
// "running", "clean" or "suspended": the platform calls this when the app goes to
// the background and when it comes back, so that a swipe-away is not reported as
// a crash on the next start.
void umbra_session_set(umbra_app *app, const char *state);
void umbra_app_frame(umbra_app *app);
void umbra_app_touch(umbra_app *app, int32_t x, int32_t y, bool down);

// Implemented per platform.
void umbra_log(umbra_app *app, const char *fmt, ...);
void umbra_share_log(umbra_app *app);

int64_t umbra_now_us(void);
