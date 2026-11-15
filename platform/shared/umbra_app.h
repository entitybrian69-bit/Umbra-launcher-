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
#define UMBRA_APP_VERSION "0.3.0"

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

    // Runtime state
    umbra_screen screen;
    // The self-test renders into its own framebuffer: the window's back buffer
    // contents are undefined after a swap, and a readback of a fresh buffer
    // has to mean something.
    unsigned fbo_selftest, tex_selftest, rb_selftest;
    bool selftest_requested;
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
void umbra_app_frame(umbra_app *app);
void umbra_app_touch(umbra_app *app, int32_t x, int32_t y, bool down);

// Implemented per platform.
void umbra_log(umbra_app *app, const char *fmt, ...);
void umbra_share_log(umbra_app *app);

int64_t umbra_now_us(void);
