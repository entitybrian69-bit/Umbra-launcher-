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

// The vertex layout Goose emits: 12 packed f32 per vertex (48 bytes).
// Mirror of `struct Vertex` in goose/core/mesh.goose.
typedef struct __attribute__((packed)) {
    float x, y, z;
    float nx, ny, nz;
    float u, v;
    float r, g, b;
    float ao;
} umbra_vertex;

typedef enum {
    UMBRA_SCREEN_HOME = 0,
    UMBRA_SCREEN_SELFTEST,
    UMBRA_SCREEN_BENCH,
    UMBRA_SCREEN_LOADING,
} umbra_screen;

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

    // Runtime state
    umbra_screen screen;
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

    // Frame timing
    double last_frame_time;
    int64_t frame_us;
    int64_t frames_drawn;

#ifdef __ANDROID__
    ANativeWindow *window;
    void *java_vm;
    void *activity;       // ANativeActivity*
    int32_t touch_x, touch_y;
    bool touch_down;
#endif
};

// Implemented per platform.
void umbra_log(umbra_app *app, const char *fmt, ...);
void umbra_share_log(umbra_app *app);

int64_t umbra_now_us(void);
