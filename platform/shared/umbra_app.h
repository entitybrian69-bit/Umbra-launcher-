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
#include "umbra_player.h"

typedef enum {
    UMBRA_SCREEN_HOME = 0,
    UMBRA_SCREEN_SELFTEST,
    UMBRA_SCREEN_BENCH,
    UMBRA_SCREEN_LOADING,
    // The screen a phone needs and an emulator never does: where the game's own
    // files come from. It is shown when no jar was found, and it is the only way a
    // phone can obtain one (download from Mojang, or import a file already there).
    UMBRA_SCREEN_GAMEFILES,
} umbra_screen;

// The app's own version, next to the git commit the build records. Bumped with
// the tag that publishes it (see .github/workflows/release.yml).
#define UMBRA_APP_VERSION "0.3.7"

// The brief's number: re-meshing after a break or a place must not hold a frame for
// more than about 50 ms, and the CI smoke test reads the same figure out of the log.
#define UMBRA_EDIT_BUDGET_MS 50

// How much meshing a frame may do before it must draw and poll input again -- for an
// edit *and* for the initial mesh. It used to be six milliseconds for loading; the
// device showed what that bought, and it was not a guarantee: the worst loading call
// was 45.4 ms (run 43968867039) because a unit is not interruptible, so the slice was
// a promise the code could not keep.
//
// The budget is now set so the *hard* ceiling, UMBRA_EDIT_BUDGET_MS, is one the code
// can actually meet: a call may overrun its slice by one unit, and a unit on the
// device is up to ~6 ms, so 20 + 6 is still inside 50. A 50 ms slice would not be:
// the host suite measured 52.33 ms for it, which is over the number the brief names.
#define UMBRA_MESH_BUDGET_MS 20
// A call may overrun the slice by one unit; the device's worst unit is ~6 ms and the
// host's 7.45 ms, both inside the headroom this leaves (20 + 30 = 50).
#define UMBRA_MESH_UNIT_ALLOWANCE_MS (UMBRA_EDIT_BUDGET_MS - UMBRA_MESH_BUDGET_MS)

typedef struct umbra_app umbra_app;

struct umbra_app {
    int32_t width, height;
    int32_t insets[4];        // left, top, right, bottom, in pixels
    float dpi_scale;

    // GL objects
    unsigned prog_mesh, prog_hud, prog_pattern, prog_cube, prog_atlas;
    unsigned vao_mesh, vbo_mesh, ibo_mesh;
    unsigned vao_hud, vbo_hud, ibo_hud;
    unsigned vao_cube, vbo_cube, ibo_cube;
    unsigned vao_full;
    unsigned tex_font;

    // Demo scene, built and meshed by Goose
    int32_t vert_count, index_count;
    // Indices per pass, summed over the ranges. The world is drawn and uploaded per
    // range now (one per pass and column), so there is no single start per pass.
    int64_t batch_count[3];
    int64_t uploaded_vlen, uploaded_ilen;   // bytes the GPU holds, for sub-uploads
    float center[3];
    // Extent of the demo mesh, in blocks, used to frame the camera and to set
    // a sane near/far range instead of a guess.
    float span[3];
    float cam_dist;
    // The player. `player_on` switches the camera from the fixed overview to the
    // body's eyes; the overview stays the default so the screenshot gate keeps a
    // fixed view, and the state is logged whenever it changes.
    umbra_player player;
    int player_on;
    int move_fwd, move_back, move_left, move_right, jump_wanted;
    int touch_look_id;      // the pointer dragging the view, or -1
    int touch_walk_id;      // the pointer holding "walk forward", or -1
    float touch_last_x, touch_last_y;
    int touch_moved;        // this finger has turned the head instead of resting
    int64_t touch_down_us;
    int64_t player_logged_us;
    // The hotbar and the two action buttons. `act_wanted` is what a tap asked for (0
    // break, 1 place, -1 nothing) and is consumed once per frame; `act_text` is what
    // Goose said it did, printed in the overlay and logged, so a phone report says
    // "broke grass_block at 24 65 24" instead of "nothing happened".
    int hotbar_sel;
    int act_wanted;
    char act_text[96];
    int act_edits;              // how many blocks were changed this session
    int tap_used;               // this finger was answered by a control, not the world
    int hands_logged_width;     // the width the hand controls' rects were logged at
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
    int st_atlas_bad;          // texels of the sampled tile that came back wrong
    int st_atlas_checked;
    int st_atlas_slot;
    char st_reason[160];       // why the test was skipped, when it was
    char st_bad_text[128];     // the first mismatch, copied out of Goose
    int st_steps;              // steps taken, so the log can say how many

    // What the device answered at start-up, and what the app did about it.
    unsigned atlas_tex;        // the block atlas, one texture for the world
    int atlas_size;            // its width and height in texels
    unsigned atlas_hash;       // what the packer produced, for the log
    int atlas_missing;         // blocks that asked for a tile the build has not
    int atlas_uploads;         // times the atlas reached the GPU
    // Where the pixels and the models came from. A client jar, when one was found,
    // replaces the placeholder set: the atlas is the jar's own textures and the mesher
    // asks the jar's own models. `jar_code` is the loader's answer (1 loaded, negative
    // why not), so the log can say which of the two the picture on screen uses.
    char jar_path[512];
    int jar_code;
    // The "get game files" screen: which state it is in, what it last said, and
    // whether the work it asked for is running. `gf_download` is 1 while Java is
    // streaming the jar and 2 while a picked document is being copied; the frame
    // loop polls the platform for progress and never blocks on it.
    int gf_state;              // 0 idle, 1 downloading, 2 checking, 3 ready, 4 failed, 5 imported
    int gf_job;                // 1 download, 2 import, 0 nothing
    int gf_done;               // the job finished, one frame of handling left
    int gf_quit;               // a button asked to close the screen
    char gf_text[192];         // the headline, from Goose (core/gamefiles.goose)
    char gf_detail[192];       // the second line: a number, a reason, or a path
    long long gf_got, gf_total;  // bytes, for the bar and the log
    char files_dir[512];       // where client.jar goes, from the platform
    // Set by the platform shell: run the download / pick a file. Both return when
    // the job is over, and write the number of bytes into *got. Null on a platform
    // with no way to do it (the PC host), which the screen says out loud.
    int (*download_fn)(void *ctx, const char *url, const char *dest, long long *got);
    int (*pick_file_fn)(void *ctx, const char *dest, const char *mime, long long *got);
    void (*progress_fn)(void *ctx, long long *got, long long *total);
    void *net_ctx;
    char gf_url[512];          // where the jar comes from, from Goose's version JSON
    char gf_platform_error[160];  // the last thing the platform's job said
    int gf_logged_width;       // the width the screen's buttons were logged at
    int gf_adopt;              // a verified jar is waiting to be loaded
    int gf_pending_open;       // open the screen as soon as the surface is real
    bool jar_loaded;
    int jar_models, jar_blockstates, jar_textures, jar_textures_missing;
    long long jar_bytes;
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
    int64_t upload_us;         // the one whole-arena upload, timed on its own
    int64_t last_draw_us;      // the scene draw, timed every frame
    int first_draw_timed;      // the first world frame has been timed and logged
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
// Which screen the app is on. Setting it logs the change, because a screen that
// changed without a line in the log is a screen nobody can explain later.
void umbra_app_set_screen(umbra_app *app, int screen);
// Opens the "get game files" screen: it asks Goose where the jar goes, logs what it
// is about to offer, and marks the screen. Called at start-up when no jar was found
// and from the home screen's button when the owner wants a different one.
void open_gamefiles_screen(umbra_app *app);
void close_gamefiles_screen(umbra_app *app);
void umbra_app_shutdown(umbra_app *app);
// "running", "clean" or "suspended": the platform calls this when the app goes to
// the background and when it comes back, so that a swipe-away is not reported as
// a crash on the next start.
void umbra_session_set(umbra_app *app, const char *state);
void umbra_app_frame(umbra_app *app);
void umbra_app_touch(umbra_app *app, int32_t x, int32_t y, bool down);
// The same, with the pointer's id and its whole life: 0 down, 1 move, 2 up,
// 3 cancel. A phone reports several pointers at once and only this version can see
// the one that is dragging while another one holds "walk".
void umbra_app_touch_id(umbra_app *app, int32_t id, int32_t x, int32_t y, int32_t phase);

// Implemented per platform.
void umbra_log(umbra_app *app, const char *fmt, ...);
void umbra_share_log(umbra_app *app);

int64_t umbra_now_us(void);
