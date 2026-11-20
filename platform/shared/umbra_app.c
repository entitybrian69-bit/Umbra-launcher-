// Umbra's application shell: EGL/GLES3 setup, the render pass graph, the HUD,
// the GPU self-test, the 60-second benchmark, the crash marker and the log.
//
// Game logic is not here: it is in goose/ and reached through umbra_core.h.
// This file draws and measures.
#include "umbra_app.h"
#include "umbra_results.h"
#include "umbra_camera.h"
#include "umbra_vertex.h"
#include "umbra_font.h"
#include "umbra_hud.h"
#include "umbra_selftest.h"
#include "umbra_core.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Defined further down, used by umbra_app_init and the frame loop.
static void set_run_paths(umbra_app *app);
static void load_last_run(umbra_app *app);
static void camera_eye(const umbra_app *app, float eye[3]);
// The game-files screen's helpers: the screen is opened from init, which is above
// their definitions.
static void gf_copy(umbra_app *app, const uint8_t *text, int64_t len, char *dst, size_t cap);
static void gf_say(umbra_app *app, int kind, long long now, long long total, const char *extra);
static void begin_scene(umbra_app *app);
static void upload_atlas(umbra_app *app);
static void gf_pump(umbra_app *app);
static void world_job_start(umbra_app *app);
static void world_pump(umbra_app *app);
static void rebuild_world(umbra_app *app);
static void stream_start(umbra_app *app, int cx, int cz, int radius);
static void stream_maybe_recentre(umbra_app *app);
static void world_sample_download_start(umbra_app *app);
static int file_exists_at(const char *path);
static void delete_file_at(const char *path);
static int world_open_path(umbra_app *app, const char *path, const char *how);
#include <stdarg.h>
#include <time.h>
#include <math.h>

#ifdef __ANDROID__
#include <GLES3/gl3.h>
#include <EGL/egl.h>
#include <pthread.h>
#include <android/log.h>
#define LOG_TAG "umbra"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#else
#include <GLES3/gl3.h>
#define LOGE(...) fprintf(stderr, __VA_ARGS__)
#define LOGI(...) fprintf(stdout, __VA_ARGS__)
#endif

#ifndef UMBRA_GIT_COMMIT
#define UMBRA_GIT_COMMIT "unknown"
#endif

int64_t umbra_now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

// --- logging ------------------------------------------------------------

static FILE *g_log = NULL;

static void log_open(umbra_app *app) {
    if (g_log) return;
    g_log = fopen(app->log_path, "ab");
    if (!g_log) LOGE("cannot open log %s\n", app->log_path);
}

void umbra_log(umbra_app *app, const char *fmt, ...) {
    // Where the previous run's results live: next to the log, one line each.
    // Computed once, in init, so that the read at start-up happens after the
    // paths exist -- it used to happen before, which is why the first run of
    // 0.3.1 saved its results and then reported "nothing recorded yet".
    if (!app->selftest_path[0]) set_run_paths(app);

    log_open(app);
    char line[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    time_t t = time(NULL);
    struct tm tmv;
#ifdef _WIN32
    localtime_s(&tmv, &t);
#else
    localtime_r(&t, &tmv);
#endif
    char stamp[32];
    strftime(stamp, sizeof stamp, "%H:%M:%S", &tmv);
    if (g_log) {
        fprintf(g_log, "%s %s\n", stamp, line);
        fflush(g_log);
    }
    LOGI("%s %s\n", stamp, line);
    // Keep the last few lines for the on-screen tail.
    int len = (int)strlen(app->tail_text);
    if (len > 700) {
        // Drop the oldest line.
        char *nl = strchr(app->tail_text, '\n');
        if (nl) {
            memmove(app->tail_text, nl + 1, strlen(nl + 1) + 1);
            len = (int)strlen(app->tail_text);
        }
    }
    snprintf(app->tail_text + len, sizeof app->tail_text - len, "%s\n", line);
}

// --- shaders ------------------------------------------------------------

static GLuint compile_shader(GLenum type, const char *src, char *err, size_t errlen) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        GLint len = 0;
        glGetShaderiv(s, GL_INFO_LOG_LENGTH, &len);
        if (len > 0 && (size_t)len < errlen) glGetShaderInfoLog(s, len, NULL, err);
        else snprintf(err, errlen, "shader compile failed (no info log)");
        glDeleteShader(s);
        return 0;
    }
    err[0] = 0;
    return s;
}

static GLuint link_program(const char *vs, const char *fs, char *err, size_t errlen) {
    char verr[512] = {0}, ferr[512] = {0};
    GLuint v = compile_shader(GL_VERTEX_SHADER, vs, verr, sizeof verr);
    if (!v) { snprintf(err, errlen, "vertex: %s", verr); return 0; }
    GLuint f = compile_shader(GL_FRAGMENT_SHADER, fs, ferr, sizeof ferr);
    if (!f) { snprintf(err, errlen, "fragment: %s", ferr); glDeleteShader(v); return 0; }
    GLuint p = glCreateProgram();
    glAttachShader(p, v);
    glAttachShader(p, f);
    glLinkProgram(p);
    GLint ok = 0;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) {
        GLint len = 0;
        glGetProgramiv(p, GL_INFO_LOG_LENGTH, &len);
        if (len > 0 && (size_t)len < errlen) glGetProgramInfoLog(p, len, NULL, err);
        else snprintf(err, errlen, "link failed (no info log)");
        glDeleteProgram(p);
        glDeleteShader(v);
        glDeleteShader(f);
        return 0;
    }
    glDeleteShader(v);
    glDeleteShader(f);
    err[0] = 0;
    return p;
}

// The pass graph. Stage 2 extends it with shadow/opaque/cutout/translucent/post/
// final and Stage 9 with shader-pack passes; the order is fixed here from the
// start so that extension does not mean a rewrite.
typedef enum {
    PASS_SHADOW = 0,
    PASS_OPAQUE,
    PASS_CUTOUT,
    PASS_TRANSLUCENT,
    PASS_POST,
    PASS_FINAL,
    PASS_COUNT,
} umbra_pass;

// Defined further down, used by the init path and the atlas upload above it.
static void set_fallback(umbra_app *app, const char *reason);
static void upload_atlas(umbra_app *app);

static const char *VS_MESH =
    "#version 300 es\n"
    "layout(location=0) in vec3 a_pos;\n"
    "layout(location=1) in vec3 a_nrm;\n"
    "layout(location=2) in vec2 a_uv;\n"
    "layout(location=3) in vec3 a_col;\n"
    "layout(location=4) in float a_ao;\n"
    "uniform mat4 u_viewproj;\n"
    "uniform vec3 u_center;\n"
    "out vec3 v_col;\n"
    "out vec2 v_uv;\n"
    "out float v_dist;\n"
    "void main() {\n"
    "    vec3 p = a_pos - u_center;\n"
    "    v_col = a_col;  // face shade, ambient occlusion and block tint, baked in\n"
    "    v_uv = a_uv;\n"
    "    v_dist = length(p);\n"
    "    gl_Position = u_viewproj * vec4(p, 1.0);\n"
    "}\n";

// The world is one atlas texture. highp on the sampler coordinates is not
// optional: at 1280 texels wide a mediump float has ~2 texels of precision, and
// the owner's phone is the device that taught this project what a default
// precision costs (DECISIONS.md D-038).
//
// The cutout pass discards fully transparent fragments instead of blending them,
// so leaves and plants have holes and still write depth; the translucent pass
// blends. `u_cutout` is 1 for the first and 0 for the second -- one program, so a
// shader that fails to link fails once.
static const char *FS_MESH =
    "#version 300 es\n"
    "precision highp float;\n"
    "precision highp int;\n"
    "in vec3 v_col;\n"
    "in vec2 v_uv;\n"
    "in float v_dist;\n"
    "uniform sampler2D u_atlas;\n"
    "uniform vec2 u_fog;\n"
    "uniform int u_cutout;\n"
    "out vec4 o_col;\n"
    "void main() {\n"
    "    vec4 t = texture(u_atlas, v_uv);\n"
    "    if (u_cutout == 1 && t.a < 0.5) discard;\n"
    "    float fog = clamp((v_dist - u_fog.x) / (u_fog.y - u_fog.x), 0.0, 1.0);\n"
    "    vec3 sky = vec3(0.55, 0.70, 0.92);\n"
    "    o_col = vec4(mix(t.rgb * v_col, sky, fog), t.a);\n"
    "}\n";

// The atlas sampler the self-test draws with. It is a separate program on
// purpose: it reads the *production* texture through the *production* sampler
// state (NEAREST magnification, CLAMP_TO_EDGE, mipmaps generated), and paints the
// 16x16 texels of one tile into the bottom-left 16x16 pixels of the target, one
// texel per pixel. The comparison then has 256 exact values to check.
static const char *FS_ATLAS =
    "#version 300 es\n"
    "precision highp float;\n"
    "precision highp int;\n"
    "uniform sampler2D u_atlas;\n"
    "uniform vec4 u_rect;\n"       // u0, v0, u1, v1 of the tile
    "out vec4 o_col;\n"
    "void main() {\n"
    "    vec2 p = floor(gl_FragCoord.xy);\n"
    "    if (p.x >= 16.0 || p.y >= 16.0) { o_col = vec4(0.0, 0.0, 0.0, 1.0); return; }\n"
    "    vec2 t = (p + 0.5) / 16.0;\n"
    "    vec2 uv = vec2(mix(u_rect.x, u_rect.z, t.x), mix(u_rect.y, u_rect.w, t.y));\n"
    "    o_col = texture(u_atlas, uv);\n"
    "}\n";

static const char *VS_HUD =
    "#version 300 es\n"
    "layout(location=0) in vec2 a_pos;\n"
    "layout(location=1) in vec2 a_uv;\n"
    "layout(location=2) in vec4 a_col;\n"
    "uniform vec2 u_screen;\n"
    "out vec2 v_uv;\n"
    "out vec4 v_col;\n"
    "void main() {\n"
    "    vec2 p = vec2(a_pos.x / u_screen.x * 2.0 - 1.0, 1.0 - a_pos.y / u_screen.y * 2.0);\n"
    "    v_uv = a_uv; v_col = a_col;\n"
    "    gl_Position = vec4(p, 0.0, 1.0);\n"
    "}\n";

static const char *FS_HUD =
    "#version 300 es\n"
    "precision highp float;\n"
    "in vec2 v_uv;\n"
    "in vec4 v_col;\n"
    "uniform sampler2D u_tex;\n"
    "out vec4 o_col;\n"
    "void main() {\n"
    "    vec4 t = texture(u_tex, v_uv);\n"
    "    o_col = vec4(v_col.rgb, v_col.a * t.r);\n"  // the font atlas is coverage in red
    "}\n";

static const char *VS_FULL = 
    "#version 300 es\n"
    "layout(location=0) in vec2 a_pos;\n"
    "void main() { gl_Position = vec4(a_pos, 0.0, 1.0); }\n";

static const char *FS_PATTERN =
    "#version 300 es\n"
    "precision highp float;\n"
    // highp int is not the default in a fragment shader -- int is mediump, which
    // is 16 bits on Mali. x * 255 overflows past x = 128, and the owner's phone
    // reported "SELF-TEST FAIL: 2458665 bad of 4950720 px": 2475360 minus exactly
    // the 16695 pixels where neither x nor y reached the overflow.
    "precision highp int;\n"
    "uniform int u_w;\n"
    "uniform int u_h;\n"
    "out vec4 o_col;\n"
    "void main() {\n"
    // Must match pattern_expected() in goose/main.goose.
    "    int x = int(gl_FragCoord.x);\n"
    "    int y = int(gl_FragCoord.y);\n"
    "    int u = (x * 255) / max(u_w - 1, 1);\n"
    "    int v = (y * 255) / max(u_h - 1, 1);\n"
    "    o_col = vec4(float((u ^ v) & 255) / 255.0, float((u + v) & 255) / 255.0, 64.0 / 255.0, 1.0);\n"
    "}\n";

static const char *VS_CUBE =
    "#version 300 es\n"
    "layout(location=0) in vec3 a_pos;\n"
    "layout(location=1) in vec3 a_col;\n"
    "uniform mat4 u_viewproj;\n"
    "out vec3 v_col;\n"
    "void main() { v_col = a_col; gl_Position = u_viewproj * vec4(a_pos, 1.0); }\n";

static const char *FS_CUBE =
    "#version 300 es\n"
    "precision highp float;\n"
    "in vec3 v_col;\n"
    "out vec4 o_col;\n"
    "void main() { o_col = vec4(v_col, 1.0); }\n";

// --- matrices (column-major, as GL wants them) --------------------------
//
// The traps in the brief live here: a transposed upload, a wrong depth range or
// a row-major layout all show up as a self-test failure, which is why the cube
// test exists.

static void mat4_identity(float *m) {
    memset(m, 0, 16 * sizeof(float));
    m[0] = m[5] = m[10] = m[15] = 1.0f;
}

static void mat4_perspective(float *m, float fovy_rad, float aspect, float znear, float zfar) {
    float f = 1.0f / (float)tan(fovy_rad * 0.5);
    memset(m, 0, 16 * sizeof(float));
    m[0] = f / aspect;
    m[5] = f;
    m[10] = (zfar + znear) / (znear - zfar);
    m[11] = -1.0f;
    m[14] = (2.0f * zfar * znear) / (znear - zfar);
}

static void mat4_mul(float *out, const float *a, const float *b) {
    // out = a * b, both column-major.
    for (int c = 0; c < 4; c++) {
        for (int r = 0; r < 4; r++) {
            float sum = 0;
            for (int k = 0; k < 4; k++) sum += a[k * 4 + r] * b[c * 4 + k];
            out[c * 4 + r] = sum;
        }
    }
}

static void mat4_look_at(float *m, const float eye[3], const float target[3], const float up[3]) {
    float f[3] = {target[0] - eye[0], target[1] - eye[1], target[2] - eye[2]};
    float fl = sqrtf(f[0]*f[0] + f[1]*f[1] + f[2]*f[2]);
    if (fl < 1e-6f) fl = 1.0f;
    f[0] /= fl; f[1] /= fl; f[2] /= fl;
    float s[3] = {f[1]*up[2] - f[2]*up[1], f[2]*up[0] - f[0]*up[2], f[0]*up[1] - f[1]*up[0]};
    float sl = sqrtf(s[0]*s[0] + s[1]*s[1] + s[2]*s[2]);
    if (sl < 1e-6f) { s[0] = 1; s[1] = 0; s[2] = 0; sl = 1; }
    s[0] /= sl; s[1] /= sl; s[2] /= sl;
    float u[3] = {s[1]*f[2] - s[2]*f[1], s[2]*f[0] - s[0]*f[2], s[0]*f[1] - s[1]*f[0]};
    memset(m, 0, 16 * sizeof(float));
    m[0] = s[0]; m[4] = s[1]; m[8] = s[2];
    m[1] = u[0]; m[5] = u[1]; m[9] = u[2];
    m[2] = -f[0]; m[6] = -f[1]; m[10] = -f[2];
    m[12] = -(s[0]*eye[0] + s[1]*eye[1] + s[2]*eye[2]);
    m[13] = -(u[0]*eye[0] + u[1]*eye[1] + u[2]*eye[2]);
    m[14] = (f[0]*eye[0] + f[1]*eye[1] + f[2]*eye[2]);
    m[15] = 1.0f;
}

// --- HUD ----------------------------------------------------------------

typedef struct {
    float x, y, u, v, r, g, b, a;
} hud_vert;

static hud_vert *g_hud_verts = NULL;
static int g_hud_count = 0;
static int g_hud_cap = 0;

static void hud_begin(void) { g_hud_count = 0; }

static void hud_reserve(int n) {
    if (g_hud_count + n <= g_hud_cap) return;
    int cap = g_hud_cap ? g_hud_cap * 2 : 4096;
    while (cap < g_hud_count + n) cap *= 2;
    g_hud_verts = (hud_vert *)realloc(g_hud_verts, cap * sizeof(hud_vert));
    g_hud_cap = cap;
}

static void hud_quad(float x, float y, float w, float h, float u0, float v0, float u1, float v1,
                     float r, float g, float b, float a) {
    hud_reserve(4);
    hud_vert v[4] = {
        {x, y, u0, v0, r, g, b, a},
        {x + w, y, u1, v0, r, g, b, a},
        {x + w, y + h, u1, v1, r, g, b, a},
        {x, y + h, u0, v1, r, g, b, a},
    };
    memcpy(g_hud_verts + g_hud_count, v, sizeof v);
    g_hud_count += 4;
}

// Flat rectangles sample one reserved opaque texel of the glyph atlas. Sampling
// (0,0) -- the first pixel of the space glyph -- made every panel and button
// background fully transparent, which is why the 0.3.0 home screen had text
// floating in the sky with nothing behind it.
#define HUD_WHITE_U (127.5f / 128.0f)
#define HUD_WHITE_V (63.5f / 64.0f)

static void hud_rect(float x, float y, float w, float h, float r, float g, float b, float a) {
    hud_quad(x, y, w, h, HUD_WHITE_U, HUD_WHITE_V, HUD_WHITE_U, HUD_WHITE_V, r, g, b, a);
}

static void hud_text(float x, float y, float scale, float cr, float cg, float cb, float ca,
                     const char *text) {
    // The font texture is 16x8 cells of 8x8 texels: 128x64 texels total.
    const float cell = 1.0f / 16.0f;
    const float row = 1.0f / 8.0f;
    float cx = x;
    for (const char *p = text; *p; p++) {
        unsigned char c = (unsigned char)*p;
        if (c == '\n') {
            // Multi-line HUD text: the benchmark block needs separate lines to
            // stay readable on a phone.
            cx = x;
            y += 12.0f * scale;
            continue;
        }
        if (c < 32 || c > 126) c = '?';
        int gi = c - 32;
        float u0 = (gi % 16) * cell;
        float v0 = (gi / 16) * row;
        if (c != ' ') {
            hud_quad(cx, y, 8.0f * scale, 8.0f * scale, u0, v0, u0 + cell, v0 + row, cr, cg, cb, ca);
        }
        cx += 6.0f * scale;
    }
}

static float hud_text_width(const char *text, float scale) {
    return (float)strlen(text) * 6.0f * scale;
}

// --- last run -----------------------------------------------------------
//
// One screenshot should be enough to see how the app behaved last time: the
// self-test verdict and the benchmark numbers are written to two one-line files
// as they happen, read back at start-up, and shown in the overlay.

// Where the two result files live: beside the log, one line each. Called from
// init, before the start-up read, and again by umbra_log if the platform set the
// log path late.
static void set_run_paths(umbra_app *app) {
    umbra_result_path(app->log_path, "last_selftest.txt", app->selftest_path, sizeof app->selftest_path);
    umbra_result_path(app->log_path, "last_bench.txt", app->bench_path, sizeof app->bench_path);
}

// Read both result files into the block the HUD draws.
static void load_last_run(umbra_app *app) {
    char selftest[160], bench[220];
    umbra_result_load(app->selftest_path, selftest, sizeof selftest);
    umbra_result_load(app->bench_path, bench, sizeof bench);
    if (!selftest[0] && !bench[0]) {
        app->last_run_text[0] = 0;
        app->last_run_lines = 0;
        umbra_log(app, "last run: nothing recorded yet");
        return;
    }
    app->last_run_lines = umbra_last_run_block(app->last_run_text, sizeof app->last_run_text,
                                               selftest, bench);
    char flat[260];
    umbra_flatten(flat, sizeof flat, app->last_run_text);
    umbra_log(app, "last run: %s", flat);
}

static void remember_selftest(umbra_app *app) {
    umbra_result_save(app->selftest_path, app->selftest_text);
    umbra_log(app, "last run: self-test saved to %s", app->selftest_path);
    load_last_run(app);
}

static void remember_bench(umbra_app *app) {
    // The benchmark block is four lines; the file holds one, so the newlines
    // become spaces and the device name is cut short enough to stay readable.
    char flat[200];
    umbra_flatten(flat, sizeof flat, app->bench_text);
    umbra_result_save(app->bench_path, flat);
    umbra_log(app, "last run: benchmark saved to %s", app->bench_path);
    load_last_run(app);
}

// "OpenGL ES 3.2 V1.R32P1-01EAC0.153D…" is 60 characters of driver build id; the
// overlay only needs the version.
static void short_gles(const char *version, char *out, size_t cap) {
    const char *p = version ? strstr(version, "OpenGL ES") : NULL;
    if (!p) {
        snprintf(out, cap, "%s", version ? version : "?");
        return;
    }
    size_t n = 0;
    while (p[n] && n + 1 < cap) {
        char c = p[n];
        if (n > 9 && !(c >= '0' && c <= '9') && c != '.') break;
        out[n] = c;
        n++;
    }
    out[n] = 0;
}

// The HUD font is an 8-pixel bitmap, and where it goes is decided in
// umbra_hud.h: pure functions that the headless self-test runs, so the
// status-bar and navigation-bar cases are tested without a phone. These wrappers
// only feed them the app's numbers.
static int hud_rows(const umbra_app *app);

static float hud_scale(const umbra_app *app) {
    return umbra_hud_scale(app->dpi_scale, app->width, app->height, hud_rows(app), app->insets[1]);
}

// The hand controls' own scale, from a finger's size rather than the text's.
static float hand_scale(const umbra_app *app) {
    return umbra_hud_hand_scale(app->dpi_scale, app->width, app->height);
}

static void hud_button_rect(const umbra_app *app, int i, float *x, float *y, float *w, float *h) {
    umbra_rect r = umbra_hud_button(i, app->width, app->height, app->insets, hud_scale(app));
    *x = r.x;
    *y = r.y;
    *w = r.w;
    *h = r.h;
}

static void hud_flush(umbra_app *app) {
    if (g_hud_count == 0) return;
    glUseProgram(app->prog_hud);
    glBindVertexArray(app->vao_hud);
    glBindBuffer(GL_ARRAY_BUFFER, app->vbo_hud);
    glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)g_hud_count * (GLsizeiptr)sizeof(hud_vert), NULL, GL_STREAM_DRAW);
    glBufferSubData(GL_ARRAY_BUFFER, 0, (GLsizeiptr)g_hud_count * (GLsizeiptr)sizeof(hud_vert), g_hud_verts);
    glUniform2f(glGetUniformLocation(app->prog_hud, "u_screen"), (float)app->width, (float)app->height);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, app->tex_font);
    glUniform1i(glGetUniformLocation(app->prog_hud, "u_tex"), 0);
    // Quad indices: two triangles per quad.
    static unsigned *indices = NULL;
    static int cap = 0;
    int quads = g_hud_count / 4;
    if (quads > cap) {
        cap = quads * 2;
        indices = (unsigned *)realloc(indices, cap * 6 * sizeof(unsigned));
        for (int i = 0; i < cap; i++) {
            unsigned b = i * 4u;
            indices[i * 6 + 0] = b; indices[i * 6 + 1] = b + 1; indices[i * 6 + 2] = b + 2;
            indices[i * 6 + 3] = b; indices[i * 6 + 4] = b + 2; indices[i * 6 + 5] = b + 3;
        }
    }
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, app->ibo_hud);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, (GLsizeiptr)quads * 6 * (GLsizeiptr)sizeof(unsigned), indices, GL_STREAM_DRAW);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glDisable(GL_DEPTH_TEST);
    glDrawElements(GL_TRIANGLES, quads * 6, GL_UNSIGNED_INT, 0);
    glEnable(GL_DEPTH_TEST);
    glDisable(GL_BLEND);
}

// --- font texture -------------------------------------------------------

static void create_font_texture(umbra_app *app) {
    const int W = 128, H = 64;
    static unsigned char texels[128 * 64];
    memset(texels, 0, sizeof texels);
    for (int gi = 0; gi < 95; gi++) {
        int ox = (gi % 16) * 8;
        int oy = (gi / 16) * 8;
        for (int row = 0; row < 8; row++) {
            unsigned bits = UMBRA_FONT8X8[gi][row];
            for (int col = 0; col < 8; col++) {
                if (bits & (1u << col)) {
                    texels[(oy + row) * W + ox + col] = 255;
                }
            }
        }
    }
    // Reserve the bottom-right texel as solid coverage for hud_rect(); the 95
    // glyphs use rows 0..5 of the 8-row atlas, so it belongs to no glyph.
    texels[(H - 1) * W + (W - 1)] = 255;
    glGenTextures(1, &app->tex_font);
    glBindTexture(GL_TEXTURE_2D, app->tex_font);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, W, H, 0, GL_RED, GL_UNSIGNED_BYTE, texels);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}

// --- GL setup -----------------------------------------------------------

static void query_gl_info(umbra_app *app) {
    const char *r = (const char *)glGetString(GL_RENDERER);
    const char *v = (const char *)glGetString(GL_VENDOR);
    const char *ver = (const char *)glGetString(GL_VERSION);
    snprintf(app->gl_renderer, sizeof app->gl_renderer, "%s", r ? r : "?");
    snprintf(app->gl_vendor, sizeof app->gl_vendor, "%s", v ? v : "?");
    snprintf(app->gl_version, sizeof app->gl_version, "%s", ver ? ver : "?");
    GLint depth = 0;
    glGetIntegerv(GL_DEPTH_BITS, &depth);
    app->depth_bits = depth;
    GLint range[2] = {0, 0};
    GLint precision = 0;
    glGetShaderPrecisionFormat(GL_VERTEX_SHADER, GL_HIGH_FLOAT, range, &precision);
    snprintf(app->highp_vertex, sizeof app->highp_vertex, "%d^%d", range[1], precision);
    GLint frange[2] = {0, 0};
    GLint fprecision = 0;
    glGetShaderPrecisionFormat(GL_FRAGMENT_SHADER, GL_HIGH_FLOAT, frange, &fprecision);
    snprintf(app->highp_fragment, sizeof app->highp_fragment, "%d^%d", frange[1], fprecision);
}

static void create_fullscreen_quad(umbra_app *app) {
    static const float tri[8] = {-1, -1, 3, -1, -1, 3};
    glGenVertexArrays(1, &app->vao_full);
    glBindVertexArray(app->vao_full);
    GLuint vbo;
    glGenBuffers(1, &vbo);
    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof tri, tri, GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 8, (void *)0);
}

static void create_cube_geometry(umbra_app *app) {
    // A unit cube at the origin with the mesher's face shading baked in, so a
    // wrong matrix or depth range shows up as a failed pixel test.
    typedef struct { float x, y, z, r, g, b; } cube_vert;
    static const cube_vert verts[] = {
        // +Z (front) 0.5 light... front is a side face: 0.8
        {-0.5f, -0.5f, 0.5f, 0.8f, 0.2f, 0.2f}, {0.5f, -0.5f, 0.5f, 0.8f, 0.2f, 0.2f},
        {0.5f, 0.5f, 0.5f, 0.8f, 0.2f, 0.2f}, {-0.5f, 0.5f, 0.5f, 0.8f, 0.2f, 0.2f},
        // -Z
        {0.5f, -0.5f, -0.5f, 0.8f, 0.2f, 0.2f}, {-0.5f, -0.5f, -0.5f, 0.8f, 0.2f, 0.2f},
        {-0.5f, 0.5f, -0.5f, 0.8f, 0.2f, 0.2f}, {0.5f, 0.5f, -0.5f, 0.8f, 0.2f, 0.2f},
        // +Y
        {-0.5f, 0.5f, 0.5f, 1.0f, 0.3f, 0.9f}, {0.5f, 0.5f, 0.5f, 1.0f, 0.3f, 0.9f},
        {0.5f, 0.5f, -0.5f, 1.0f, 0.3f, 0.9f}, {-0.5f, 0.5f, -0.5f, 1.0f, 0.3f, 0.9f},
        // -Y
        {-0.5f, -0.5f, -0.5f, 0.5f, 0.2f, 0.2f}, {0.5f, -0.5f, -0.5f, 0.5f, 0.2f, 0.2f},
        {0.5f, -0.5f, 0.5f, 0.5f, 0.2f, 0.2f}, {-0.5f, -0.5f, 0.5f, 0.5f, 0.2f, 0.2f},
        // -X
        {-0.5f, -0.5f, -0.5f, 0.6f, 0.2f, 0.2f}, {-0.5f, -0.5f, 0.5f, 0.6f, 0.2f, 0.2f},
        {-0.5f, 0.5f, 0.5f, 0.6f, 0.2f, 0.2f}, {-0.5f, 0.5f, -0.5f, 0.6f, 0.2f, 0.2f},
        // +X
        {0.5f, -0.5f, 0.5f, 0.6f, 0.2f, 0.2f}, {0.5f, -0.5f, -0.5f, 0.6f, 0.2f, 0.2f},
        {0.5f, 0.5f, -0.5f, 0.6f, 0.2f, 0.2f}, {0.5f, 0.5f, 0.5f, 0.6f, 0.2f, 0.2f},
    };
    static const unsigned short idx[] = {
        0,1,2, 0,2,3, 4,5,6, 4,6,7, 8,9,10, 8,10,11,
        12,13,14, 12,14,15, 16,17,18, 16,18,19, 20,21,22, 20,22,23,
    };
    glGenVertexArrays(1, &app->vao_cube);
    glBindVertexArray(app->vao_cube);
    glGenBuffers(1, &app->vbo_cube);
    glBindBuffer(GL_ARRAY_BUFFER, app->vbo_cube);
    glBufferData(GL_ARRAY_BUFFER, sizeof verts, verts, GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, sizeof(cube_vert), (void *)0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, sizeof(cube_vert), (void *)(3 * sizeof(float)));
    glGenBuffers(1, &app->ibo_cube);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, app->ibo_cube);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof idx, idx, GL_STATIC_DRAW);
}

// Uploads the finished mesh. Split from buffer creation because the buffers are
// made at init and the data only exists after the sliced mesher finishes.
static void upload_mesh(umbra_app *app) {
    int64_t vlen = 0, ilen = 0;
    const uint8_t *verts = umbra_verts_ptr(&vlen);
    const uint8_t *indices = umbra_indices_ptr(&ilen);
    glBindVertexArray(app->vao_mesh);
    glBindBuffer(GL_ARRAY_BUFFER, app->vbo_mesh);
    glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)vlen, verts, GL_STATIC_DRAW);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, app->ibo_mesh);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, (GLsizeiptr)ilen, indices, GL_STATIC_DRAW);
    app->mesh_uploaded = true;
    app->uploaded_vlen = vlen;
    app->uploaded_ilen = ilen;
    umbra_log(app, "mesh uploaded: %.1f MB vertices, %.1f MB indices", vlen / 1048576.0,
              ilen / 1048576.0);
}

// An edit rewrote a few ranges, not the world. Re-uploading 18 MB of vertices for one
// block is what the old code did; this sends the slots that changed, and falls back to
// a whole upload only when the arena itself changed shape (a column outgrew its slot).
static void upload_mesh_changes(umbra_app *app) {
    int64_t vlen = 0, ilen = 0;
    const uint8_t *verts = umbra_verts_ptr(&vlen);
    const uint8_t *indices = umbra_indices_ptr(&ilen);
    if (!app->mesh_uploaded || app->uploaded_vlen != vlen || app->uploaded_ilen != ilen ||
            umbra_mesh_moved()) {
        upload_mesh(app);
        umbra_dirty_clear();
        return;
    }
    int slots = (int)umbra_dirty_count();
    glBindVertexArray(app->vao_mesh);
    glBindBuffer(GL_ARRAY_BUFFER, app->vbo_mesh);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, app->ibo_mesh);
    int64_t vbytes = 0, ibytes = 0;
    for (int i = 0; i < slots; i++) {
        int64_t sid = umbra_dirty_slot(i);
        if (sid < 0) continue;
        int64_t voff = umbra_range_vertex(sid), vcount = umbra_range_vertex_len(sid);
        int64_t ioff = umbra_range_index(sid), icount = umbra_range_index_len(sid);
        if (vcount > 0) {
            glBufferSubData(GL_ARRAY_BUFFER, (GLintptr)(voff * (int64_t)sizeof(umbra_vertex)),
                            (GLsizeiptr)(vcount * (int64_t)sizeof(umbra_vertex)),
                            verts + voff * (int64_t)sizeof(umbra_vertex));
            vbytes += vcount * (int64_t)sizeof(umbra_vertex);
        }
        if (icount > 0) {
            glBufferSubData(GL_ELEMENT_ARRAY_BUFFER, (GLintptr)(ioff * 4),
                            (GLsizeiptr)(icount * 4), indices + ioff * 4);
            ibytes += icount * 4;
        }
    }
    umbra_dirty_clear();
    if (glGetError() != GL_NO_ERROR) {
        umbra_log(app, "edit: the sub-upload was refused; re-uploading the whole mesh");
        upload_mesh(app);
        return;
    }
    umbra_log(app, "edit: uploaded %lld slot(s), %.1f KB of vertices, %.1f KB of indices",
              (long long)slots, vbytes / 1024.0, ibytes / 1024.0);
}

static void create_mesh_buffers(umbra_app *app) {
    glGenVertexArrays(1, &app->vao_mesh);
    glBindVertexArray(app->vao_mesh);
    glGenBuffers(1, &app->vbo_mesh);
    glBindBuffer(GL_ARRAY_BUFFER, app->vbo_mesh);
    static int64_t len = 0;
    const uint8_t *verts = umbra_verts_ptr(&len);
    glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)len, verts, GL_STATIC_DRAW);
    const GLsizei stride = (GLsizei)sizeof(umbra_vertex);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, stride, (void *)offsetof(umbra_vertex, x));
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, stride, (void *)offsetof(umbra_vertex, nx));
    glEnableVertexAttribArray(2);
    glVertexAttribPointer(2, 2, GL_FLOAT, GL_FALSE, stride, (void *)offsetof(umbra_vertex, u));
    glEnableVertexAttribArray(3);
    glVertexAttribPointer(3, 3, GL_FLOAT, GL_FALSE, stride, (void *)offsetof(umbra_vertex, r));
    glEnableVertexAttribArray(4);
    glVertexAttribPointer(4, 1, GL_FLOAT, GL_FALSE, stride, (void *)offsetof(umbra_vertex, ao));
    glGenBuffers(1, &app->ibo_mesh);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, app->ibo_mesh);
    static int64_t ilen = 0;
    const uint8_t *indices = umbra_indices_ptr(&ilen);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, (GLsizeiptr)ilen, indices, GL_STATIC_DRAW);
}

// --- saved edits ---------------------------------------------------------
//
// A break or a place has to still be there when the app is opened again, or a phone
// that sleeps loses the player's work. Goose owns the format (umbra_edit_line /
// umbra_apply_edit, "x y z block_name" per line); this owns the file, because the path
// is a platform fact.
//
// The file is written by appending one line per edit rather than by rewriting it: an
// append cannot corrupt the edits already saved if the process dies halfway through a
// write, and the reader ignores a line it cannot parse, so a truncated last line costs
// that one edit and nothing else.
static void edits_path(const char *dir_hint, char *out, size_t cap) {
    out[0] = 0;
    const char *env = getenv("UMBRA_EDITS");
    if (env && env[0]) { snprintf(out, cap, "%s", env); return; }
    if (dir_hint && dir_hint[0]) { snprintf(out, cap, "%s/edits.txt", dir_hint); }
}

// "x y z name" -> one edit. Returns 1 if the world changed.
static int edit_apply_line(umbra_app *app, const char *line) {
    long x = 0, y = 0, z = 0;
    int used = 0;
    if (sscanf(line, "%ld %ld %ld %n", &x, &y, &z, &used) != 3 || used <= 0) return 0;
    const char *name = line + used;
    size_t n = strlen(name);
    while (n > 0 && (name[n - 1] == '\n' || name[n - 1] == '\r' || name[n - 1] == ' ')) n--;
    if (n == 0) return 0;
    return (int)umbra_apply_edit((int64_t)x, (int64_t)y, (int64_t)z,
                                 (sl_u8){(uint8_t *)name, (int64_t)n});
}

static int edits_append(umbra_app *app, const char *line, int64_t len) {
    if (!app->edits_path[0]) return 0;
    FILE *f = fopen(app->edits_path, "ab");
    if (!f) {
        umbra_log(app, "edits: cannot open %s to save an edit", app->edits_path);
        return 0;
    }
    fwrite(line, 1, (size_t)len, f);
    fputc('\n', f);
    int ok = ferror(f) ? 0 : 1;
    fclose(f);
    return ok;
}

// Replay the saved edits into the world. Called after the world is built and before
// the mesh begins, so the first mesh already has them and nothing is re-meshed twice.
static void edits_replay(umbra_app *app) {
    if (!app->edits_path[0]) return;
    FILE *f = fopen(app->edits_path, "rb");
    if (!f) {
        umbra_log(app, "edits: no saved edits at %s (this world has none yet)",
                  app->edits_path);
        return;
    }
    char line[256];
    int applied = 0, refused = 0, lines = 0;
    while (fgets(line, (int)sizeof line, f)) {
        lines++;
        if (line[0] == '#') continue;
        if (edit_apply_line(app, line)) { applied++; }
        else if (line[0] != '\n' && line[0] != '\r' && line[0] != 0) {
            refused++;
            // One line, named, so a bad save file is a log line and not a mystery.
            if (refused <= 3) {
                char shown[80];
                size_t n = strlen(line);
                if (n > 0 && line[n - 1] == '\n') n--;
                if (n >= sizeof shown) n = sizeof shown - 1;
                memcpy(shown, line, n);
                shown[n] = 0;
                umbra_log(app, "edits: refused \"%s\" (line %d)", shown, lines);
            }
        }
    }
    fclose(f);
    app->edits_replayed = applied;
    umbra_log(app, "edits: %d saved edit(s) replayed from %s, %d line(s) in the file, %d refused",
              applied, app->edits_path, lines, refused);
}

// Finds a client jar and makes it the source of the atlas and the block models.
//
// Three places, in order, and no user interface: the environment (host runs and
// anything that wants to point the app at a specific jar), the app's own files
// directory as `client.jar`, and /data/local/tmp/umbra-client.jar, which is where a
// test harness can push one. Anything else and the atlas stays the built-in
// placeholder set -- the app still runs, and the log says which of the two it got.
static int jar_try(umbra_app *app, const char *dir_hint) {
    char path[512];
    const char *env = getenv("UMBRA_JAR");
    if (env && env[0]) {
        snprintf(path, sizeof path, "%s", env);
    } else if (dir_hint && dir_hint[0]) {
        snprintf(path, sizeof path, "%s/client.jar", dir_hint);
    } else {
        path[0] = 0;
    }
    const char *candidates[3];
    int n = 0;
    if (path[0]) candidates[n++] = path;
    if (n == 0 || strcmp(path, "/data/local/tmp/umbra-client.jar") != 0) {
        candidates[n++] = "/data/local/tmp/umbra-client.jar";
    }
    for (int i = 0; i < n; i++) {
        FILE *f = fopen(candidates[i], "rb");
        if (!f) continue;
        fclose(f);
        snprintf(app->jar_path, sizeof app->jar_path, "%s", candidates[i]);
        int64_t code = umbra_jar_load((sl_u8){(uint8_t *)app->jar_path,
                                             (int64_t)strlen(app->jar_path)});
        app->jar_code = (int)code;
        if (code == 1) {
            app->jar_loaded = true;
            app->jar_models = (int)umbra_jar_models();
            app->jar_blockstates = (int)umbra_jar_blockstates();
            app->jar_textures = (int)umbra_jar_textures();
            app->jar_textures_missing = (int)umbra_jar_textures_missing();
            app->jar_bytes = (long long)umbra_jar_bytes();
            umbra_log(app, "jar: %s, %lld bytes: %d models, %d blockstates, %d textures "
                           "(%d missing) -- the atlas and the models are the jar's",
                      app->jar_path, app->jar_bytes, app->jar_models,
                      app->jar_blockstates, app->jar_textures, app->jar_textures_missing);
            return 1;
        }
        umbra_log(app, "jar: %s could not be used (code %lld); trying the next place",
                  app->jar_path, (long long)code);
    }
    app->jar_loaded = false;
    app->jar_code = 0;
    umbra_log(app, "jar: none found; the atlas is the built-in placeholder set "
                   "(set UMBRA_JAR or put client.jar in the app's files directory)");
    return 0;
}

// Uploads the block atlas Goose built, once. The pixels are the packer's own:
// gutters, the loud missing tile and frame 0 of every animation are already in
// them (core/atlas.goose), so this is a straight RGBA8 upload with mipmaps.
static void upload_atlas(umbra_app *app) {
    int64_t len = 0;
    const uint8_t *pixels = umbra_atlas_pixels(&len);
    int sz = (int)umbra_atlas_size();
    int sh = (int)umbra_atlas_height();
    if (!pixels || sz <= 0 || sh <= 0 || len < (int64_t)sz * sh * 4) {
        umbra_log(app, "atlas: no pixels (%lld bytes for %dx%d)", (long long)len, sz, sh);
        set_fallback(app, "the texture atlas did not build");
        return;
    }
    if (!app->atlas_tex) glGenTextures(1, &app->atlas_tex);
    glBindTexture(GL_TEXTURE_2D, app->atlas_tex);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, sz, sh, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    // Nearest within a tile would alias badly at a distance, so: repeat-free
    // linear inside the tile, mipmaps for the far field, and the gutter is what
    // keeps a mip level from mixing two tiles.
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST_MIPMAP_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glGenerateMipmap(GL_TEXTURE_2D);
    glBindTexture(GL_TEXTURE_2D, 0);
    app->atlas_size = sz;
    app->atlas_hash = (unsigned)umbra_atlas_hash();
    app->atlas_missing = (int)umbra_atlas_missing();
    app->atlas_uploads++;
    umbra_log(app, "atlas: %dx%d, %lld bytes, %lld tiles, hash %08x, %d missing", sz, sh,
              (long long)len, (long long)umbra_atlas_tiles(), app->atlas_hash,
              app->atlas_missing);
    umbra_log(app, "atlas: source is %s", app->jar_loaded ? "the client jar" : "the placeholder set");
    if (app->atlas_missing > 0) {
        // Not fatal, and never silent: the loud tile is on screen and the count
        // says how many blocks asked for a texture this build does not have.
        umbra_log(app, "atlas: %d block faces asked for a tile that is missing",
                  app->atlas_missing);
    }
}

static void create_hud_buffers(umbra_app *app) {
    glGenVertexArrays(1, &app->vao_hud);
    glBindVertexArray(app->vao_hud);
    glGenBuffers(1, &app->vbo_hud);
    glBindBuffer(GL_ARRAY_BUFFER, app->vbo_hud);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, sizeof(hud_vert), (void *)offsetof(hud_vert, x));
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, sizeof(hud_vert), (void *)offsetof(hud_vert, u));
    glEnableVertexAttribArray(2);
    glVertexAttribPointer(2, 4, GL_FLOAT, GL_FALSE, sizeof(hud_vert), (void *)offsetof(hud_vert, r));
    glGenBuffers(1, &app->ibo_hud);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, app->ibo_hud);
}

// Everything that needs the finished mesh: counts, bounds, the camera frame and
// the two GPU buffers. Called once, when the sliced mesher says it is done.
// Indices per pass, summed over the (pass, column) ranges.
static void count_ranges(umbra_app *app) {
    int64_t counts[3] = {0, 0, 0};
    int slots = (int)umbra_range_slots();
    for (int i = 0; i < slots; i++) {
        int b = (int)umbra_range_batch(i);
        if (b < 0 || b > 2) continue;
        counts[b] += umbra_range_index_len(i);
    }
    for (int b = 0; b < 3; b++) app->batch_count[b] = counts[b];
}

static void finish_scene(umbra_app *app) {
    // What the ranges draw: the arena also holds the slack an edit needs, and a HUD
    // that counted the slack would report a world bigger than the one on screen.
    app->vert_count = (int32_t)umbra_used_vertices();
    app->index_count = (int32_t)umbra_index_count();
    count_ranges(app);
    app->center[0] = (umbra_mesh_min_x() + umbra_mesh_max_x()) * 0.5f;
    app->center[1] = (umbra_mesh_min_y() + umbra_mesh_max_y()) * 0.5f;
    app->center[2] = (umbra_mesh_min_z() + umbra_mesh_max_z()) * 0.5f;
    app->span[0] = umbra_mesh_max_x() - umbra_mesh_min_x();
    app->span[1] = umbra_mesh_max_y() - umbra_mesh_min_y();
    app->span[2] = umbra_mesh_max_z() - umbra_mesh_min_z();
    // Fit the world into the band of screen that the overlay and the buttons
    // leave free, instead of fitting it into the whole screen and hoping. The
    // arithmetic lives in umbra_camera.h so the host tests can check it with the
    // owner's phone's numbers.
    float min_b[3] = {umbra_mesh_min_x(), umbra_mesh_min_y(), umbra_mesh_min_z()};
    float max_b[3] = {umbra_mesh_max_x(), umbra_mesh_max_y(), umbra_mesh_max_z()};
    float band_top = 0.0f, band_bottom = 0.0f;
    umbra_hud_scene_band(hud_rows(app), hud_scale(app), app->insets, app->width, app->height,
                         &band_top, &band_bottom);
    umbra_camera_fit fit = umbra_camera_fit_world(min_b, max_b, app->fov_y, app->width,
                                                  app->height, band_top, band_bottom);
    if (!fit.ok) {
        umbra_log(app, "camera: could not fit the world (%dx%d)", app->width, app->height);
    }
    app->cam_dist = fit.dist;
    app->look[0] = fit.look[0];
    app->look[1] = fit.look[1];
    app->look[2] = fit.look[2];
    app->fog_near = fit.fog_near;
    app->fog_far = fit.fog_far;
    float band_frac = fit.band_fraction;
    camera_eye(app, app->eye);
    // The upload is a single glBufferData of the whole arena, and it lands inside one
    // frame: the run that logs "longest frame 165 ms" cannot say whether that frame
    // was spent here or in the first draw, so it is timed on its own and the number
    // goes in the log with the size that produced it.
    int64_t up_t0 = umbra_now_us();
    upload_mesh(app);
    app->upload_us = umbra_now_us() - up_t0;
    umbra_log(app, "upload: %.1f MB of vertices and %.1f MB of indices in %.1f ms "
                   "(%.0f MB/s)",
              app->uploaded_vlen / 1048576.0, app->uploaded_ilen / 1048576.0,
              app->upload_us / 1000.0,
              (app->uploaded_vlen + app->uploaded_ilen) / 1048576.0 /
                  (app->upload_us > 0 ? app->upload_us / 1000000.0 : 1e-6));
    // The initial mesh marked everything dirty and moved the arena; now that the whole
    // buffer is up, the next upload is an edit's sub-upload, not another 25 MB.
    umbra_dirty_clear();
    app->mesh_state = 2;
    app->mesh_progress = 1000;
    umbra_log(app, "mesh bounds x %.1f..%.1f y %.1f..%.1f z %.1f..%.1f, camera %.1f blocks out, "
                   "free band %.0f..%.0f of %d (%.0f%%), fog %.0f..%.0f",
              umbra_mesh_min_x(), umbra_mesh_max_x(), umbra_mesh_min_y(), umbra_mesh_max_y(),
              umbra_mesh_min_z(), umbra_mesh_max_z(), app->cam_dist,
              band_top, band_bottom, app->height, band_frac * 100.0f,
              app->fog_near, app->fog_far);
    umbra_log(app, "camera: eye %.1f %.1f %.1f look %.1f %.1f %.1f, %.1f blocks out, fov %.0f",
              app->eye[0], app->eye[1], app->eye[2], app->look[0], app->look[1], app->look[2],
              app->cam_dist, app->fov_y);
    umbra_log(app, "mesh: %d vertices drawn, passes %lld/%lld/%lld over %lld ranges",
              app->vert_count, (long long)app->batch_count[0],
              (long long)app->batch_count[1], (long long)app->batch_count[2],
              (long long)umbra_range_slots());
    // Item 3's own question, in one line: how much of this world came out of the jar's
    // blockstates -> models -> geometry, and how much fell back to a cube because a
    // blockstate named no model. A phone that loaded the jar's textures but drew every
    // block as a cube reports 0 blocks and 0 faces here, and the "the atlas is the jar's"
    // line would still be true -- which is why this number is logged separately.
    umbra_log(app, "mesh: %lld block(s) drawn from a model, %lld face(s) from a model, "
                   "%lld block(s) whose blockstate had no model",
              (long long)umbra_mesh_model_blocks(), (long long)umbra_mesh_model_faces(),
              (long long)umbra_mesh_model_missing());
    umbra_log(app, "startup: meshed in %.1f ms over %lld calls (worst call %.1f ms, worst unit %.1f ms), "
                   "longest frame %.1f ms, frames over 250 ms: %lld",
              app->mesh_total_us / 1000.0, (long long)app->mesh_calls,
              app->mesh_worst_call_us / 1000.0, umbra_demo_mesh_worst_unit_us() / 1000.0,
              app->max_frame_us / 1000.0, (long long)app->long_frames);
    // Why the unit number is what it is: the unit is a layer of a section (a meshing
    // walk) or a column copy, and the two have nothing in common. A unit over 10 ms on
    // a shared, GPU-less emulator is usually the scheduler taking the core back, so the
    // count of them says whether the ceiling is being approached by the code or by the
    // machine.
    umbra_log(app, "units: worst meshing walk %.1f ms, worst column copy %.1f ms, "
                   "%lld units over 10 ms of %lld",
              umbra_demo_mesh_worst_mesh_us() / 1000.0,
              umbra_demo_mesh_worst_copy_us() / 1000.0,
              (long long)umbra_demo_mesh_units_over_10ms(),
              (long long)umbra_demo_mesh_units());
}

// The mesh after an edit: the view stays where the player put it, the geometry that
// did not change stays on the GPU, and the log says how little work the edit cost.
static void finish_edit(umbra_app *app) {
    app->vert_count = (int32_t)umbra_used_vertices();
    app->index_count = (int32_t)umbra_index_count();
    count_ranges(app);
    // The count has to be read before the upload clears the list.
    int64_t changed = umbra_dirty_count();
    int64_t up_t0 = umbra_now_us();
    upload_mesh_changes(app);
    app->edit_upload_us = umbra_now_us() - up_t0;
    // The geometry is on the GPU; nothing has drawn it yet. That is what makes the next
    // swap the frame the edit becomes visible in, and it is marked here.
    app->edit_mesh_done_us = umbra_now_us();
    app->edit_pending_present = 1;
    app->mesh_state = 2;
    app->mesh_progress = 1000;
    umbra_log(app, "edit: re-meshed %lld of %lld columns in %.1f ms over %lld calls "
                   "(worst call %.1f ms, worst slice %.1f ms), %lld slot(s) changed",
              (long long)umbra_mesh_columns(), (long long)umbra_world_columns(),
              app->mesh_total_us / 1000.0, (long long)app->mesh_calls,
              app->mesh_worst_call_us / 1000.0, umbra_mesh_worst_unit_ms(),
              (long long)changed);
    int64_t worst = app->mesh_worst_call_us;
    if (worst >= (int64_t)UMBRA_EDIT_BUDGET_MS * 1000) {
        umbra_log(app, "edit: a slice took %.1f ms, over the %d ms an edit is allowed",
                  worst / 1000.0, UMBRA_EDIT_BUDGET_MS);
    }
    app->mesh_worst_call_us = 0;
    app->mesh_calls = 0;
    app->mesh_total_us = 0;
}

// --- screens -------------------------------------------------------------
//
// One number says which screen is up, and every change is logged: the emulator run
// reads the log to know what it is looking at, so a screen that changed without a
// line is a screen the harness cannot drive.
static const char *screen_name(int screen) {
    switch (screen) {
        case UMBRA_SCREEN_HOME: return "home";
        case UMBRA_SCREEN_SELFTEST: return "self-test";
        case UMBRA_SCREEN_BENCH: return "benchmark";
        case UMBRA_SCREEN_LOADING: return "loading";
        case UMBRA_SCREEN_GAMEFILES: return "game files";
        default: return "unknown";
    }
}

void umbra_app_set_screen(umbra_app *app, int screen) {
    if (app->screen == (umbra_screen)screen) return;
    umbra_log(app, "screen: %s -> %s", screen_name((int)app->screen), screen_name(screen));
    app->screen = (umbra_screen)screen;
}

// The jar's destination and the URL it comes from, both asked of Goose, so the
// path the screen shows is the path jar_try() reads at start-up.
static void gf_resolve_paths(umbra_app *app, char *hex, size_t hex_cap) {
    int64_t n = 0;
    int64_t sha_len = 0;
    const uint8_t *sha = umbra_gf_pinned_sha1(&sha_len);
    gf_copy(app, sha, sha_len, hex, hex_cap);
    const uint8_t *p = umbra_gf_jar_path((sl_u8){(uint8_t *)app->files_dir,
                                                 (int64_t)strlen(app->files_dir)}, &n);
    gf_copy(app, p, n, app->jar_path, sizeof app->jar_path);
    // The jar's URL comes out of the version JSON the manifest names, which is
    // another fetch; the pinned object URL is the same file and needs no second
    // request, so it is what a download uses. It is checked against the pin's sha1
    // either way, which is what makes trusting the URL harmless.
    snprintf(app->gf_url, sizeof app->gf_url,
             "https://piston-data.mojang.com/v1/objects/%s/client.jar", hex);
}

void open_gamefiles_screen(umbra_app *app) {
    app->gf_job = 0;
    app->gf_done = 0;
    app->gf_adopt = 0;
    app->gf_got = 0;
    app->gf_total = (long long)umbra_gf_pinned_bytes();
    app->gf_logged_width = 0;
    umbra_app_set_screen(app, UMBRA_SCREEN_GAMEFILES);
    char hex[64];
    gf_resolve_paths(app, hex, sizeof hex);
    int present = (int)umbra_gf_jar_present((sl_u8){(uint8_t *)app->files_dir,
                                                    (int64_t)strlen(app->files_dir)});
    if (present) {
        gf_say(app, (int)umbra_gf_state_ready(), 0, 0, app->jar_path);
    } else {
        gf_say(app, (int)umbra_gf_state_idle(), 0, 0, "");
    }
    umbra_log(app, "gamefiles: the screen is up; jar path %s, %lld bytes pinned (sha1 %s), "
                   "a jar is %s here",
              app->jar_path, (long long)umbra_gf_pinned_bytes(), hex,
              present ? "already" : "not");
    umbra_log(app, "gamefiles: download would fetch %s", app->gf_url);
    if (!app->download_fn) {
        umbra_log(app, "gamefiles: this build cannot download (no platform hook); "
                       "import is %s", app->pick_file_fn ? "available" : "unavailable too");
    }
}

void close_gamefiles_screen(umbra_app *app) {
    if (app->screen != UMBRA_SCREEN_GAMEFILES) return;
    umbra_app_set_screen(app, app->mesh_state == 2 ? UMBRA_SCREEN_HOME : UMBRA_SCREEN_LOADING);
}

// Build the world (fast) and start meshing it (slow, sliced by the frame loop).
//
// Two worlds can be here: the demo scene this project generates, and a save the owner
// opened (core/worldload_in.goose). Whichever it is, the columns are in the array the
// mesher walks, so the only difference at this point is whether `demo_build` runs. A
// save is *not* rebuilt: its columns are the ones the import put there, and calling
// `demo_build` would throw them away.
static int scene_is_save(void) { return (int)umbra_world_is_save(); }

static void begin_scene(umbra_app *app) {
    int64_t t0 = umbra_now_us();
    if (scene_is_save() == 0) umbra_demo_build(20261114);
    // Saved edits go in before the first mesh: replaying them afterwards would re-mesh
    // columns that are already in the mesh, and the load is the slow part.
    edits_replay(app);
    int64_t t1 = umbra_now_us();
    umbra_demo_mesh_begin();
    app->mesh_state = 1;
    app->mesh_progress = 0;
    app->mesh_calls = 0;
    app->mesh_worst_call_us = 0;
    app->mesh_total_us = 0;
    umbra_app_set_screen(app, UMBRA_SCREEN_LOADING);
    umbra_log(app, "%s built in %.1f ms; meshing starts in slices of at most %d ms",
              scene_is_save() ? "the opened world" : "demo world", (t1 - t0) / 1000.0,
              UMBRA_MESH_BUDGET_MS);
}

// Called once per frame while the mesh is incomplete. The budget is a soft cap:
// a single section cannot be interrupted, so a call can overrun it by one
// section's work, which the worst-call number above reports.
static void pump_mesh(umbra_app *app) {
    if (app->mesh_state != 1) return;
    int64_t t = umbra_now_us();
    // How long the edit waited for the frame loop to get to it: measured once per edit,
    // on the first call that steps it. `umbra_mesh_is_edit()` is read *before* the step
    // because the step clears the flag on the last slice -- reading it afterwards lost
    // the measurement for any edit that finished in one call, which on a single changed
    // column is most of them.
    int was_edit = (int)umbra_mesh_is_edit();
    if (app->edit_applied_us > 0 && app->edit_wait_us == 0 && was_edit) {
        app->edit_wait_us = t - app->edit_applied_us;
    }
    // An edit gets the same small slices as the first mesh: the point of the edit path
    // is that it is *short*, not that it may block. Neither may hold a frame for more
    // than one section, and no section here takes anywhere near UMBRA_EDIT_BUDGET_MS.
    int done = (int)umbra_demo_mesh_step((int64_t)UMBRA_MESH_BUDGET_MS * 1000);
    int64_t took = umbra_now_us() - t;
    app->mesh_calls++;
    app->mesh_total_us += took;
    if (took > app->mesh_worst_call_us) app->mesh_worst_call_us = took;
    // The export is clamped in Goose too; clamping again here means a miscount
    // can never reach the screen as "LOADING WORLD 224%", which it did.
    int64_t progress = umbra_demo_mesh_progress();
    if (progress < 0) progress = 0;
    if (progress > 1000) {
        umbra_log(app, "mesh progress overran: %lld permille of %lld units",
                  (long long)progress, (long long)umbra_demo_mesh_total_units());
        progress = 1000;
    }
    app->mesh_progress = (int)progress;
    if (done) {
        umbra_demo_mesh_finish();
        if (was_edit) {
            finish_edit(app);
        } else {
            finish_scene(app);
            umbra_app_set_screen(app, UMBRA_SCREEN_HOME);
        }
    }
}

// --- the streaming world ------------------------------------------------
//
// Step 1 of the brief: a world worth walking in. The import reads the archive and leaves
// the region files resident; the *chunks* are parsed as the player approaches them, a
// slice per frame, so the world a person walks through is the radius they set rather than
// the window the reader happened to open.
//
// Two phases, and the split is what keeps a frame under its budget:
//
//   1. centre -- evict what left the window and plan what is missing. Cheap arithmetic,
//      no parsing, so it is safe in any frame.
//   2. fill   -- one slice per frame, UMBRA_STREAM_BUDGET_MS, until the window is whole.
//      Only when it is whole does the mesh restart, because a mesh of a half-filled
//      window is a mesh with holes in it: the mesher culls a face against a neighbour
//      that is not there and draws nothing where the world continues.
//
// `stream_start` is the only entry point a caller needs: it centres on the chunk that
// holds the player and leaves the job to run. It refuses to restart a fill that is
// already going to the same place, because that would throw away the parses in flight.

static int world_stream_armed(umbra_app *app) {
    // A world has to be open, and it has to be one with regions still resident. A save
    // read before this existed has no stream, and `umbra_world_stream_open` says so.
    return app->world_state == 2 && umbra_world_stream_open() == 1;
}

static void stream_start(umbra_app *app, int cx, int cz, int radius) {
    if (!world_stream_armed(app)) return;
    if (app->stream_state == 1 && app->stream_cx == cx && app->stream_cz == cz &&
            app->stream_radius == radius) {
        // Already filling this exact window: leaving it alone is the point of asking.
        return;
    }
    int64_t want = umbra_world_set_radius((int64_t)radius);
    int64_t gone = umbra_world_stream_centre((int64_t)cx, (int64_t)cz, want);
    app->stream_radius = (int)want;
    app->stream_cx = cx;
    app->stream_cz = cz;
    app->stream_state = 1;
    umbra_log(app, "stream: centre chunk %d,%d radius %d (%lld chunks), %lld evicted, "
                   "%lld to parse",
              cx, cz, (int)want, (long long)((want * 2 + 1) * (want * 2 + 1)),
              (long long)gone, (long long)umbra_world_stream_pending());
}

// Re-centre the window on the chunk the player is standing in -- but only once they are
// a whole chunk away from the middle of the window they already have.
//
// The hysteresis is not an optimisation. Centring on the chunk under the player means a
// player who stands on a chunk border alternates between two windows every frame, and
// every recentre evicts, plans, parses and re-meshes the whole world. A stride of one
// chunk costs at most one chunk of draw distance ahead of the player (they are never
// more than one chunk inside the window's edge) and makes the number of re-meshes a
// function of distance walked rather than of frames.
//
// It also refuses while a fill or a mesh is in flight: a re-centre during either one
// throws away the work in progress, and the player is not moving fast enough for that to
// be worth it.
static void stream_maybe_recentre(umbra_app *app) {
    if (app->stream_state != 1 && app->stream_state != 2) return;
    if (!world_stream_armed(app)) return;
    if (app->mesh_state == 1) return;            // a mesh is being rebuilt: wait for it
    if (app->stream_state == 1) return;          // a window is still filling
    // A chunk is 16 blocks and the body's position is its centre, so this is the chunk it
    // is standing in.
    int cx = (int)floorf(app->player.x / 16.0f);
    int cz = (int)floorf(app->player.z / 16.0f);
    // The stride, and the whole point of this function: only re-centre when the body is a
    // whole *radius* of chunks away from the middle of the window it has. A stride of one
    // chunk (the obvious version) re-centres on every chunk crossing, which at walking
    // speed is once a second -- and every recentre evicts, plans, parses and re-meshes the
    // whole world. With this stride a radius-4 window is rebuilt when the player has walked
    // 64 blocks, and the window always extends at least `radius` chunks ahead of them.
    if (cx >= app->stream_cx - app->stream_radius && cx <= app->stream_cx + app->stream_radius &&
        cz >= app->stream_cz - app->stream_radius && cz <= app->stream_cz + app->stream_radius) {
        return;
    }
    stream_start(app, cx, cz, app->stream_radius);
}

static void stream_pump(umbra_app *app) {
    if (app->stream_state != 1) return;
    if (!world_stream_armed(app)) {
        app->stream_state = 0;
        return;
    }
    int64_t t0 = umbra_now_us();
    int done = (int)umbra_world_stream_step((int64_t)UMBRA_STREAM_BUDGET_MS * 1000);
    int64_t took = umbra_now_us() - t0;
    app->stream_slices++;
    if (took > app->stream_worst_us) app->stream_worst_us = took;
    if (!done) return;

    // The window is whole. Now -- and not before -- the mesh is rebuilt over it.
    app->stream_state = 2;
    app->stream_resident = umbra_world_stream_resident();
    app->stream_seen = umbra_world_stream_seen();
    app->stream_missing = umbra_world_stream_missing();
    app->stream_errors = umbra_world_stream_errors();
    app->stream_loaded = umbra_world_stream_loaded();
    app->stream_evicted = umbra_world_stream_evicted();
    app->stream_peak = umbra_world_stream_peak();
    app->stream_bytes = umbra_world_stream_bytes();
    umbra_log(app, "stream: window complete, %lld column(s) resident of %lld asked for "
                   "(%lld missing from the save, %lld parse error(s)), %lld slice(s), "
                   "worst %.1f ms",
              (long long)app->stream_resident, (long long)app->stream_seen,
              (long long)app->stream_missing, (long long)app->stream_errors,
              (long long)app->stream_slices, app->stream_worst_us / 1000.0);
    umbra_log(app, "stream: the save's region files are %.1f MB resident, and %lld chunk(s) "
                   "have been parsed in total (%lld evicted) since the world opened",
              app->stream_bytes / (1024.0 * 1024.0), (long long)app->stream_loaded,
              (long long)app->stream_evicted);
    // A window with nothing in it is not a world to walk in, and rebuilding the mesh for
    // it would replace a drawable scene with an empty one.
    if (app->stream_resident <= 0) {
        umbra_log(app, "stream: no chunk of the window is in the save; keeping the mesh that "
                       "was there");
        return;
    }
    rebuild_world(app);
}

// Defined with the rest of the device checks, called at the end of init.
static void device_checks(umbra_app *app);

int umbra_app_init(umbra_app *app) {
    // The platform layer fills in where the log and the crash marker live
    // before calling init; the blanket memset below would erase them, and then
    // every log line would be written nowhere.
    char log_path[sizeof app->log_path];
    char marker_path[sizeof app->marker_path];
    int32_t width = app->width, height = app->height;
    // The platform reads the system insets and the density before init (it needs
    // a window to ask for them), so they must survive the memset too.
    int32_t insets[4] = {app->insets[0], app->insets[1], app->insets[2], app->insets[3]};
    float dpi_scale = app->dpi_scale > 0.0f ? app->dpi_scale : 1.0f;
    // The swap-interval hook is the platform's too, and the memset below erased
    // it: the emulator logged "no platform hook for the swap interval" while
    // android_main had set one.
    int (*swap_fn)(void *, int) = app->swap_interval_fn;
    void *swap_ctx = app->swap_interval_ctx;
    // The same is true of everything the platform supplies for the game-files
    // screen: the directory the app's own jar lives in, and the two ways to get
    // one there. All four were erased by this memset, so on the phone the app
    // believed it was a build with no download and no file picker, logged
    // "jar: none found" and went straight to the placeholder world -- the screen
    // the whole feature exists for never opened (run 43946503664).
    char files_dir[sizeof app->files_dir];
    memcpy(files_dir, app->files_dir, sizeof files_dir);
    int (*download_fn)(void *, const char *, const char *, long long *) = app->download_fn;
    int (*pick_file_fn)(void *, const char *, const char *, long long *) = app->pick_file_fn;
    void (*progress_fn)(void *, long long *, long long *) = app->progress_fn;
    void *net_ctx = app->net_ctx;
    memcpy(log_path, app->log_path, sizeof log_path);
    memcpy(marker_path, app->marker_path, sizeof marker_path);
    memset(app, 0, sizeof *app);
    memcpy(app->log_path, log_path, sizeof app->log_path);
    memcpy(app->marker_path, marker_path, sizeof app->marker_path);
    // The surface size comes from the window, not from this function: zeroing
    // it here would lay the HUD out for a 0x0 screen and log nonsense.
    app->width = width;
    app->height = height;
    for (int i = 0; i < 4; i++) app->insets[i] = insets[i];
    app->dpi_scale = dpi_scale;
    app->swap_interval_fn = swap_fn;
    app->swap_interval_ctx = swap_ctx;
    memcpy(app->files_dir, files_dir, sizeof app->files_dir);
    app->download_fn = download_fn;
    app->pick_file_fn = pick_file_fn;
    app->progress_fn = progress_fn;
    app->net_ctx = net_ctx;
    app->screen = UMBRA_SCREEN_HOME;
    app->bench_seconds = 60;
    // 55 degrees is a phone-friendly vertical field of view; the distance that
    // fits the world into it is computed from the mesh, per screen aspect.
    app->fov_y = 55.0f;
    app->touch_look_id = -1;
    app->touch_walk_id = -1;
    // The result files sit next to the log, so their names have to be known
    // before the start-up read: this line is the whole 0.3.1 last-run bug.
    set_run_paths(app);
    load_last_run(app);
    snprintf(app->build_text, sizeof app->build_text, "Umbra %s (%s)", "(see HUD)", UMBRA_GIT_COMMIT);

    log_open(app);
    umbra_log(app, "---- Umbra starting, build %s ----", UMBRA_GIT_COMMIT);
    int64_t name_len = 0;
    const uint8_t *core_name = umbra_core_selftest_name(&name_len);
    umbra_log(app, "core: %.*s", (int)(name_len < 120 ? name_len : 120), (const char *)core_name);

    // Crash marker: a clean shutdown rewrites this file; a crash leaves it.
    FILE *m = fopen(app->marker_path, "rb");
    if (m) {
        char buf[64] = {0};
        size_t n = fread(buf, 1, sizeof buf - 1, m);
        fclose(m);
        if (n > 0 && strncmp(buf, "running", 7) == 0) {
            app->previous_run_crashed = true;
            umbra_log(app, "previous run did not exit cleanly");
        }
    }
    m = fopen(app->marker_path, "wb");
    if (m) {
        fputs("running\n", m);
        fclose(m);
    }

    // Each shader is compiled and linked here, inside init, and the driver does that
    // work then and there: on the emulator this is the longest frame of the run
    // (269.7 ms at "mesh 0%, 1 calls"), and on a phone a driver that compiles on
    // first use would put it in the first world frame instead. Timed per program so
    // the number in the log names what it cost.
    char err[1024];
    int64_t sh_t0 = umbra_now_us();
    app->prog_mesh = link_program(VS_MESH, FS_MESH, err, sizeof err);
    if (!app->prog_mesh) { umbra_log(app, "mesh program: %s", err); return 0; }
    int64_t sh_mesh = umbra_now_us() - sh_t0;
    app->prog_hud = link_program(VS_HUD, FS_HUD, err, sizeof err);
    if (!app->prog_hud) { umbra_log(app, "hud program: %s", err); return 0; }
    int64_t sh_hud = umbra_now_us() - sh_t0 - sh_mesh;
    app->prog_pattern = link_program(VS_FULL, FS_PATTERN, err, sizeof err);
    app->prog_atlas = link_program(VS_FULL, FS_ATLAS, err, sizeof err);
    if (!app->prog_atlas) umbra_log(app, "atlas sampler shader: %s", err);
    if (!app->prog_pattern) { umbra_log(app, "pattern program: %s", err); return 0; }
    app->prog_cube = link_program(VS_CUBE, FS_CUBE, err, sizeof err);
    if (!app->prog_cube) { umbra_log(app, "cube program: %s", err); return 0; }
    int64_t sh_total = umbra_now_us() - sh_t0;
    umbra_log(app, "shaders: 5 programs compiled and linked in %.1f ms "
                   "(mesh %.1f, hud %.1f, the rest %.1f) -- once, at start",
              sh_total / 1000.0, sh_mesh / 1000.0, sh_hud / 1000.0,
              (sh_total - sh_mesh - sh_hud) / 1000.0);

    query_gl_info(app);
    umbra_log(app, "GL_RENDERER %s", app->gl_renderer);
    umbra_log(app, "GL_VERSION %s", app->gl_version);
    umbra_log(app, "GL_VENDOR %s", app->gl_vendor);
    umbra_log(app, "depth bits %d, vertex highp %s, fragment highp %s", app->depth_bits,
              app->highp_vertex, app->highp_fragment);

    create_font_texture(app);
    create_fullscreen_quad(app);
    create_cube_geometry(app);
    // The models and the atlas come from the jar when there is one, and only then is
    // there anything worth uploading: this has to run before the atlas and before the
    // mesher is handed its first section, or the first frames are the placeholder world
    // and never get replaced.
    {
        char files[512] = {0};
        const char *slash = strrchr(app->log_path, '/');
        if (slash) {
            size_t d = (size_t)(slash - app->log_path);
            if (d < sizeof files) {
                memcpy(files, app->log_path, d);
                files[d] = 0;
            }
        }
        jar_try(app, files);
        // The same directory holds the saved edits, and it is only known here (it is
        // where the log file lives). Set before begin_scene runs, which is what reads it.
        edits_path(files, app->edits_path, sizeof app->edits_path);
        umbra_log(app, "edits: the file for saved edits is %s",
                  app->edits_path[0] ? app->edits_path : "(none: this build has no files directory)");
        // A world the owner opened last time is opened again: the phone should come back
        // to the world it was in, not to the demo scene. This is the same import the
        // screen's fifth button runs, and it is before `begin_scene` so the save's
        // columns are what the first mesh is built from -- nothing is built and thrown
        // away.
        // The world is read by the stream, not by the import: the import validates the
        // archive and keeps its region files, and the window the player is in is parsed
        // from them as they walk. Set here, before any world is opened, because it is a
        // decision about who reads the save and it has to be made before the first chunk.
        umbra_world_set_stream_mode(1);
        // A test can ask for a particular render distance by leaving `radius.txt` beside
        // the save. This is the *only* way the radius is set from outside, and it exists
        // because the device walk is 1.5-second holds: at radius 4 the stride is 64
        // blocks and no hold crosses it, so a re-centre cannot be proved at the default.
        // The file is read once, here, and the value is clamped by Goose like any other.
        {
            char rp[560];
            snprintf(rp, sizeof rp, "%s/radius.txt", files);
            FILE *rf = fopen(rp, "rb");
            if (rf) {
                char line[32];
                if (fgets(line, (int)sizeof line, rf)) {
                    int want = atoi(line);
                    int64_t used = umbra_world_set_radius((int64_t)want);
                    umbra_log(app, "stream: radius %d asked for in radius.txt, %lld used "
                                   "(max %lld)", want, (long long)used,
                              (long long)umbra_world_radius_max());
                }
                fclose(rf);
            }
        }
        umbra_log(app, "stream: the world is streamed: radius %lld (max %lld), the import "
                       "validates the archive and the stream parses the window",
                  (long long)umbra_world_radius_setting(), (long long)umbra_world_radius_max());
        char world_zip[512];
        snprintf(world_zip, sizeof world_zip, "%s/world.zip", files);
        if (file_exists_at(world_zip)) {
            umbra_log(app, "world: a world from the game is in the app's directory; opening it");
            world_open_path(app, world_zip, "app directory, at start-up");
        } else {
            umbra_log(app, "world: no world from the game in the app's directory; this is the "
                           "demo scene (PUT A SAVE AT %s/world.zip)", files);
        }
    }
    // No jar, no jar's textures: on a phone there is no way to put one at
    // /data/local/tmp, so the world would be drawn with the twelve-tile placeholder
    // set (D-039) and nobody would be told. The game-files screen is what turns that
    // into a question the owner can answer (D-043); it goes up before the world is
    // meshed, so the placeholder geometry is never what the owner sees first.
    // The screen needs a real surface to lay out its buttons, so the frame loop
    // opens it (see gf_open_when_ready) rather than this function: at this point the
    // window may still be 1x1.
    umbra_log(app, "gamefiles: platform hooks %s, picker %s, files dir %s",
              app->download_fn ? "download" : "none",
              app->pick_file_fn ? "import" : "none",
              app->files_dir[0] ? app->files_dir : "(unknown)");
    // A world that is already open is the world; the screen is for getting the jar's
    // textures, and it goes up when there is no jar. The scene's source is in the log
    // either way (see the "world:" and "atlas:" lines).
    app->gf_pending_open = (!app->jar_loaded && app->files_dir[0] && app->download_fn) ? 1 : 0;
    // The atlas goes up before the world: the mesher's UVs already point into it.
    upload_atlas(app);
    create_hud_buffers(app);
    create_mesh_buffers(app);
    begin_scene(app);

    glEnable(GL_DEPTH_TEST);
    glDepthFunc(GL_LESS);
    glDisable(GL_CULL_FACE);  // turned on for the opaque world pass only: cross
                              // plants are single quads and must stay visible
                              // from both sides, and the HUD is not culled. The
                              // mesher's winding is checked in the host suite
                              // (cross product against the face normal).
    glFrontFace(GL_CCW);
    app->last_frame_time = 0.0;
    // The button rectangles are logged from the frame loop instead of here: at
    // this point the surface may still be 1x1, and a layout computed from that
    // is nonsense (run 43687356640 logged "button 0 at 25,-269 size -49x63").
    //
    // What the driver says about itself is written to the log here, once, before
    // anything can fail on it -- and a check that failed puts the app in the
    // fallback renderer instead of letting it crash later.
    device_checks(app);
    return 1;
}

// Running, suspended or clean. A force-stop, a kill -9 or a crash all leave the
// marker saying "running", which is the honest answer for a crash -- but the app
// is also killed from the background all the time, and claiming "previous run
// crashed" on a screen the owner is looking at after a swipe-away is a lie that
// costs more than it is worth. Pausing writes "clean", resuming writes "running".
void umbra_session_set(umbra_app *app, const char *state) {
    if (!app || !app->marker_path[0]) return;
    FILE *m = fopen(app->marker_path, "wb");
    if (!m) return;
    fprintf(m, "%s\n", state);
    fclose(m);
}

void umbra_app_shutdown(umbra_app *app) {
    FILE *m = fopen(app->marker_path, "wb");
    if (m) {
        fputs("clean\n", m);
        fclose(m);
    }
    umbra_log(app, "---- Umbra exiting after %lld frames ----", (long long)app->frames_drawn);
    if (g_log) {
        fclose(g_log);
        g_log = NULL;
    }
}

// --- self test ----------------------------------------------------------

// Every step of the self-test reports its own GL error, because "black screen"
// on its own does not say which call the driver refused.
static void selftest_gl_check(umbra_app *app, const char *where) {
    GLenum e = glGetError();
    if (e != GL_NO_ERROR) umbra_log(app, "self-test: gl error 0x%x at %s", (unsigned)e, where);
}

// --- GPU timing ------------------------------------------------------------
//
// A 59 FPS average on a 60 Hz phone is a statement about the display, not about
// the GPU: every frame is waiting for the vertical blank. Real GPU time needs a
// timer query, which GLES exposes as an extension, so the pointers are looked up
// at run time and the benchmark says plainly whether it had them.

#ifndef GL_TIME_ELAPSED_EXT
#define GL_TIME_ELAPSED_EXT 0x88BF
#endif
#ifndef GL_GPU_DISJOINT_EXT
#define GL_GPU_DISJOINT_EXT 0x8FBB
#endif
#ifndef GL_QUERY_RESULT_AVAILABLE
#define GL_QUERY_RESULT_AVAILABLE 0x8867
#endif
#ifndef GL_QUERY_RESULT
#define GL_QUERY_RESULT 0x8866
#endif

typedef void (*pfn_gen_queries)(GLsizei, GLuint *);
typedef void (*pfn_delete_queries)(GLsizei, const GLuint *);
typedef void (*pfn_begin_query)(GLenum, GLuint);
typedef void (*pfn_end_query)(GLenum);
typedef void (*pfn_get_query_uiv)(GLuint, GLenum, GLuint *);
typedef void (*pfn_get_query_ui64v)(GLuint, GLenum, uint64_t *);

#define UMBRA_GPU_QUERIES 4

typedef struct {
    int ready;
    pfn_gen_queries gen;
    pfn_delete_queries del;
    pfn_begin_query begin;
    pfn_end_query end;
    pfn_get_query_uiv available;
    pfn_get_query_ui64v result;
    GLuint ids[UMBRA_GPU_QUERIES];
    int in_flight[UMBRA_GPU_QUERIES];
    GLuint active;      // the query that has been begun and not yet ended
    int next;
} gpu_timer;

static gpu_timer g_gpu_timer;

static void gpu_timer_reset(umbra_app *app) {
    app->gpu_time_us = 0;
    app->gpu_frames = 0;
    for (int i = 0; i < UMBRA_GPU_QUERIES; i++) g_gpu_timer.in_flight[i] = 0;
    if (!g_gpu_timer.ready) return;
    for (int i = 0; i < UMBRA_GPU_QUERIES; i++) {
        if (g_gpu_timer.ids[i]) g_gpu_timer.del(1, &g_gpu_timer.ids[i]);
        g_gpu_timer.ids[i] = 0;
    }
    g_gpu_timer.gen(UMBRA_GPU_QUERIES, g_gpu_timer.ids);
    g_gpu_timer.next = 0;
}

static void gpu_timer_load(umbra_app *app) {
    if (!app->gpu_timer_supported || g_gpu_timer.ready) return;
#ifdef __ANDROID__
    g_gpu_timer.gen = (pfn_gen_queries)eglGetProcAddress("glGenQueriesEXT");
    g_gpu_timer.del = (pfn_delete_queries)eglGetProcAddress("glDeleteQueriesEXT");
    g_gpu_timer.begin = (pfn_begin_query)eglGetProcAddress("glBeginQueryEXT");
    g_gpu_timer.end = (pfn_end_query)eglGetProcAddress("glEndQueryEXT");
    g_gpu_timer.available = (pfn_get_query_uiv)eglGetProcAddress("glGetQueryObjectuivEXT");
    g_gpu_timer.result = (pfn_get_query_ui64v)eglGetProcAddress("glGetQueryObjectui64vEXT");
#endif
    g_gpu_timer.ready = g_gpu_timer.gen && g_gpu_timer.del && g_gpu_timer.begin &&
                        g_gpu_timer.end && g_gpu_timer.available && g_gpu_timer.result;
    umbra_log(app, "gpu timer: %s (EXT_disjoint_timer_query %s)", 
              g_gpu_timer.ready ? "ready" : "unavailable",
              app->gpu_timer_supported ? "advertised" : "not advertised");
}

// Collects any finished queries into the running total. Called once a frame while
// the benchmark runs; a result that is not ready yet stays in flight.
static void gpu_timer_collect(umbra_app *app) {
    if (!g_gpu_timer.ready) return;
    int pending = 0;
    for (int i = 0; i < UMBRA_GPU_QUERIES; i++) pending += g_gpu_timer.in_flight[i] ? 1 : 0;
    if (!pending) return;
#ifdef __ANDROID__
    // A reset of the GPU (a driver recovery, a thermal event) makes every result
    // in flight a number, but not a measurement. The extension says so, and the
    // benchmark then reports that it had no GPU time rather than a wrong one.
    GLint disjoint = 0;
    glGetIntegerv(GL_GPU_DISJOINT_EXT, &disjoint);
    if (disjoint) {
        for (int i = 0; i < UMBRA_GPU_QUERIES; i++) g_gpu_timer.in_flight[i] = 0;
        g_gpu_timer.active = 0;
        app->gpu_time_us = 0;
        app->gpu_frames = 0;
        app->gpu_timer_disjoint = 1;
        app->gpu_timer_supported = 0;
        umbra_log(app, "gpu timer: results discarded, GL_GPU_DISJOINT_EXT was set");
        return;
    }
#endif
    for (int i = 0; i < UMBRA_GPU_QUERIES; i++) {
        if (!g_gpu_timer.in_flight[i]) continue;
        GLuint ready = 0;
        g_gpu_timer.available(g_gpu_timer.ids[i], GL_QUERY_RESULT_AVAILABLE, &ready);
        if (!ready) continue;
        uint64_t ns = 0;
        g_gpu_timer.result(g_gpu_timer.ids[i], GL_QUERY_RESULT, &ns);
        app->gpu_time_us += (int64_t)(ns / 1000);
        app->gpu_frames++;
        g_gpu_timer.in_flight[i] = 0;
    }
}

static void gpu_timer_begin(umbra_app *app) {
    if (!g_gpu_timer.ready || !app->benching) return;
    int slot = g_gpu_timer.next;
    if (!g_gpu_timer.ids[slot] || g_gpu_timer.in_flight[slot]) return;
    g_gpu_timer.begin(GL_TIME_ELAPSED_EXT, g_gpu_timer.ids[slot]);
    g_gpu_timer.active = g_gpu_timer.ids[slot];
    g_gpu_timer.in_flight[slot] = 1;
    g_gpu_timer.next = (slot + 1) % UMBRA_GPU_QUERIES;
}

static void gpu_timer_end(umbra_app *app) {
    (void)app;
    if (!g_gpu_timer.ready || !g_gpu_timer.active) return;
    g_gpu_timer.end(GL_TIME_ELAPSED_EXT);
    g_gpu_timer.active = 0;
}

// --- device checks ---------------------------------------------------------
//
// Everything the app asks the device and every answer: one shared log has to
// explain a phone nobody here can attach a debugger to. A failure that the app can
// live with is a fallback and a line of text, never a crash: the owner has no
// second phone and no PC, so "it closed" is the worst possible outcome.

static void device_note(umbra_app *app, const char *what, const char *answer, int ok) {
    umbra_log(app, "check: %-28s %s%s", what, answer, ok ? "" : "  <-- failed");
}

// Some answers are informational: a driver without timer queries cannot provide
// GPU times, and that is worth a line in the log, not a "<-- failed" beside a
// verdict that says every check passed.
static void device_note_optional(umbra_app *app, const char *what, const char *answer,
                                 int present) {
    umbra_log(app, "check: %-28s %s%s", what, answer, present ? "" : "  (not available)");
}

static void set_fallback(umbra_app *app, const char *reason) {
    if (app->render_fallback && app->fallback_reason[0]) return;
    app->render_fallback = true;
    snprintf(app->fallback_reason, sizeof app->fallback_reason, "%s", reason);
    umbra_log(app, "fallback: %s - drawing with the plain renderer", reason);
}

// What the driver says about itself, and what this app needs from it.
static void device_checks(umbra_app *app) {
    const char *renderer = (const char *)glGetString(GL_RENDERER);
    const char *version = (const char *)glGetString(GL_VERSION);
    device_note(app, "renderer", renderer ? renderer : "(null)", renderer != NULL);
    device_note(app, "gl version", version ? version : "(null)", version != NULL);
    if (!version || !strstr(version, "OpenGL ES 3")) {
        set_fallback(app, version ? "not an OpenGL ES 3 context" : "no GL version string");
    }
    GLint max_tex = 0;
    glGetIntegerv(GL_MAX_TEXTURE_SIZE, &max_tex);
    char buf[128];
    snprintf(buf, sizeof buf, "%d px", (int)max_tex);
    // The scene renders into a framebuffer texture the size of the screen.
    device_note(app, "max texture size", buf, max_tex >= 2048);

    const char *ext = (const char *)glGetString(GL_EXTENSIONS);
    size_t ext_len = 0;
    if (ext) ext_len = strlen(ext);
    int timer_ext = ext && strstr(ext, "GL_EXT_disjoint_timer_query") != NULL;
    app->gpu_timer_supported = timer_ext;
    snprintf(app->gpu_timer_note, sizeof app->gpu_timer_note, "%s",
             timer_ext ? "EXT_disjoint_timer_query" : "none");
    device_note_optional(app, "gpu timer query", app->gpu_timer_note, timer_ext);

    // Every program that linked is reported by name: a shader that fails on one
    // driver and not another is the single most likely device-specific failure.
    snprintf(buf, sizeof buf, "mesh %s, hud %s, pattern %s, cube %s, atlas %s",
             app->prog_mesh ? "ok" : "FAILED", app->prog_hud ? "ok" : "FAILED",
             app->prog_pattern ? "ok" : "FAILED", app->prog_cube ? "ok" : "FAILED",
             app->prog_atlas ? "ok" : "FAILED");
    int all = app->prog_mesh && app->prog_hud && app->prog_pattern && app->prog_cube &&
              app->prog_atlas;
    device_note(app, "shader programs", buf, all);
    if (!app->prog_mesh) set_fallback(app, "the world shader did not compile");
    if (!app->prog_hud) set_fallback(app, "the text shader did not compile");
    if (!app->prog_pattern || !app->prog_cube) {
        // The self-test cannot compare a pipeline it cannot draw with; saying so
        // is worth more than a FAIL that blames the device.
        set_fallback(app, "the self-test shaders did not compile");
    }

    snprintf(buf, sizeof buf, "%d bits", app->depth_bits);
    device_note(app, "depth buffer", buf, app->depth_bits >= 16);
    if (app->depth_bits < 16) set_fallback(app, "no depth buffer");
    snprintf(buf, sizeof buf, "%zu chars", ext_len);
    device_note(app, "extension string", buf, ext != NULL);
    if (app->render_fallback) {
        umbra_log(app, "check: running in fallback: %s", app->fallback_reason);
    } else {
        umbra_log(app, "check: all device checks passed");
    }
}

// --- self test ----------------------------------------------------------
//
// Two passes (a fullscreen pattern and a lit cube), both read back and compared
// pixel by pixel. The first version did all of that inside one frame -- two
// full-frame readbacks and five million comparisons -- and the owner's phone
// logged "SELF-TEST: BEGIN (2292x1080)" and then died: five seconds without a
// frame is an ANR, and an ANR is a force-stop, which the crash marker then reports
// as a crash. So the test is a state machine that does one bounded step per frame,
// logs the start and end of every phase, and gives up with a reason if a phase
// takes longer than the watchdog.

enum {
    ST_IDLE = 0,
    ST_DRAW_PATTERN,
    ST_READ_PATTERN,
    ST_COMPARE_PATTERN,
    ST_DRAW_CUBE,
    ST_READ_CUBE,
    ST_COMPARE_CUBE,
    ST_DRAW_ATLAS,
    ST_COMPARE_ATLAS,
    ST_DONE,
    ST_ABORTED
};

#define UMBRA_SELFTEST_WATCHDOG_US (30 * 1000 * 1000)

static const char *st_state_name(int st) {
    switch (st) {
        case ST_DRAW_PATTERN: return "draw pattern";
        case ST_READ_PATTERN: return "read pattern";
        case ST_COMPARE_PATTERN: return "compare pattern";
        case ST_DRAW_CUBE: return "draw cube";
        case ST_READ_CUBE: return "read cube";
        case ST_COMPARE_CUBE: return "compare cube";
        case ST_DRAW_ATLAS: return "sample the atlas";
        case ST_COMPARE_ATLAS: return "compare the atlas sample";
        case ST_DONE: return "done";
        case ST_ABORTED: return "aborted";
        default: return "idle";
    }
}

static void selftest_free_buffers(umbra_app *app) {
    free(app->st_frame);
    free(app->st_tile);
    app->st_frame = NULL;
    app->st_tile = NULL;
    app->st_frame_bytes = 0;
    app->st_tile_bytes = 0;
}

static void selftest_end(umbra_app *app, bool ok, const char *why) {
    int64_t bad = app->st_pattern_bad + app->st_cube_bad;
    int64_t checked = app->st_pattern_checked + app->st_cube_checked;
    app->selftest_ran = true;
    app->selftest_ok = ok;
    app->selftest_mismatches = bad;
    app->selftest_checked = checked;
    app->selftest_us = umbra_now_us() - app->st_start_us;
    if (ok) {
        snprintf(app->selftest_text, sizeof app->selftest_text,
                 "SELFTEST PASS (0 bad of %lld px + %d atlas texels, %.0f ms, %s, atlas %s)",
                 (long long)checked, app->st_atlas_checked, app->selftest_us / 1000.0,
                 app->st_offscreen ? "offscreen" : "window",
                 app->jar_loaded ? "from the jar" : "placeholder");
    } else if (why && why[0]) {
        snprintf(app->selftest_text, sizeof app->selftest_text, "SELFTEST SKIPPED - %s", why);
    } else {
        snprintf(app->selftest_text, sizeof app->selftest_text,
                 "SELFTEST FAIL (%lld bad of %lld px, %.0f ms, %s)",
                 (long long)bad, (long long)checked, app->selftest_us / 1000.0,
                 app->st_offscreen ? "offscreen" : "window");
    }
    umbra_log(app, "%s", app->selftest_text);
    if (!ok && why && why[0]) {
        umbra_log(app, "self-test: skipped because %s", why);
    }
    if (bad > 0) {
        umbra_log(app, "self-test: first mismatch %s",
                  app->st_bad_text[0] ? app->st_bad_text : "(not recorded)");
    }
    if (app->st_skip_px > 0) {
        umbra_log(app, "self-test: %lld px not compared (under the overlay)",
                  (long long)app->st_skip_px);
    }
    umbra_log(app, "self-test: end after %.0f ms, %d steps",
              app->selftest_us / 1000.0, app->st_steps);
    remember_selftest(app);
    selftest_free_buffers(app);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glViewport(0, 0, app->width, app->height);
    app->st_state = ok ? ST_DONE : ST_ABORTED;
}

static void selftest_abort(umbra_app *app, const char *why) {
    umbra_log(app, "self-test: aborting in %s after %.0f ms: %s", st_state_name(app->st_state),
              (umbra_now_us() - app->st_start_us) / 1000.0, why);
    snprintf(app->st_reason, sizeof app->st_reason, "%s", why);
    selftest_end(app, false, why);
}

// A colour texture plus a depth renderbuffer that the self-test draws into.
// Returns 0 if the driver refuses, and the reason goes in app->st_reason.
static int selftest_begin_target(umbra_app *app, int w, int h) {
    if (!app->fbo_selftest) {
        glGenFramebuffers(1, &app->fbo_selftest);
        glGenTextures(1, &app->tex_selftest);
        glGenRenderbuffers(1, &app->rb_selftest);
    }
    glBindTexture(GL_TEXTURE_2D, app->tex_selftest);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glBindTexture(GL_TEXTURE_2D, 0);
    // 24-bit depth first, because the brief asks for it and the scene uses it;
    // 16 is the fallback for drivers that will not render to 32-bit depth.
    const GLenum depth_formats[2] = {GL_DEPTH_COMPONENT24, GL_DEPTH_COMPONENT16};
    GLenum status = 0;
    for (int attempt = 0; attempt < 2; attempt++) {
        glBindRenderbuffer(GL_RENDERBUFFER, app->rb_selftest);
        glRenderbufferStorage(GL_RENDERBUFFER, depth_formats[attempt], w, h);
        glBindRenderbuffer(GL_RENDERBUFFER, 0);
        glBindFramebuffer(GL_FRAMEBUFFER, app->fbo_selftest);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                               app->tex_selftest, 0);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER,
                                  app->rb_selftest);
        status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        if (status == GL_FRAMEBUFFER_COMPLETE) {
            if (attempt == 1) {
                umbra_log(app, "self-test: 24-bit depth was refused, using 16-bit");
            }
            return 1;
        }
        umbra_log(app, "self-test: framebuffer with depth 0x%x is not complete (status 0x%x)",
                  (unsigned)depth_formats[attempt], (unsigned)status);
    }
    app->st_fbo_status = (unsigned)status;
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    return 0;
}

static void selftest_begin(umbra_app *app) {
    app->st_start_us = umbra_now_us();
    app->st_w = app->width;
    app->st_h = app->height;
    app->st_row = 0;
    app->st_skip_px = 0;
    app->st_pattern_bad = app->st_pattern_checked = 0;
    app->st_cube_bad = app->st_cube_checked = 0;
    app->st_atlas_bad = app->st_atlas_checked = 0;
    // A tile with transparent texels, so the sample proves the alpha channel made
    // it through the upload and not only the colour channels.
    app->st_atlas_slot = (int)umbra_atlas_named((sl_u8){(uint8_t *)"oak_leaves", 10});
    if (app->st_atlas_slot < 0) {
        // A jar that does not spell the texture that way is not a reason to skip the
        // check: stone is in every pack, and any opaque tile still proves the upload.
        app->st_atlas_slot = (int)umbra_atlas_named((sl_u8){(uint8_t *)"stone", 5});
    }
    app->st_tile_rows = umbra_selftest_tile_rows(app->st_w, app->st_h);
    app->st_offscreen = 0;
    app->st_fbo_status = 0;
    app->st_reason[0] = 0;
    app->st_bad_text[0] = 0;
    app->st_steps = 0;
    umbra_selftest_reset();
    (void)glGetError();  // clear anything the last frame left behind
    umbra_log(app, "self-test: begin (%dx%d), tile %d rows", app->st_w, app->st_h,
              app->st_tile_rows);
    if (app->st_w < 16 || app->st_h < 16) {
        selftest_abort(app, "the surface has no size yet");
        return;
    }
    if (app->render_fallback) {
        // Comparing pixels proves nothing when the pipeline that draws them is the
        // reason for the fallback; say that instead of failing the device twice.
        app->st_skip_px = 0;
        snprintf(app->st_reason, sizeof app->st_reason, "fallback renderer: %s",
                 app->fallback_reason);
        selftest_end(app, false, app->st_reason);
        return;
    }
    app->st_offscreen = selftest_begin_target(app, app->st_w, app->st_h);
    if (!app->st_offscreen) {
        umbra_log(app, "self-test: no offscreen target (status 0x%x); comparing the window "
                       "before this frame draws anything else",
                  app->st_fbo_status);
    }
    // One tile buffer is reused by every step; the window path also needs the whole
    // frame, read in one go so the next frame cannot overwrite it.
    app->st_tile_bytes = (size_t)app->st_w * (size_t)app->st_tile_rows * 4;
    app->st_tile = (unsigned char *)malloc(app->st_tile_bytes);
    if (!app->st_tile) {
        selftest_abort(app, "out of memory for the readback buffer");
        return;
    }
    if (!app->st_offscreen) {
        // Without a framebuffer object the only thing to read is the window, and
        // the window has to be read in the same step it was drawn in: by the next
        // frame the scene and the overlay are on top of the pattern and the
        // comparison would be against the wrong picture entirely.
        app->st_frame_bytes = (size_t)app->st_w * (size_t)app->st_h * 4;
        app->st_frame = (unsigned char *)malloc(app->st_frame_bytes);
        if (!app->st_frame) {
            selftest_abort(app, "out of memory for the frame readback");
            return;
        }
    }
    app->st_state = ST_DRAW_PATTERN;
}

// Reads and compares one tile of the current pass. Returns 1 when the pass is
// finished.
static int selftest_compare_step(umbra_app *app, int is_pattern) {
    int x0 = 0, w = app->st_w, h = app->st_h;
    if (app->st_row >= h) return 1;
    int rows = app->st_tile_rows;
    if (app->st_row + rows > h) rows = h - app->st_row;
    size_t bytes = (size_t)w * (size_t)rows * 4;

    if (app->st_offscreen) {
        // Every compare step runs in its own frame, and the frame loop binds the
        // window again after each one. Without this the readback would come from
        // the window and compare the scene against the pattern -- which is what
        // the emulator did before this line existed: "2073600 of 2073600 differ".
        glBindFramebuffer(GL_FRAMEBUFFER, app->fbo_selftest);
        glReadPixels(x0, app->st_row, w, rows, GL_RGBA, GL_UNSIGNED_BYTE, app->st_tile);
        if (glGetError() != GL_NO_ERROR) {
            selftest_abort(app, "glReadPixels failed on the offscreen target");
            return 1;
        }
    }
    const unsigned char *base = app->st_offscreen ? app->st_tile : app->st_frame;
    if (!base) {
        selftest_abort(app, "no readback buffer");
        return 1;
    }
    if (!app->st_offscreen) {
        base += (size_t)app->st_row * (size_t)w * 4;
    }
    int hud_rows_now = hud_rows(app);
    float hud_scale_now = hud_scale(app);
    for (int y = 0; y < rows; y++) {
        const unsigned char *row = base + (size_t)y * (size_t)w * 4;
        int fy = app->st_row + y;
        for (int x = 0; x < w; x++) {
            const unsigned char *p = row + (size_t)x * 4;
            // The overlay is part of the window, not part of the test: in the
            // fallback path its pixels are counted as skipped, never compared.
            if (!app->st_offscreen &&
                !umbra_selftest_compares(x, fy, hud_rows_now, hud_scale_now, app->insets,
                                         app->st_w, app->st_h, &app->st_skip_px)) {
                continue;
            }
            if (is_pattern) {
                umbra_selftest_pattern_pixel(x, fy, w, h, p[0], p[1], p[2]);
            } else {
                umbra_selftest_cube_pixel(x, fy, w, h, p[0], p[1], p[2]);
            }
        }
    }
    app->st_row += rows;
    (void)bytes;
    return app->st_row >= h;
}

// Reads every counter of a finished pass, then clears them. The first version
// read the mismatch count, reset, and then asked for the checked count -- which
// had just been zeroed, so the log said "2073600 of 0 px differ".
static void selftest_take_pass(umbra_app *app, int64_t *bad, int64_t *checked,
                               int64_t *max_diff) {
    *bad = umbra_selftest_mismatches();
    *checked = umbra_selftest_checked();
    *max_diff = umbra_selftest_max_diff();
    if (!app->st_bad_text[0]) {
        int64_t len = 0;
        const uint8_t *t = umbra_selftest_first_bad_text(&len);
        if (len > 0) {
            if (len > (int64_t)sizeof app->st_bad_text - 1) len = (int64_t)sizeof app->st_bad_text - 1;
            memcpy(app->st_bad_text, t, (size_t)len);
            app->st_bad_text[len] = 0;
        }
    }
    umbra_selftest_reset();
}

// One bounded step, called once per frame while the test is running.
static void selftest_step(umbra_app *app) {
    if (app->st_state <= ST_IDLE || app->st_state >= ST_DONE) return;
    app->st_steps++;
    int64_t elapsed = umbra_now_us() - app->st_start_us;
    if (elapsed > UMBRA_SELFTEST_WATCHDOG_US) {
        char why[128];
        snprintf(why, sizeof why, "watchdog: %.0f s in \"%s\"", elapsed / 1e6,
                 st_state_name(app->st_state));
        selftest_abort(app, why);
        return;
    }
    switch (app->st_state) {
        case ST_DRAW_PATTERN: {
            int64_t t0 = umbra_now_us();
            glBindFramebuffer(GL_FRAMEBUFFER, app->st_offscreen ? app->fbo_selftest : 0);
            glViewport(0, 0, app->st_w, app->st_h);
            glDisable(GL_DEPTH_TEST);
            glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
            glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
            glUseProgram(app->prog_pattern);
            glUniform1i(glGetUniformLocation(app->prog_pattern, "u_w"), app->st_w);
            glUniform1i(glGetUniformLocation(app->prog_pattern, "u_h"), app->st_h);
            glBindVertexArray(app->vao_full);
            glDrawArrays(GL_TRIANGLES, 0, 3);
            selftest_gl_check(app, "drawing the pattern");
            glFinish();
            umbra_log(app, "self-test: pattern drawn in %.1f ms into the %s", 
                      (umbra_now_us() - t0) / 1000.0,
                      app->st_offscreen ? "offscreen target" : "window");
            if (!app->st_offscreen) {
                int64_t t1 = umbra_now_us();
                glReadPixels(0, 0, app->st_w, app->st_h, GL_RGBA, GL_UNSIGNED_BYTE,
                             app->st_frame);
                selftest_gl_check(app, "reading the pattern back");
                umbra_log(app, "self-test: read the window back in %.1f ms (%zu bytes)",
                          (umbra_now_us() - t1) / 1000.0, app->st_frame_bytes);
                app->st_row = 0;
                app->st_state = ST_COMPARE_PATTERN;
                break;
            }
            app->st_state = ST_READ_PATTERN;
            break;
        }
        case ST_READ_PATTERN:
            // Offscreen only: the tiles are read as they are compared, so the
            // whole pass arrives here with nothing left to fetch. The window path
            // read its buffer in the draw step, before the scene could paint
            // over the pattern.
            umbra_log(app, "self-test: reading the offscreen target in %d-row tiles",
                      app->st_tile_rows);
            app->st_row = 0;
            app->st_state = ST_COMPARE_PATTERN;
            break;
        case ST_COMPARE_PATTERN:
            if (selftest_compare_step(app, 1)) {
                int64_t max_diff = 0;
                selftest_take_pass(app, &app->st_pattern_bad, &app->st_pattern_checked, &max_diff);
                umbra_log(app, "self-test: pattern compared, %lld of %lld px differ, max channel "
                               "diff %lld",
                          (long long)app->st_pattern_bad, (long long)app->st_pattern_checked,
                          (long long)max_diff);
                app->st_state = ST_DRAW_CUBE;
            }
            break;
        case ST_DRAW_CUBE: {
            int64_t t0 = umbra_now_us();
            glBindFramebuffer(GL_FRAMEBUFFER, app->st_offscreen ? app->fbo_selftest : 0);
            glViewport(0, 0, app->st_w, app->st_h);
            glEnable(GL_DEPTH_TEST);
            glClearColor(0.02f, 0.03f, 0.06f, 1.0f);
            glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
            float proj[16], view[16], vp[16];
            mat4_perspective(proj, 60.0f * 3.14159265f / 180.0f,
                             (float)app->st_w / (float)app->st_h, 0.1f, 100.0f);
            float eye[3] = {0.0f, 0.0f, 3.0f};
            float target[3] = {0.0f, 0.0f, 0.0f};
            float up[3] = {0.0f, 1.0f, 0.0f};
            mat4_look_at(view, eye, target, up);
            mat4_mul(vp, proj, view);
            glUseProgram(app->prog_cube);
            glUniformMatrix4fv(glGetUniformLocation(app->prog_cube, "u_viewproj"), 1, GL_FALSE, vp);
            glBindVertexArray(app->vao_cube);
            glDrawElements(GL_TRIANGLES, 36, GL_UNSIGNED_SHORT, 0);
            selftest_gl_check(app, "drawing the cube");
            glFinish();
            umbra_log(app, "self-test: cube drawn in %.1f ms", (umbra_now_us() - t0) / 1000.0);
            if (!app->st_offscreen) {
                int64_t t1 = umbra_now_us();
                glReadPixels(0, 0, app->st_w, app->st_h, GL_RGBA, GL_UNSIGNED_BYTE,
                             app->st_frame);
                selftest_gl_check(app, "reading the cube back");
                umbra_log(app, "self-test: read the window back in %.1f ms (%zu bytes)",
                          (umbra_now_us() - t1) / 1000.0, app->st_frame_bytes);
                app->st_row = 0;
                app->st_state = ST_COMPARE_CUBE;
                break;
            }
            app->st_state = ST_READ_CUBE;
            break;
        }
        case ST_READ_CUBE:
            app->st_row = 0;
            app->st_state = ST_COMPARE_CUBE;
            break;
        case ST_DRAW_ATLAS: {
            // One 16x16 tile of the production atlas, one texel per pixel. NEAREST
            // magnification means the readback is exact, so anything but equality
            // is a real fault: a row order, a stride, a gutter written over a tile.
            int64_t t0 = umbra_now_us();
            glBindFramebuffer(GL_FRAMEBUFFER, app->st_offscreen ? app->fbo_selftest : 0);
            glViewport(0, 0, app->st_w, app->st_h);
            glDisable(GL_DEPTH_TEST);
            glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
            glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
            glUseProgram(app->prog_atlas);
            glActiveTexture(GL_TEXTURE0);
            glBindTexture(GL_TEXTURE_2D, app->atlas_tex);
            glUniform1i(glGetUniformLocation(app->prog_atlas, "u_atlas"), 0);
            glUniform4f(glGetUniformLocation(app->prog_atlas, "u_rect"),
                        umbra_atlas_tile_u0(app->st_atlas_slot),
                        umbra_atlas_tile_v0(app->st_atlas_slot),
                        umbra_atlas_tile_u1(app->st_atlas_slot),
                        umbra_atlas_tile_v1(app->st_atlas_slot));
            glBindVertexArray(app->vao_full);
            glDrawArrays(GL_TRIANGLES, 0, 3);
            selftest_gl_check(app, "sampling the atlas");
            glFinish();
            int64_t t1 = umbra_now_us();
            glReadPixels(0, 0, 16, 16, GL_RGBA, GL_UNSIGNED_BYTE, app->st_tile);
            if (glGetError() != GL_NO_ERROR) {
                selftest_abort(app, "glReadPixels failed on the atlas sample");
                break;
            }
            umbra_log(app, "self-test: atlas tile %d sampled in %.1f ms",
                      app->st_atlas_slot, (umbra_now_us() - t1) / 1000.0);
            (void)t0;
            app->st_state = ST_COMPARE_ATLAS;
            break;
        }
        case ST_COMPARE_ATLAS: {
            // 256 texels, compared with the CPU decode of the same tile.
            int bad = 0;
            int first_x = -1, first_y = -1;
            int got_r = 0, got_g = 0, got_b = 0, got_a = 0;
            int want_r = 0, want_g = 0, want_b = 0, want_a = 0;
            for (int y = 0; y < 16; y++) {
                for (int x = 0; x < 16; x++) {
                    const unsigned char *p = app->st_tile + (y * 16 + x) * 4;
                    int64_t want = umbra_atlas_texel(app->st_atlas_slot, x, y);
                    if (want < 0) { continue; }
                    int wr = (int)(want & 0xFF), wg = (int)((want >> 8) & 0xFF);
                    int wb = (int)((want >> 16) & 0xFF), wa = (int)((want >> 24) & 0xFF);
                    app->st_atlas_checked++;
                    if (p[0] != wr || p[1] != wg || p[2] != wb || p[3] != wa) {
                        bad++;
                        if (first_x < 0) {
                            first_x = x; first_y = y;
                            got_r = p[0]; got_g = p[1]; got_b = p[2]; got_a = p[3];
                            want_r = wr; want_g = wg; want_b = wb; want_a = wa;
                        }
                    }
                }
            }
            app->st_atlas_bad = bad;
            if (bad > 0) {
                umbra_log(app, "self-test: atlas first mismatch at %d,%d got %d,%d,%d,%d "
                               "want %d,%d,%d,%d", first_x, first_y, got_r, got_g, got_b,
                          got_a, want_r, want_g, want_b, want_a);
            }
            umbra_log(app, "self-test: atlas %d of %d texels differ", bad,
                      app->st_atlas_checked);
            glEnable(GL_DEPTH_TEST);
            selftest_end(app, app->st_pattern_bad == 0 && app->st_cube_bad == 0 && bad == 0,
                         NULL);
            break;
        }
        case ST_COMPARE_CUBE:
            if (selftest_compare_step(app, 0)) {
                int64_t max_diff = 0;
                selftest_take_pass(app, &app->st_cube_bad, &app->st_cube_checked, &max_diff);
                umbra_log(app, "self-test: cube compared, %lld of %lld px differ",
                          (long long)app->st_cube_bad, (long long)app->st_cube_checked);
                app->st_state = ST_DRAW_ATLAS;
            }
            break;
        default:
            break;
    }
}

// The home view's eye: up and to one side, far enough out that the whole world
// fits. Shared by the draw call and the HUD so the numbers on screen are the
// numbers that were used.
static void camera_eye(const umbra_app *app, float eye[3]) {
    // A three-quarter view from about 27 degrees up: (0.62, 0.46, 0.62) normalised,
    // so the eye really is cam_dist away from the point it looks at and the
    // distances in the fog and in the log mean what they say.
    eye[0] = app->look[0] + app->cam_dist * 0.617f;
    eye[1] = app->look[1] + app->cam_dist * 0.458f;
    eye[2] = app->look[2] + app->cam_dist * 0.640f;
}

// --- the player ---------------------------------------------------------

// The grid the player collides with is the world the mesher just built: Goose
// answers "how tall is this cell's collision box", with 0.5 for the slab that is
// drawn from a model. One call per candidate cell, and a cell is only a candidate
// if the body's box overlaps it.
static float app_block_top(void *ctx, int x, int y, int z) {
    (void)ctx;
    return umbra_block_top((int64_t)x, (int64_t)y, (int64_t)z);
}

// And the grid's other question: is this cell water? Asked three times per physics
// step (feet, waist, head) by the same Goose data the mesher drew, so a pond the
// player can see is a pond the body can swim in.
static int app_block_fluid(void *ctx, int x, int y, int z) {
    (void)ctx;
    return (int)umbra_block_fluid((int64_t)x, (int64_t)y, (int64_t)z);
}

// Spawn on top of the middle column, at the floor the world reports. Logged,
// because "the player fell through the world" has to be distinguishable from "the
// player was never spawned".
static void player_spawn(umbra_app *app) {
    // The middle of whatever world is loaded. The demo world is 0..48 and used to be
    // written here as 24,24 in two places; a save's columns can be anywhere, so the
    // position is asked for.
    float cx = (umbra_world_loaded_min_x() + umbra_world_loaded_max_x()) * 0.5f;
    float cz = (umbra_world_loaded_min_z() + umbra_world_loaded_max_z()) * 0.5f;
    // A body is 0.6 wide and 1.8 tall, so the cell it stands in is not enough: a body
    // placed on a cell's *corner* overlaps four cells, and the three it is not standing
    // on can be a hillside. That is exactly what happened once the demo scene's extent
    // was fixed and the spawn moved to the true middle: at 24.0,24.0 the floor is 66 and
    // the column at 24,23 is solid to 69, so the body spawned walled in on three sides
    // and no heading moved it (run 44241902430, four holds of 0.00 blocks). Two rules
    // come out of that: spawn at the *centre* of a cell, never its corner, and only in a
    // cell with two blocks of air above the floor.
    int32_t bx = (int32_t)floorf(cx);
    int32_t bz = (int32_t)floorf(cz);
    float y = 0.0f;
    int found = 0;
    for (int ring = 0; ring <= 6 && !found; ring++) {
        for (int dz = -ring; dz <= ring && !found; dz++) {
            for (int dx = -ring; dx <= ring && !found; dx++) {
                if (ring > 0 && dx != -ring && dx != ring && dz != -ring && dz != ring) continue;
                float fy = umbra_world_spawn((int64_t)(bx + dx), (int64_t)(bz + dz));
                if (fy <= 0.0f) continue;
                int64_t cell = (int64_t)ceilf(fy);
                // Two blocks of air above the floor: the body's own height, rounded up.
                if (umbra_block_top((int64_t)(bx + dx), cell, (int64_t)(bz + dz)) > 0.0f) continue;
                if (umbra_block_top((int64_t)(bx + dx), cell + 1, (int64_t)(bz + dz)) > 0.0f) continue;
                bx += dx;
                bz += dz;
                y = fy;
                found = 1;
            }
        }
    }
    if (!found) {
        // Print what the scan actually saw before falling back. A spawn at the top of the
        // world says the terrain read "solid" everywhere, and the two ways that happens
        // (a wrong column, a wrong air test) cannot be told apart from the fallback alone.
        // Cost: one line, only when the spawn has already failed.
        char seen[256];
        int nseen = 0;
        for (int wy = 130; wy >= 40 && nseen + 24 < (int)sizeof seen; wy -= 10) {
            float t = umbra_block_top((int64_t)bx, (int64_t)wy, (int64_t)bz);
            nseen += snprintf(seen + nseen, sizeof seen - (size_t)nseen, " y%d=%.0f",
                              wy, t);
        }
        umbra_log(app, "player: the scan at %d,%d saw%s", bx, bz, seen);
        y = umbra_world_spawn((int64_t)bx, (int64_t)bz);
        umbra_log(app, "player: no open cell within 6 blocks of %d,%d; standing on the "
                       "middle at floor %.2f, which may be walled in", bx, bz, y);
    } else if (bx != (int32_t)floorf(cx) || bz != (int32_t)floorf(cz)) {
        umbra_log(app, "player: the middle of the world is walled in; spawning at %d,%d "
                       "(floor %.2f), the nearest open cell", bx, bz, y);
    }
    // The centre of the cell, not its corner: a body at the corner is inside four cells.
    umbra_player_reset(&app->player, (float)bx + 0.5f, y + 0.01f, (float)bz + 0.5f);
    app->player.yaw = 0.0f;
    app->player.pitch = -0.25f;
    app->player_on = 1;
    app->touch_look_id = -1;
    app->touch_walk_id = -1;
    app->sneak_touch_id = -1;
    app->sneak_held = 0;
    app->player_logged_us = 0;
    umbra_log(app, "player: spawned at %.2f %.2f %.2f (floor %.2f), eye %.2f",
              app->player.x, app->player.y, app->player.z, y,
              app->player.y + UMBRA_PLAYER_EYE);
    // The window follows the body, and it starts where the body starts. Centring here, on
    // the spawn the app just chose, is what makes a save whose origin is not its spawn
    // work: `wl_import_end_streamed` filled the window around the save's *origin* (0,0),
    // and a player put at the middle of the loaded bounds may be nowhere near it. Asking
    // for the window around the body supersedes it, and the evictions of the origin window
    // are the first thing the log reports.
    if (app->stream_state != 0 || world_stream_armed(app) == 0) {
        // No stream on this world: the demo scene, or a save with no region files.
        return;
    }
    int pcx = (int)floorf(app->player.x / 16.0f);
    int pcz = (int)floorf(app->player.z / 16.0f);
    stream_start(app, pcx, pcz, (int)umbra_world_radius_setting());
}

// One physics step with the current input. dt is the real frame time, and the
// step function sub-steps it, so a long frame cannot walk the body through a wall.
static void player_update(umbra_app *app) {
    if (!app->player_on) return;
    float dt = app->frame_us / 1000000.0f;
    if (dt <= 0.0f || dt > 1.0f) dt = 1.0f / 60.0f;
    // Hold to walk. A finger that rests on the screen without turning the head is
    // a walk, which is the one gesture a single finger can make on a phone: drag to
    // look, rest to walk, tap to jump. The 400 ms delay is what keeps a tap from
    // also being a step.
    int64_t now_us = umbra_now_us();
    if (app->touch_walk_id < 0 && app->touch_look_id >= 0 && !app->touch_moved &&
        now_us - app->touch_down_us > 400000 && !app->move_fwd) {
        app->move_fwd = 1;
        app->touch_walk_id = app->touch_look_id;
        umbra_log(app, "player: holding, walking forward");
    }
    umbra_player_world world;
    world.top = app_block_top;
    world.fluid = app_block_fluid;
    world.ctx = app;
    umbra_player_input in;
    in.forward = (float)(app->move_fwd - app->move_back);
    in.strafe = (float)(app->move_right - app->move_left);
    in.jump = app->jump_wanted;
    in.sneak = app->sneak_held;
    int was_water = app->player.in_water;
    umbra_player_update(&world, &app->player, dt, in);
    app->jump_wanted = 0;
    // Entering or leaving water is logged once, because "why is the body slow" and
    // "why did it stop walking on the pond floor" are the two questions a phone log
    // has to be able to answer.
    if (app->player.in_water != was_water) {
        umbra_log(app, app->player.in_water ? "player: entered water, swimming"
                                            : "player: out of the water");
    }
    // Has the player walked far enough from the middle of the window that a chunk at its
    // edge should be dropped and one ahead of them parsed? `stream_maybe_recentre` is
    // cheap when the answer is no (two comparisons), and it is called every frame because
    // the alternative -- centring on a border chunk -- re-meshes the world every step.
    stream_maybe_recentre(app);
    // Once every two seconds, so a phone log says where the body is and whether it
    // is standing, without the log costing anything.
    int64_t now = umbra_now_us();
    if (app->player_logged_us == 0 || now - app->player_logged_us > 2000000) {
        app->player_logged_us = now;
        umbra_log(app, "player: at %.2f %.2f %.2f, yaw %.2f pitch %.2f, %s, %lld steps up%s",
                  app->player.x, app->player.y, app->player.z, app->player.yaw,
                  app->player.pitch,
                  app->player.in_water ? "swimming"
                                       : (app->player.on_ground ? "on ground" : "in the air"),
                  (long long)app->player.stepped,
                  app->player.sneaking ? ", sneaking" : "");
    }
}

// The block under the crosshair: what the ray from the eye hits, and what the two
// buttons do to it. The work is Goose's (ray, edit, re-mesh); this only carries the
// eye and the look direction and reports what came back.
static void player_act(umbra_app *app) {
    if (app->act_wanted < 0) return;
    int kind = app->act_wanted;
    app->act_wanted = -1;
    if (!app->player_on) return;
    if (app->mesh_state == 1) {
        umbra_log(app, "player: %s refused, still meshing",
                  kind == 0 ? "break" : "place");
        return;
    }
    float eye[3], fwd[3];
    umbra_player_eye(&app->player, eye);
    umbra_player_forward(&app->player, fwd);
    int64_t code = umbra_player_act((int64_t)kind, eye[0], eye[1], eye[2],
                                    fwd[0], fwd[1], fwd[2], UMBRA_PLAYER_REACH);
    const uint8_t *said = NULL;
    int64_t said_len = 0;
    said = umbra_act_text(&said_len);
    int n = 0;
    if (said && said_len > 0) {
        for (int64_t i = 0; i < said_len && n + 1 < (int)sizeof app->act_text; i++) {
            app->act_text[n++] = (char)said[i];
        }
    }
    app->act_text[n] = 0;
    umbra_log(app, "player: %s -> %lld (%s)", kind == 0 ? "break" : "place",
              (long long)code, app->act_text[0] ? app->act_text : "no change");
    if (code == 1) {
        // The world changed, and Goose has begun a re-mesh: the frame loop picks it up
        // through the same sliced stepper as the first mesh, so nothing is uploaded
        // until the new mesh is complete.
        app->act_edits++;
        // Saved now, not at exit: an app that is killed by the system (which is how a
        // phone ends most apps) never gets an exit.
        {
            int64_t n = umbra_edit_count();
            if (n > 0) {
                int64_t len = 0;
                const uint8_t *line = umbra_edit_line(n - 1, &len);
                if (line && len > 0) {
                    if (edits_append(app, (const char *)line, len)) {
                        app->edits_saved++;
                    }
                }
            }
        }
        app->mesh_state = 1;
        app->mesh_progress = 0;
        app->mesh_calls = 0;
        app->mesh_total_us = 0;
        app->mesh_worst_call_us = 0;
        // Question (d) starts here: the finger has lifted, the world has changed, and the
        // clock starts on "when does a person see it".
        app->edit_applied_us = umbra_now_us();
        app->edit_mesh_done_us = 0;
        app->edit_wait_us = 0;
        app->edit_upload_us = 0;
        app->edit_pending_present = 0;
        // The old mesh stays on screen and stays uploaded while the new one is built:
        // blanking the world for a moment is worse than a block that disappears a few
        // frames late.
        umbra_log(app, "player: re-meshing %lld column(s) after edit %d", 
                  (long long)umbra_edit_column_count(), app->act_edits);
    }
}

// --- frame --------------------------------------------------------------

static void draw_scene(umbra_app *app) {
    float proj[16], view[16], vp[16];
    // The home view is a fixed three-quarter view, framed from the mesh extent
    // and not from a hand-tuned number: the screenshot gate compares one run
    // with the next, so the scene must not drift while it is being captured.
    float near_z = app->cam_dist * 0.02f;
    if (near_z < 0.05f) near_z = 0.05f;
    float far_z = app->cam_dist * 4.0f + app->span[0] + app->span[1] + app->span[2];
    mat4_perspective(proj, app->fov_y * 3.14159265f / 180.0f, (float)app->width / (float)app->height, near_z, far_z);
    float eye[3];
    float target[3];
    if (app->player_on) {
        // First person: the eye is the body's eye and the target is one block along
        // the look direction. The fog moves with the view, so it is a depth cue at
        // the distance a walking body can actually see.
        float f[3];
        umbra_player_eye(&app->player, eye);
        umbra_player_forward(&app->player, f);
        target[0] = eye[0] + f[0];
        target[1] = eye[1] + f[1];
        target[2] = eye[2] + f[2];
        near_z = 0.05f;
        far_z = 320.0f;
        mat4_perspective(proj, app->fov_y * 3.14159265f / 180.0f,
                         (float)app->width / (float)app->height, near_z, far_z);
    } else {
        camera_eye(app, eye);
        target[0] = app->look[0];
        target[1] = app->look[1];
        target[2] = app->look[2];
    }
    app->eye[0] = eye[0];
    app->eye[1] = eye[1];
    app->eye[2] = eye[2];
    float up[3] = {0.0f, 1.0f, 0.0f};
    mat4_look_at(view, eye, target, up);
    mat4_mul(vp, proj, view);
    // The overlay covers the top of the screen, so the scene is centred in what
    // is left of it: shift every clip-space y by k * w.
    float band_top = 0.0f, band_bottom = 0.0f;
    umbra_hud_scene_band(hud_rows(app), hud_scale(app), app->insets, app->width, app->height,
                         &band_top, &band_bottom);
    float shift = umbra_hud_band_shift(band_top, band_bottom, app->height);
    if (shift != 0.0f) {
        for (int col = 0; col < 4; col++) {
            vp[1 + 4 * col] += shift * vp[3 + 4 * col];
        }
    }
    glUseProgram(app->prog_mesh);
    glUniformMatrix4fv(glGetUniformLocation(app->prog_mesh, "u_viewproj"), 1, GL_FALSE, vp);
    if (app->player_on) {
        // Two blocks away is clear, 90 is sky: a walking body sees further than the
        // overview camera, which is framed from outside the island.
        glUniform2f(glGetUniformLocation(app->prog_mesh, "u_fog"), 24.0f, 96.0f);
        glUniform3f(glGetUniformLocation(app->prog_mesh, "u_center"), app->player.x,
                    app->player.y, app->player.z);
    } else {
        glUniform2f(glGetUniformLocation(app->prog_mesh, "u_fog"), app->fog_near, app->fog_far);
        glUniform3f(glGetUniformLocation(app->prog_mesh, "u_center"), app->center[0],
                    app->center[1], app->center[2]);
    }
    glBindVertexArray(app->vao_mesh);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, app->ibo_mesh);
    // PASS_OPAQUE and PASS_CUTOUT draw with depth writing on; PASS_TRANSLUCENT
    // blends with depth writes off, which is the vanilla order.
    app->draw_calls = 0;
    int slots = (int)umbra_range_slots();
    for (int pass = PASS_OPAQUE; pass <= PASS_TRANSLUCENT; pass++) {
        int b = pass - PASS_OPAQUE;
        if (app->batch_count[b] <= 0) continue;
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, app->atlas_tex);
        glUniform1i(glGetUniformLocation(app->prog_mesh, "u_atlas"), 0);
        // Opaque and cutout discard nothing and blend nothing; cutout discards
        // the transparent texels so leaves have holes and still write depth.
        glUniform1i(glGetUniformLocation(app->prog_mesh, "u_cutout"),
                    pass == PASS_CUTOUT ? 1 : 0);
        // Back faces of solid blocks are half the triangles in a naive mesher;
        // this pass is the one that can drop them, because every face in it is
        // the outside of a box. Plants live in the cutout pass, which stays
        // two-sided.
        if (pass == PASS_OPAQUE) {
            glEnable(GL_CULL_FACE);
            glCullFace(GL_BACK);
        } else {
            glDisable(GL_CULL_FACE);
        }
        if (pass == PASS_TRANSLUCENT) {
            glEnable(GL_BLEND);
            glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
            glDepthMask(GL_FALSE);
        }
        // One range per column: an edit rewrites one of these and nothing else, so the
        // draw call count changes with the world but never with the edit.
        for (int i = 0; i < slots; i++) {
            if ((int)umbra_range_batch(i) != b) continue;
            int64_t len = umbra_range_index_len(i);
            if (len <= 0) continue;
            glDrawElements(GL_TRIANGLES, (GLsizei)len, GL_UNSIGNED_INT,
                           (void *)(uintptr_t)(umbra_range_index(i) * 4));
            app->draw_calls++;
        }
        if (pass == PASS_TRANSLUCENT) {
            glDepthMask(GL_TRUE);
            glDisable(GL_BLEND);
        }
    }
    glDisable(GL_CULL_FACE);
}

// Rows the overlay draws: the title (1.6 rows, it has its own spacing), five
// facts, the mesh line, the self-test, the benchmark block, the last-run block
// and the crash tail. Needed before anything is drawn, because the backdrop's
// height and the text scale both depend on it.
//
// It is a float, and it counts the blank rows the drawing code advances through,
// because it *is* the drawing code's walk: the first version counted whole rows
// and forgot the title's 1.6-row spacing, so on a phone the last three lines --
// the crash tail, the one people need -- were drawn below the panel on bare sky.
static float hud_content_rows(const umbra_app *app) {
    int bench_lines = 0;
    if (app->benching) {
        bench_lines = 1;
    } else if (app->bench_text[0]) {
        bench_lines = 1;
        for (const char *q = app->bench_text; *q; q++) {
            if (*q == '\n') bench_lines++;
        }
    }
    // The fallback line is part of the panel, so the panel is a row taller while
    // it is shown -- and the self-test's overlay skip uses the same count.
    return umbra_hud_rows(bench_lines, app->last_run_lines, app->previous_run_crashed ? 1 : 0) +
           (app->render_fallback ? 1 : 0);
}

static int hud_rows(const umbra_app *app) {
    float rows = hud_content_rows(app);
    int whole = (int)rows;
    if ((float)whole < rows) whole++;                 // round up: the panel may be tall, never short
    return whole;
}

// The hotbar and the two action buttons. Drawn only in first person, because in the
// overview the buttons belong to the home screen; drawn from the same rects the taps
// are tested against (umbra_hud.h), so what is drawn and what is tapped is one thing.
static void draw_hands(umbra_app *app) {
    if (!app->player_on) return;
    if (app->mesh_state == 1) return;
    float s = hand_scale(app);
    // The labels are text, not targets: they keep the overlay's readable size instead of
    // growing to the size of a finger.
    float text_s = hud_scale(app);
    // The automated run taps these by reading their rects back, so a layout change
    // cannot silently make it tap empty space (the home screen's buttons are logged the
    // same way, for the same reason).
    if (app->hands_logged_width != app->width) {
        app->hands_logged_width = app->width;
        for (int i = 0; i < UMBRA_HOTBAR_SLOTS; i++) {
            umbra_rect r = umbra_hud_hotbar_slot(i, app->width, app->height, app->insets, s);
            umbra_log(app, "hud: hand hotbar %d at %d,%d size %dx%d on %dx%d", i,
                      (int)r.x, (int)r.y, (int)r.w, (int)r.h, app->width, app->height);
        }
        for (int i = 0; i < 2; i++) {
            umbra_rect r = umbra_hud_action(i, app->width, app->height, app->insets, s);
            umbra_log(app, "hud: hand %s at %d,%d size %dx%d on %dx%d",
                      i == 0 ? "break" : "place", (int)r.x, (int)r.y, (int)r.w, (int)r.h,
                      app->width, app->height);
        }
        umbra_rect sr = umbra_hud_sneak(app->width, app->height, app->insets, s);
        umbra_log(app, "hud: hand sneak at %d,%d size %dx%d on %dx%d (held)",
                  (int)sr.x, (int)sr.y, (int)sr.w, (int)sr.h, app->width, app->height);
    }
    for (int i = 0; i < UMBRA_HOTBAR_SLOTS; i++) {
        umbra_rect r = umbra_hud_hotbar_slot(i, app->width, app->height, app->insets, s);
        int sel = (i == app->hotbar_sel);
        hud_rect(r.x, r.y, r.w, r.h, sel ? 1.0f : 0.0f, sel ? 0.85f : 0.0f,
                 sel ? 0.3f : 0.0f, sel ? 0.55f : 0.35f);
        const uint8_t *name = NULL;
        int64_t name_len = 0;
        name = umbra_hotbar_name((int64_t)i, &name_len);
        char label[32];
        int n = 0;
        for (int64_t k = 0; k < name_len && n + 1 < (int)sizeof label; k++) {
            label[n++] = (char)name[k];
        }
        label[n] = 0;
        float ts = text_s * 0.7f;
        float tw = hud_text_width(label, ts);
        hud_text(r.x + (r.w - tw) * 0.5f, r.y - UMBRA_HUD_ROW_HEIGHT * ts * 1.4f, ts,
                 sel ? 1.0f : 0.75f, sel ? 0.95f : 0.8f, sel ? 0.6f : 0.85f, 1, label);
    }
    {
        umbra_rect r = umbra_hud_sneak(app->width, app->height, app->insets, s);
        int on = app->sneak_held;
        hud_rect(r.x, r.y, r.w, r.h, on ? 0.15f : 0.2f, on ? 0.55f : 0.2f, on ? 0.85f : 0.25f, 0.5f);
        const char *label = on ? "SNEAKING" : "SNEAK";
        float ts = text_s * 0.8f;
        float tw = hud_text_width(label, ts);
        hud_text(r.x + (r.w - tw) * 0.5f, r.y + (r.h - UMBRA_HUD_ROW_HEIGHT * ts) * 0.5f,
                 ts, 1, 1, 1, 1, label);
    }
    static const char *action_names[2] = { "BREAK", "PLACE" };
    for (int i = 0; i < 2; i++) {
        umbra_rect r = umbra_hud_action(i, app->width, app->height, app->insets, s);
        hud_rect(r.x, r.y, r.w, r.h, i == 0 ? 0.75f : 0.25f, i == 0 ? 0.25f : 0.55f, 0.25f, 0.5f);
        float ts = text_s * 0.8f;
        float tw = hud_text_width(action_names[i], ts);
        hud_text(r.x + (r.w - tw) * 0.5f, r.y + (r.h - UMBRA_HUD_ROW_HEIGHT * ts) * 0.5f,
                 ts, 1, 1, 1, 1, action_names[i]);
    }
}

// --- the "get game files" screen -----------------------------------------
//
// The CI emulator gets its jar pushed to /data/local/tmp by the harness; a phone
// gets nothing, so before this screen existed the phone drew the placeholder atlas
// (D-043). This is the C half of the flow: the buttons, the job, and the state the
// screen shows. The rules are Goose's -- the pin, the sha1 check, the wording --
// and the bytes come from the platform (Java's HttpURLConnection, or a content Uri
// copy). Nothing here decides whether a jar is the right one.

static void gf_copy(umbra_app *app, const uint8_t *text, int64_t len, char *dst, size_t cap) {
    size_t n = 0;
    if (text) {
        for (int64_t i = 0; i < len && n + 1 < cap; i++) dst[n++] = (char)text[i];
    }
    dst[n] = 0;
    (void)app;
}

// Refreshes the screen's words from Goose, in the state the flow is in.
static void gf_say(umbra_app *app, int kind, long long now, long long total, const char *extra) {
    const char *ex = extra ? extra : "";
    umbra_gf_state_set((int64_t)kind, (int64_t)now, (int64_t)total,
                       (sl_u8){(uint8_t *)ex, (int64_t)strlen(ex)});
    int64_t n = 0;
    gf_copy(app, umbra_gf_state_text(&n), n, app->gf_text, sizeof app->gf_text);
    gf_copy(app, umbra_gf_state_detail(&n), n, app->gf_detail, sizeof app->gf_detail);
    app->gf_state = kind;
}

// The jar is in place: load it, then build the atlas and the world from it. This
// is the same path start-up takes when it finds a jar; the difference is that the
// app is already running, so the old (placeholder) mesh has to be thrown away.
static void gf_adopt_jar(umbra_app *app) {
    int64_t code = umbra_jar_load((sl_u8){(uint8_t *)app->jar_path,
                                          (int64_t)strlen(app->jar_path)});
    app->jar_code = (int)code;
    if (code != 1) {
        umbra_log(app, "gamefiles: the verified jar would not load (code %lld)", (long long)code);
        gf_say(app, (int)umbra_gf_state_failed(), 0, 0,
               "the jar passed its checksum but could not be read as a jar");
        return;
    }
    app->jar_loaded = true;
    app->jar_models = (int)umbra_jar_models();
    app->jar_blockstates = (int)umbra_jar_blockstates();
    app->jar_textures = (int)umbra_jar_textures();
    app->jar_textures_missing = (int)umbra_jar_textures_missing();
    app->jar_bytes = (long long)umbra_jar_bytes();
    umbra_log(app, "jar: %s, %lld bytes: %d models, %d blockstates, %d textures "
                   "(%d missing) -- the atlas and the models are the jar's",
              app->jar_path, app->jar_bytes, app->jar_models, app->jar_blockstates,
              app->jar_textures, app->jar_textures_missing);
    upload_atlas(app);
    // The placeholder geometry is the wrong geometry now: the demo world is rebuilt
    // and re-meshed in slices, exactly as at start-up.
    begin_scene(app);
    char detail[192];
    snprintf(detail, sizeof detail, "%d models, %d textures, %d missing",
             app->jar_models, app->jar_textures, app->jar_textures_missing);
    gf_say(app, (int)umbra_gf_state_ready(), 0, 0, detail);
    umbra_log(app, "gamefiles: ready: %s", app->gf_detail);
}

// Runs a job to completion on the calling thread and records what to do next. Both
// jobs take tens of seconds over the network, which is why the caller is a worker
// thread and not the frame loop.
typedef struct {
    umbra_app *app;
    int kind;            // 1 download, 2 import
} gf_job_args;

static void *gf_job_thread(void *arg) {
    gf_job_args *job = (gf_job_args *)arg;
    umbra_app *app = job->app;
    char part[512];
    int64_t n = 0;
    // The .part name comes from Goose (core/gamefiles.goose), so the name the app
    // writes and the name the check and the rename use are one string, decided in
    // the file the tests can reach.
    const uint8_t *pp = umbra_gf_part_path((sl_u8){(uint8_t *)app->files_dir,
                                                   (int64_t)strlen(app->files_dir)}, &n);
    gf_copy(app, pp, n, part, sizeof part);
    long long got = -1;
    if (job->kind == 1) {
        got = -1;
        if (!app->download_fn) {
            gf_say(app, (int)umbra_gf_state_failed(), 0, 0,
                   "this build has no way to download files");
            app->gf_done = 1;
            free(job);
            return NULL;
        }
        gf_say(app, (int)umbra_gf_state_downloading(), 0, (long long)umbra_gf_pinned_bytes(), "");
        umbra_log(app, "gamefiles: downloading %lld bytes from Mojang", (long long)umbra_gf_pinned_bytes());
        int rc = app->download_fn(app->net_ctx, (const char *)app->gf_url, part, &got);
        if (rc != 0 || got <= 0) {
            char why[192];
            snprintf(why, sizeof why, "the download failed (%s)", app->gf_platform_error);
            umbra_log(app, "gamefiles: %s", why);
            gf_say(app, (int)umbra_gf_state_failed(), 0, 0, why);
            app->gf_done = 1;
            free(job);
            return NULL;
        }
        umbra_log(app, "gamefiles: the download finished: %lld bytes in %s", got, part);
    } else {
        if (!app->pick_file_fn) {
            gf_say(app, (int)umbra_gf_state_failed(), 0, 0,
                   "this build has no way to open a file picker");
            app->gf_done = 1;
            free(job);
            return NULL;
        }
        got = -1;
        int rc = app->pick_file_fn(app->net_ctx, part, "*/*", &got);
        if (rc != 0 || got <= 0) {
            char why[192];
            snprintf(why, sizeof why, "no file was imported (%s)", app->gf_platform_error);
            umbra_log(app, "gamefiles: %s", why);
            gf_say(app, (int)umbra_gf_state_failed(), 0, 0, why);
            app->gf_done = 1;
            free(job);
            return NULL;
        }
        umbra_log(app, "gamefiles: the picked file was copied: %lld bytes in %s", got, part);
    }

    // Whatever arrived has to prove itself before it is given the jar's name.
    gf_say(app, (int)umbra_gf_state_verifying(), 0, 0, "");
    int64_t ok;
    if (job->kind == 1) {
        ok = umbra_gf_check_file((sl_u8){(uint8_t *)part, (int64_t)strlen(part)});
    } else {
        ok = umbra_gf_import_verdict((sl_u8){(uint8_t *)part, (int64_t)strlen(part)}, got);
    }
    const uint8_t *why = NULL;
    if (job->kind == 1) {
        why = umbra_gf_check_reason(&n);
    } else {
        why = umbra_gf_import_message(&n);
    }
    char reason[192];
    gf_copy(app, why, n, reason, sizeof reason);
    char digest[64];
    gf_copy(app, umbra_gf_digest(&n), n, digest, sizeof digest);
    if (ok != 1) {
        umbra_log(app, "gamefiles: the file was refused: %s", reason);
        remove(part);
        char detail[192];
        snprintf(detail, sizeof detail, "%s", reason);
        gf_say(app, (int)umbra_gf_state_failed(), 0, 0, detail);
        app->gf_done = 1;
        free(job);
        return NULL;
    }
    umbra_log(app, "gamefiles: the file is the pinned jar: %lld bytes, sha1 %s", got, digest);
    if (rename(part, app->jar_path) != 0) {
        char why2[192];
        snprintf(why2, sizeof why2, "the checked file could not be renamed into place");
        umbra_log(app, "gamefiles: %s", why2);
        remove(part);
        gf_say(app, (int)umbra_gf_state_failed(), 0, 0, why2);
        app->gf_done = 1;
        free(job);
        return NULL;
    }
    umbra_log(app, "gamefiles: %s is now the app's client jar (%lld bytes, sha1 %s)",
              app->jar_path, got, digest);
    app->gf_adopt = 1;
    app->gf_state = (int)umbra_gf_state_ready();
    gf_say(app, (int)umbra_gf_state_ready(), 0, 0, "checking it as the world's textures");
    app->gf_done = 1;
    free(job);
    return NULL;
}

// Starts a job on a worker thread. The frame loop never blocks: it polls
// umbra_gf_progress() for the bar and gf_done for the end.
static void gf_start(umbra_app *app, int kind) {
    if (app->gf_job != 0) {
        umbra_log(app, "gamefiles: a job is already running (%d)", app->gf_job);
        return;
    }
    gf_job_args *job = (gf_job_args *)calloc(1, sizeof *job);
    if (!job) {
        gf_say(app, (int)umbra_gf_state_failed(), 0, 0, "out of memory");
        return;
    }
    job->app = app;
    job->kind = kind;
    app->gf_job = kind;
    app->gf_done = 0;
    app->gf_adopt = 0;
    app->gf_got = 0;
    app->gf_total = (long long)umbra_gf_pinned_bytes();
    umbra_log(app, "gamefiles: %s started", kind == 1 ? "download" : "import");
#ifdef __ANDROID__
    // A worker, because the job is tens of seconds of network I/O, and the whole
    // point of the sliced mesher is that the frame loop never waits.
    pthread_t th;
    if (pthread_create(&th, NULL, gf_job_thread, job) == 0) {
        pthread_detach(th);
    } else {
        umbra_log(app, "gamefiles: could not start a worker; running the job on this thread");
        gf_job_thread(job);
    }
#else
    // The desktop host has no network hook and no picker: run it here so the
    // failure is immediate and says so.
    gf_job_thread(job);
#endif
}

// --- opening a world the game generated ----------------------------------
//
// The screen's fifth button. What it does, in the order a person sees it:
//
//   1. If a world archive is already in the app's own directory (`world.zip`), it is
//      opened from there without a picker. That is the path the automated run and a
//      phone that was handed a file with adb both take, and it is why the feature can be
//      proved on a device: the picker's answer cannot be scripted on an emulator.
//   2. Otherwise the file picker is asked for a zip, and what it copies is opened.
//
// The import itself is four Goose calls (core/worldload_in.goose): begin, one region
// entry per call, end. They run here, on the frame thread, between two frames and not
// inside one: the archive is pushed, the region files walked, and the mesh begun, all
// before the next draw. A window of a save is a second of work; the *mesh* of it is still
// the sliced pass, so the loading screen is what a person watches, exactly as for the
// demo world.
static int file_exists_at(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    fclose(f);
    return 1;
}

// Remove a file if it is there. A part-file that failed its download has to go, or the
// next attempt's byte count starts from the old one.
static void delete_file_at(const char *path) {
    if (file_exists_at(path)) remove(path);
}

// The numbers an import produced, in the log. One line, because the first thing anyone
// asks about a save is whether it is the world they think it is.
static void world_report(umbra_app *app, const char *when, int64_t took_us) {
    int64_t n = 0;
    const uint8_t *msg = umbra_world_import_message(&n);
    char text[192];
    gf_copy(app, msg, n, text, sizeof text);
    // A streamed import read no chunk, so the import's own counters ("states 0", "left
    // out N") are about a reader that did not run. The numbers that describe the world on
    // the screen are the stream's, and they are printed here or not at all: a report that
    // quotes a zero from the wrong counter is worse than one that quotes nothing.
    if (umbra_world_stream_open() == 1 && umbra_world_stream_resident() > 0) {
        // The wording is not free: tools/emulator_smoke.sh reads this line by position.
        // It wants `world: <when>:` so it can find the line, then a leading chunk count,
        // then `<n> non-air blocks`, then `<n> read errors`. A streamed world has to keep
        // that contract or the device test dies on a line it cannot parse -- which is the
        // failure this comment exists to prevent, because the tempting thing to write is
        // the more accurate prose that breaks it.
        umbra_log(app, "world: %s: %lld chunk(s) from %lld region file(s), radius %lld, "
                       "non-air blocks %lld, read errors %lld, %lld chunk(s) parsed by the "
                       "stream, missing from the save %lld, %.1f MB of region files, "
                       "%.1f ms",
                  when, (long long)umbra_world_stream_resident(),
                  (long long)umbra_world_import_files(),
                  (long long)umbra_world_import_radius(),
                  (long long)umbra_world_import_blocks(),
                  (long long)umbra_world_stream_errors(),
                  (long long)umbra_world_stream_loaded(),
                  (long long)umbra_world_stream_missing(),
                  umbra_world_stream_bytes() / (1024.0 * 1024.0), took_us / 1000.0);
    }
    app->world_files = (int)umbra_world_import_files();
    app->world_chunks = (long long)umbra_world_import_chunks();
    app->world_blocks = (long long)umbra_world_import_blocks();
    app->world_states = (long long)umbra_world_import_states();
    app->world_errors = (long long)umbra_world_import_errors();
    app->world_partial = (long long)umbra_world_import_partial();
    app->world_skipped = (long long)umbra_world_import_skipped();
    // The import's own line is for the case the import did the reading. In stream mode it
    // did not, and its counters describe work that never happened -- which is how a
    // report ends up saying "states 0" about a world that is drawing 81 chunks.
    int streamed = umbra_world_stream_open() == 1 && umbra_world_stream_resident() > 0;
    if (!streamed) {
        umbra_log(app, "world: %s: %s -- files %d, entries %lld, chunks %lld, "
                       "non-air blocks %lld, states %lld, read errors %lld, not-full chunks "
                       "%lld, left out %lld, %.1f ms",
                  when, text, app->world_files,
                  (long long)umbra_world_import_entries(), app->world_chunks, app->world_blocks,
                  app->world_states, app->world_errors, app->world_partial, app->world_skipped,
                  took_us / 1000.0);
    }
    snprintf(app->world_text, sizeof app->world_text, "%.*s", 150, text);
}

// The world is rebuilt from the columns the import left behind. The old mesh is dropped,
// the arena is re-planned for a different number of columns, and the camera is re-fitted
// from the new bounds -- a save is nowhere near 0..48, so every number that was folded in
// from the demo world's shape has to come from the world that is actually loaded.
static void rebuild_world(umbra_app *app) {
    umbra_demo_mesh_begin();
    app->mesh_state = 1;
    app->mesh_progress = 0;
    app->mesh_calls = 0;
    app->mesh_worst_call_us = 0;
    app->mesh_total_us = 0;
    app->first_draw_timed = 0;
    app->player_on = 0;
    app->mesh_uploaded = 0;
    umbra_app_set_screen(app, UMBRA_SCREEN_LOADING);
    umbra_log(app, "world: meshing %lld column(s) of the opened world, sliced as before",
              (long long)umbra_world_columns());
}

// Open one archive, from a path. Returns 1 when a world is open and the mesh has begun.
static int world_open_path(umbra_app *app, const char *path, const char *how) {
    int64_t t0 = umbra_now_us();
    umbra_log(app, "world: opening %s (%s)", path, how);
    int64_t regions = umbra_world_import_begin((sl_u8){(uint8_t *)path, (int64_t)strlen(path)});
    if (regions <= 0) {
        world_report(app, "refused", umbra_now_us() - t0);
        app->world_state = 3;
        return 0;
    }
    umbra_log(app, "world: the archive holds %lld region file(s)", (long long)regions);
    // One call per entry. Every entry is offered and the ones that are not regions are
    // skipped inside Goose, so the app does not have to know the archive's layout.
    int64_t entries = umbra_world_import_entries();
    for (int64_t i = 0; i < entries; i++) {
        umbra_world_import_file(i);
    }
    int64_t ok = umbra_world_import_end();
    if (ok != 1) {
        world_report(app, "refused", umbra_now_us() - t0);
        app->world_state = 3;
        return 0;
    }
    world_report(app, "opened", umbra_now_us() - t0);
    // One position from the save, named: the proof that the columns in memory are the
    // save's blocks and not an array of zeros that happens to have the right shape. The
    // position is the tallest non-air block at the world's centre column, which is what a
    // person would look at first.
    {
        float cx = (umbra_world_loaded_min_x() + umbra_world_loaded_max_x()) * 0.5f;
        float cz = (umbra_world_loaded_min_z() + umbra_world_loaded_max_z()) * 0.5f;
        int64_t bx = (int64_t)cx;
        int64_t bz = (int64_t)cz;
        int64_t y = 96;
        int64_t nlen = 0;
        const uint8_t *nm = NULL;
        while (y > -64) {
            int64_t k = 0;
            nm = umbra_block_at(bx, y, bz, &k);
            nlen = k;
            if (nlen > 0 && !(nlen == 13 && memcmp(nm, "minecraft:air", 13) == 0)) break;
            y--;
        }
        char name[96];
        int k2 = 0;
        for (int64_t j = 0; j < nlen && k2 + 1 < (int)sizeof name; j++) name[k2++] = (char)nm[j];
        name[k2] = 0;
        umbra_log(app, "world: the block at %lld,%lld,%lld is %s",
                  (long long)bx, (long long)y, (long long)bz, name);
    }
    app->world_state = 2;
    snprintf(app->world_path, sizeof app->world_path, "%s", path);
    // Step 1 of the brief: the world is a radius of chunks around the player, streamed
    // from the save's region files, not the window the reader stopped at. The stream is
    // started here so that the first world a phone opens is already the bigger one; the
    // radius is the setting's current value, and the player's first step re-centres it.
    // The window is centred on the spawn, which is only known once the body has a place
    // -- and the body's place comes from the bounds of what is loaded, which is this. So
    // the stream is started here, around the *save's origin* (the import filled that
    // window), and `player_spawn` moves it to the body as soon as there is one. The
    // alternative -- guessing a centre before the first window exists -- is what centring
    // on 0,0 already does, and a save whose spawn is elsewhere would draw nothing.
    app->stream_state = 0;
    app->stream_slices = 0;
    app->stream_worst_us = 0;
    stream_start(app, 0, 0, (int)umbra_world_radius_setting());
    if (app->stream_state != 1) {
        umbra_log(app, "stream: this world has no region files resident, so the world is "
                       "the %lld column(s) the import read", (long long)umbra_world_columns());
    }
    umbra_log(app, "world: the phone is drawing a world the game generated -- the columns are "
                   "the save's, the blocks are the save's, and the jar's models drew them");
    rebuild_world(app);
    return 1;
}

// Runs the import for the screen's fifth button. Called from the frame loop when the
// button is pressed, so the log has a frame on either side of it.
// --- the sample world: download, verify, open ---------------------------
//
// The world the release publishes is what a fresh install walks in, and it goes through
// the same door as a picked file: the download lands on `umbra-sample-world.zip.part`,
// the digest in the source is checked against the bytes, and only a file that matches is
// renamed over the name the import opens. An interrupted download therefore cannot be
// mistaken for a world -- the import never looks at a `.part`.
//
// The job is one call to the platform's download hook and then one frame of bookkeeping,
// because that hook is the same one the jar uses and it already runs without holding the
// frame loop. What is added here is the verification, which is the part that matters.
static void world_sample_download_start(umbra_app *app) {
    int64_t n = 0;
    const uint8_t *pp = umbra_world_part_file((sl_u8){(uint8_t *)app->files_dir,
                                                       (int64_t)strlen(app->files_dir)}, &n);
    char part[512];
    gf_copy(app, pp, n, part, sizeof part);
    const uint8_t *uu = umbra_world_url(&n);
    char url[512];
    gf_copy(app, uu, n, url, sizeof url);
    char sha[80];
    const uint8_t *ss = umbra_world_sha256(&n);
    gf_copy(app, ss, n, sha, sizeof sha);
    umbra_log(app, "world: no save here; fetching the release's sample world");
    umbra_log(app, "world: %s -> %s (%lld bytes, sha256 %s)", url, part,
              (long long)umbra_world_pinned_bytes(), sha);
    delete_file_at(part);
    long long got = 0;
    int rc = app->download_fn(app->net_ctx, url, part, &got);
    if (rc != 0 || got <= 0) {
        umbra_log(app, "world: the sample world did not download (%s); falling back to "
                       "the file picker", app->gf_platform_error);
        delete_file_at(part);
        // The picker is the next best answer, and it is a different function: falling
        // through would land in the pick path with a state it did not expect.
        app->world_wanted = 1;
        app->world_state = 0;
        app->sample_world_tried = 1;
        return;
    }
    umbra_log(app, "world: %lld bytes downloaded; checking the digest before it is opened",
              got);
    long long want = umbra_world_pinned_bytes();
    if (got != want) {
        umbra_log(app, "world: the download is %lld bytes and the release says %lld; "
                       "refusing it", got, want);
        delete_file_at(part);
        app->world_state = 3;
        snprintf(app->world_text, sizeof app->world_text,
                 "the sample world downloaded short (%lld of %lld bytes)", got, want);
        return;
    }
    // The digest, read back from what landed rather than from what the hook returned: a
    // download that wrote fewer bytes than it reported is exactly what a digest is for.
    int64_t checked = umbra_world_present((sl_u8){(uint8_t *)app->files_dir,
                                                  (int64_t)strlen(app->files_dir)});
    if (checked != 1) {
        umbra_log(app, "world: the downloaded world's digest is not the pinned one; "
                       "refusing it");
        delete_file_at(part);
        app->world_state = 3;
        snprintf(app->world_text, sizeof app->world_text,
                 "the sample world did not match its digest");
        return;
    }
    umbra_log(app, "world: the sample world matches the digest pinned in this build");
    if (world_open_path(app, part, "downloaded sample world")) close_gamefiles_screen(app);
}

static void world_job_start(umbra_app *app) {
    app->world_state = 1;
    app->world_wanted = 0;
    char zip[512];
    snprintf(zip, sizeof zip, "%s/world.zip", app->files_dir);
    if (app->files_dir[0] && file_exists_at(zip)) {
        // The app's own directory. This is the path a phone that was handed a file takes,
        // and the one the automated run uses: the picker's answer cannot be scripted.
        //
        // It is also usually already open: start-up opens this exact archive before the
        // first mesh (see begin_scene), so by the time the owner can tap this button the
        // world behind the screen may be this save already. Re-importing it would throw
        // away and rebuild a mesh for a world that is on screen.
        if (app->world_state == 2 && strcmp(app->world_path, zip) == 0) {
            umbra_log(app, "world: %s is already open; leaving the screen for it", zip);
            close_gamefiles_screen(app);
            return;
        }
        umbra_log(app, "world: a zip of a save is in the app's own directory");
        if (world_open_path(app, zip, "app directory")) close_gamefiles_screen(app);
        return;
    }
    // No file to pick and nothing in the app's directory: the release's own sample world
    // is what a fresh install should walk in. It is downloaded, checked against the digest
    // in the source, and only then opened -- and a build with no digest pinned says so
    // rather than downloading something it cannot check.
    if (app->download_fn && umbra_world_pinned() == 1 && !app->sample_world_tried) {
        world_sample_download_start(app);
        return;
    }
    if (umbra_world_pinned() == 0) {
        int64_t nlen = 0;
        const uint8_t *why = umbra_world_refusal(&nlen);
        char reason[192];
        gf_copy(app, why, nlen, reason, sizeof reason);
        umbra_log(app, "world: no world here, and %s", reason);
    }
    if (!app->pick_world_fn) {
        umbra_log(app, "world: no world in the app's directory and no file picker in this "
                       "build: put a zip of the save at %s/world.zip", app->files_dir);
        app->world_state = 3;
        snprintf(app->world_text, sizeof app->world_text,
                 "no world yet: put a zip of a save's region folder in the app's directory");
        return;
    }
    char part[512];
    int64_t n = 0;
    const uint8_t *pp = umbra_world_part_path((sl_u8){(uint8_t *)app->files_dir,
                                                      (int64_t)strlen(app->files_dir)}, &n);
    gf_copy(app, pp, n, part, sizeof part);
    long long got = -1;
    umbra_log(app, "world: asking for a zip of a save (it lands at %s)", part);
    int rc = app->pick_world_fn(app->net_ctx, part, &got);
    if (rc != 0 || got <= 0) {
        umbra_log(app, "world: nothing was picked (%s)", app->gf_platform_error);
        app->world_state = 3;
        snprintf(app->world_text, sizeof app->world_text, "no world was picked%s%s",
                 app->gf_platform_error[0] ? ": " : "", app->gf_platform_error);
        return;
    }
    umbra_log(app, "world: the picked archive was copied: %lld bytes", got);
    // The path is the picked archive for this session, but the world it holds is the
    // one at world.zip from the next start: start-up only ever looks there.
    if (world_open_path(app, part, "picked file")) close_gamefiles_screen(app);
    else umbra_log(app, "world: the screen stays up so the file can be picked again");
}

// The frame loop's half: one import per request, never two.
static void world_pump(umbra_app *app) {
    if (app->world_wanted) world_job_start(app);
}

// Called once per frame while a job is running: progress for the bar, and the end
// of the job.
static void gf_pump(umbra_app *app) {
    if (app->gf_job == 0) return;
    long long got = 0, total = 0;
    if (app->progress_fn) app->progress_fn(app->net_ctx, &got, &total);
    if (got > 0 || total > 0) {
        app->gf_got = got;
        if (total > 0) app->gf_total = total;
        if (app->gf_state == (int)umbra_gf_state_downloading()) {
            gf_say(app, (int)umbra_gf_state_downloading(), app->gf_got, app->gf_total, "");
        }
    }
    if (!app->gf_done) return;
    app->gf_job = 0;
    app->gf_done = 0;
    if (app->gf_adopt) {
        app->gf_adopt = 0;
        gf_adopt_jar(app);
    }
    if (app->gf_state == (int)umbra_gf_state_ready()) {
        // The screen has done its job; the world it built is behind it.
        umbra_log(app, "gamefiles: leaving the game-files screen for the world");
        umbra_app_set_screen(app, UMBRA_SCREEN_LOADING);
        close_gamefiles_screen(app);
    }
}

// What the screen draws: the headline, the detail line, a progress bar while a job
// runs, and the four buttons. Every button is logged with its rectangle the first
// time it is drawn, so the automated run taps what is on screen rather than a
// coordinate someone worked out by hand.
static void draw_gamefiles(umbra_app *app) {
    hud_begin();
    float s = hud_scale(app);
    float bs = umbra_gf_scale(app->dpi_scale, app->width, app->height);
    static const char *labels[UMBRA_GF_BUTTONS] = {
        "DOWNLOAD FROM MOJANG", "IMPORT A JAR I HAVE", "OPEN A WORLD THE GAME MADE", "RETRY",
        "BACK TO THE WORLD"
    };
    if (app->gf_logged_width != app->width) {
        app->gf_logged_width = app->width;
        for (int i = 0; i < UMBRA_GF_BUTTONS; i++) {
            umbra_rect r = umbra_hud_gf_button(i, app->width, app->height, app->insets, bs);
            umbra_log(app, "hud: gamefiles button %d at %d,%d size %dx%d on %dx%d",
                      i, (int)r.x, (int)r.y, (int)r.w, (int)r.h, app->width, app->height);
        }
        umbra_log(app, "gamefiles: screen %dx%d, state %d, jar %s", app->width, app->height,
                  app->gf_state, app->jar_path[0] ? app->jar_path : "(none)");
    }
    // The backdrop covers the whole screen: there is no world to show yet.
    hud_rect(0, 0, (float)app->width, (float)app->height, 0.05f, 0.06f, 0.10f, 0.94f);
    umbra_rect t = umbra_hud_gf_text(app->width, app->height, app->insets, bs);
    float x = t.x, y = t.y;
    float line = UMBRA_HUD_ROW_HEIGHT * s;
    hud_text(x, y, s * 1.2f, 1, 1, 1, 1, "GET THE GAME'S FILES");
    y += line * 1.8f;
    hud_text(x, y, s, 0.85f, 0.9f, 1, 1, app->gf_text);
    y += line * 1.2f;
    // The detail line can be long (a checksum mismatch names two digests), so it is
    // wrapped on the width the text area actually has.
    {
        float max_chars = hud_text_width("X", s) > 0 ? t.w / hud_text_width("X", s) : 80.0f;
        int per_line = (int)max_chars;
        if (per_line < 16) per_line = 16;
        if (per_line > 90) per_line = 90;
        const char *p = app->gf_detail;
        int guard = 0;
        while (*p && guard < 4) {
            int n = (int)strlen(p);
            if (n > per_line) n = per_line;
            char tmp[96];
            memcpy(tmp, p, (size_t)n);
            tmp[n] = 0;
            hud_text(x, y, s * 0.9f, 0.75f, 0.8f, 0.9f, 1, tmp);
            y += line * 0.95f;
            p += n;
            guard++;
        }
    }
    // The bar: what the download has and what it is expected to have.
    if (app->gf_state == (int)umbra_gf_state_downloading() && app->gf_total > 0) {
        float frac = (float)app->gf_got / (float)app->gf_total;
        if (frac < 0.0f) frac = 0.0f;
        if (frac > 1.0f) frac = 1.0f;
        float bw = t.w * 0.8f, bh = 8.0f * bs;
        y += line * 0.4f;
        hud_rect(x, y, bw, bh, 0.2f, 0.2f, 0.25f, 1);
        hud_rect(x, y, bw * frac, bh, 0.3f, 0.8f, 0.4f, 1);
        y += bh + line * 0.4f;
    }
    for (int i = 0; i < UMBRA_GF_BUTTONS; i++) {
        umbra_rect r = umbra_hud_gf_button(i, app->width, app->height, app->insets, bs);
        int busy = app->gf_job != 0;
        // RETRY only makes sense after a failure; BACK only once a jar is loaded.
        int dim = (busy && i != UMBRA_GF_BUTTONS - 1) ||
                  (i == 3 && app->gf_state != (int)umbra_gf_state_failed()) ||
                  (i == 4 && !app->jar_loaded);
        hud_rect(r.x, r.y, r.w, r.h, dim ? 0.10f : 0.18f, dim ? 0.10f : 0.34f,
                 dim ? 0.12f : 0.20f, 0.92f);
        float ts = s * 0.9f;
        float tw = hud_text_width(labels[i], ts);
        hud_text(r.x + (r.w - tw) * 0.5f, r.y + (r.h - 8.0f * ts) * 0.5f, ts,
                 dim ? 0.6f : 1.0f, dim ? 0.6f : 1.0f, dim ? 0.6f : 1.0f, 1, labels[i]);
    }
    hud_flush(app);
}

static void draw_hud(umbra_app *app) {
    hud_begin();
    float s = hud_scale(app);
    float margin = 8.0f * s;
    float y = margin + (float)app->insets[1];
    float x = margin + (float)app->insets[0];
    float line = UMBRA_HUD_ROW_HEIGHT * s;
    char buf[256];

    // The backdrop is drawn first, so its height has to be known before anything
    // is drawn -- and it starts below the status bar, not behind the clock.
    float panel_h = umbra_hud_panel_height(hud_rows(app), s, app->insets[1]);
    hud_rect(0, 0, (float)app->width, panel_h, 0.0f, 0.0f, 0.0f, 0.62f);
    hud_text(x, y, s, 1, 1, 1, 1, "UMBRA - not an official Minecraft product");
    y += line * 1.6f;
    snprintf(buf, sizeof buf, "Umbra %s  build %s", UMBRA_APP_VERSION, UMBRA_GIT_COMMIT);
    hud_text(x, y, s, 0.8f, 0.9f, 1.0f, 1, buf);
    y += line;
    // Which world is on screen, in the owner's words and not the code's: a save the game
    // generated, or the scene this project built. The brief's question (c) is answered by
    // this line, so it is on the phone and not only in the log.
    if (umbra_world_is_save() != 0) {
        snprintf(buf, sizeof buf, "world: the game's own, %lld chunk(s), %lld blocks",
                 (long long)app->world_chunks, (long long)app->world_blocks);
        hud_text(x, y, s, 0.55f, 1.0f, 0.65f, 1, buf);
    } else {
        snprintf(buf, sizeof buf, "world: Umbra's demo scene (%lld columns), not a save",
                 (long long)umbra_world_columns());
        hud_text(x, y, s, 1.0f, 0.85f, 0.5f, 1, buf);
    }
    y += line;
    snprintf(buf, sizeof buf, "vulkan-free GLES3  gl %s", app->gl_version);
    hud_text(x, y, s, 0.8f, 0.9f, 1.0f, 1, buf);
    y += line;
    snprintf(buf, sizeof buf, "renderer %s", app->gl_renderer);
    hud_text(x, y, s, 0.8f, 0.9f, 1.0f, 1, buf);
    y += line;
    if (app->render_fallback) {
        // A check that failed has to be readable on the phone, not only in a log
        // nobody can reach: one line, in the colour of a warning, and the app
        // keeps drawing with the plain renderer.
        snprintf(buf, sizeof buf, "fallback: %s", app->fallback_reason);
        hud_text(x, y, s, 1.0f, 0.55f, 0.4f, 1, buf);
        y += line;
    }
    snprintf(buf, sizeof buf, "depth %d bits  highp vs %s fs %s", app->depth_bits,
             app->highp_vertex, app->highp_fragment);
    hud_text(x, y, s, 0.8f, 0.9f, 1.0f, 1, buf);
    y += line;
    if (app->mesh_state == 1) {
        snprintf(buf, sizeof buf, "LOADING WORLD %d%%  %.1f s  (frame %.1f ms)",
                 app->mesh_progress / 10, app->mesh_total_us / 1e6, app->frame_us / 1000.0);
        hud_text(x, y, s, 1.0f, 0.9f, 0.4f, 1, buf);
    } else {
        snprintf(buf, sizeof buf, "mesh %d verts  %d draws  frame %.2f ms  worst %.1f ms",
                 app->vert_count, app->draw_calls, app->frame_us / 1000.0,
                 app->max_frame_us / 1000.0);
        hud_text(x, y, s, 0.8f, 0.9f, 1.0f, 1, buf);
    }
    y += line;
    // The camera pose is on screen because "only sky visible" is otherwise a
    // guess: the numbers say where the eye is and what it is aimed at.
    if (app->player_on) {
        // In first person the useful numbers are the body's: where it is, whether it
        // is standing, and which way it faces. "Fell through the world" and "walked
        // into a wall" both read off this line.
        snprintf(buf, sizeof buf, "you %.1f %.1f %.1f  yaw %d  %s  steps %lld",
                 app->player.x, app->player.y, app->player.z,
                 (int)(app->player.yaw * 57.2958f),
                 app->player.on_ground ? "ground" : "air",
                 (long long)app->player.stepped);
    } else {
        snprintf(buf, sizeof buf, "cam %.1f %.1f %.1f -> %.1f %.1f %.1f",
                 app->eye[0], app->eye[1], app->eye[2], app->look[0], app->look[1], app->look[2]);
    }
    hud_text(x, y, s, 0.7f, 0.85f, 0.7f, 1, buf);
    y += line;
    if (app->act_text[0]) {
        snprintf(buf, sizeof buf, "hands: %s  (%d edits)", app->act_text, app->act_edits);
        hud_text(x, y, s, 0.9f, 0.9f, 0.6f, 1, buf);
        y += line;
    }
    if (app->selftest_ran) {
        hud_text(x, y, s, app->selftest_ok ? 0.4f : 1.0f, app->selftest_ok ? 1.0f : 0.3f, 0.4f, 1,
                 app->selftest_text);
    } else {
        hud_text(x, y, s, 1.0f, 1.0f, 0.4f, 1, "self-test not run yet - tap below");
    }
    y += line;
    if (app->benching) {
        double elapsed = (umbra_now_us() / 1000000.0) - app->bench_start_time;
        long long frames = (long long)umbra_bench_frames();
        int fps_now = (elapsed > 0.05) ? (int)((double)frames / elapsed + 0.5) : 0;
        snprintf(buf, sizeof buf, "benchmark %.0f/%.0f s  %lld frames  %d fps live  worst %d ms",
                 elapsed, (double)app->bench_seconds, frames, fps_now,
                 (int)((app->max_frame_us + 500) / 1000));
        hud_text(x, y, s, 1.0f, 0.9f, 0.4f, 1, buf);
    } else if (app->bench_text[0]) {
        // The benchmark block is several lines; count them so whatever is drawn
        // below it still starts in the right place.
        int extra = 0;
        for (const char *q = app->bench_text; *q; q++) {
            if (*q == '\n') extra++;
        }
        hud_text(x, y, s, 0.7f, 1.0f, 0.7f, 1, app->bench_text);
        y += (float)extra * line;
    }
    y += line;
    if (app->last_run_lines > 0) {
        // One screenshot is enough to see the previous run: the self-test verdict
        // and the benchmark numbers are read back at start-up.
        hud_text(x, y, s, 0.85f, 0.85f, 1.0f, 1, app->last_run_text);
        y += (float)(app->last_run_lines - 1) * line;
    }
    y += line;
    if (app->previous_run_crashed) {
        hud_text(x, y, s, 1.0f, 0.4f, 0.4f, 1, "previous run crashed - log tail:");
        y += line;
        // Two lines of tail, so the screen shows something actionable.
        const char *p = app->tail_text;
        int lines = 0;
        while (*p && lines < 2) {
            const char *nl = strchr(p, '\n');
            size_t n = nl ? (size_t)(nl - p) : strlen(p);
            if (n > 90) n = 90;
            char tmp[96];
            memcpy(tmp, p, n);
            tmp[n] = 0;
            hud_text(x, y, s * 0.8f, 1.0f, 0.7f, 0.7f, 1, tmp);
            y += line * 0.9f;
            if (!nl) break;
            p = nl + 1;
            lines++;
        }
    }

    // Three touch targets, big enough for a thumb on a phone.
    struct { const char *label; int id; } buttons[3] = {
        {"RUN GPU SELF-TEST", 0}, {"RUN 60 s BENCHMARK", 1}, {"SHARE LOG", 2}};
    for (int i = 0; i < 3; i++) {
        float bx, by, bw, bh;
        hud_button_rect(app, i, &bx, &by, &bw, &bh);
        bool active = (i == 0 && app->selftest_ran) || (i == 1 && app->benching);
        float label = s * 1.15f;
        hud_rect(bx, by, bw, bh, active ? 0.25f : 0.15f, active ? 0.55f : 0.25f, active ? 0.3f : 0.15f, 0.9f);
        hud_text(bx + margin * 0.5f, by + (bh - 8.0f * label) * 0.5f, label, 1, 1, 1, 1, buttons[i].label);
    }
    // The overlay checks itself: a row-for-row walk that ends below the backdrop
    // means text on bare sky, which is what a phone screenshot showed once. The
    // numbers go to the log so CI can assert on them instead of on a picture.
    float content_bottom = y + line;
    if (app->hud_rows_logged != hud_rows(app) || app->hud_fits != (panel_h >= content_bottom)) {
        app->hud_rows_logged = hud_rows(app);
        app->hud_fits = panel_h >= content_bottom;
        if (app->hud_fits) {
            umbra_log(app, "hud: %d rows, content ends at %.0f px inside a %.0f px panel, fits",
                      hud_rows(app), content_bottom, panel_h);
        } else {
            umbra_log(app, "hud: OVERFLOW - %d rows, content ends at %.0f px but the panel is %.0f px",
                      hud_rows(app), content_bottom, panel_h);
        }
    }
    draw_hands(app);
    hud_flush(app);
}

void umbra_app_frame(umbra_app *app) {
    int64_t t0 = umbra_now_us();
    if (app->last_frame_time > 0) {
        app->frame_us = t0 - (int64_t)app->last_frame_time;
    }
    app->last_frame_time = (double)t0;

    if (app->width < 16 || app->height < 16) {
        // The EGL surface can come up at 1x1 when the window has no buffers yet
        // (run 43687356640 did exactly that and drew nothing but the clear
        // colour). Drawing into a 1-pixel viewport is not a frame, so don't.
        app->last_frame_time = (double)umbra_now_us();
        return;
    }
    if (app->hud_logged_width != app->width) {
        // Logged from the frame loop, when a real surface size is known: the
        // automated emulator run taps the self-test by reading these numbers
        // back, so a layout change cannot silently make it tap empty space.
        for (int i = 0; i < 3; i++) {
            float bx, by, bw, bh;
            hud_button_rect(app, i, &bx, &by, &bw, &bh);
            umbra_log(app, "hud: button %d at %d,%d size %dx%d on %dx%d (insets %d,%d,%d,%d)",
                      i, (int)bx, (int)by, (int)bw, (int)bh, app->width, app->height,
                      app->insets[0], app->insets[1], app->insets[2], app->insets[3]);
        }
        app->hud_logged_width = app->width;
    }
    if (app->frame_us > app->max_frame_us) app->max_frame_us = app->frame_us;
    if (app->frame_us > 250000) {
        app->long_frames++;
        // A frame this long is a stall a person can see; the log keeps the worst
        // ones so a phone report says where the time went.
        umbra_log(app, "long frame %.1f ms (mesh %d%%, %lld calls)", app->frame_us / 1000.0,
                  app->mesh_progress / 10, (long long)app->mesh_calls);
    }
    pump_mesh(app);
    stream_pump(app);
    player_act(app);
    gf_pump(app);
    world_pump(app);
    if (app->gf_pending_open && app->width >= 320 && app->mesh_state == 2) {
        app->gf_pending_open = 0;
        open_gamefiles_screen(app);
    }

    // The self-test goes first, and one bounded step of it per frame: it draws
    // into its own target, and in the fallback path (no offscreen target) it reads
    // the window before this frame's scene and overlay are drawn into it, so the
    // overlay can never end up inside the comparison.
    if (app->selftest_requested) {
        app->selftest_requested = false;
        selftest_begin(app);
    }
    selftest_step(app);

    // Whatever state the self-test stopped in, the scene gets a clean start: the
    // pattern pass draws with the depth test off, and a watchdog abort can leave
    // it that way, which would draw the world without depth for a frame.
    glEnable(GL_DEPTH_TEST);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glViewport(0, 0, app->width, app->height);
    if (app->render_fallback) {
        // The plain renderer: a flat background and the overlay that says why.
        // No world, no shader that failed to link, and no crash.
        glClearColor(0.10f, 0.11f, 0.14f, 1.0f);
    } else {
        glClearColor(0.55f, 0.70f, 0.92f, 1.0f);
    }
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    if (app->screen == UMBRA_SCREEN_GAMEFILES) {
        draw_gamefiles(app);
        app->frames_drawn++;
        gpu_timer_collect(app);
        return;
    }
    if (app->mesh_uploaded && !app->render_fallback) {
        player_update(app);
        gpu_timer_begin(app);
        int64_t first_t0 = umbra_now_us();
        draw_scene(app);
        app->last_draw_us = umbra_now_us() - first_t0;
        gpu_timer_end(app);
        // The first frame that draws a freshly uploaded 25 MB buffer is the one that
        // can stall, because the driver may not have the data on the GPU yet. It is
        // timed, once, so a "long frame" in the log can be attributed instead of
        // guessed at: this run's 230 ms frame was neither the shaders (12 ms) nor
        // the upload (35 ms), so it was here or in the present that follows.
        if (!app->first_draw_timed) {
            int64_t t_after = umbra_now_us();
            glFinish();
            int64_t blocked = umbra_now_us() - t_after;
            app->first_draw_timed = true;
            umbra_log(app, "frame: the first world frame drew in %.1f ms and the driver "
                           "held it %.1f ms (glFinish), %d vertices over %d ranges",
                      app->last_draw_us / 1000.0, blocked / 1000.0,
                      app->vert_count, app->draw_calls);
        }
    }
    draw_hud(app);
    app->frames_drawn++;
    gpu_timer_collect(app);

    // The edit's end, measured where it is true: this frame has drawn the new geometry
    // and is about to be swapped in. `edit_wait_us` is the part a person experiences as
    // lag before anything happens, `edit_upload_us` is the GPU call, and the rest is the
    // frame that drew it.
    if (app->edit_pending_present && app->edit_mesh_done_us > 0) {
        int64_t now = umbra_now_us();
        int64_t total = now - app->edit_applied_us;
        int64_t mesh = app->edit_mesh_done_us - app->edit_applied_us;
        umbra_log(app, "edit: on screen in %.1f ms (re-mesh %.1f ms from %.1f ms after the "
                       "edit, of which the sub-upload %.2f ms; the frame that drew it %.1f ms)",
                  total / 1000.0, mesh / 1000.0, app->edit_wait_us / 1000.0,
                  app->edit_upload_us / 1000.0, (now - app->edit_mesh_done_us) / 1000.0);
        app->edit_pending_present = 0;
        app->edit_applied_us = 0;
    }

    if (app->benching) {
        umbra_bench_add(app->frame_us);
        double elapsed = (umbra_now_us() / 1000000.0) - app->bench_start_time;
        if (elapsed >= app->bench_seconds) {
            app->benching = false;
            gpu_timer_end(app);
            // Drain what is ready, then give the last queries a few frames' worth of
            // time by force-syncing once: the benchmark is over, a stall here costs
            // nothing.
            glFinish();
            for (int i = 0; i < UMBRA_GPU_QUERIES; i++) gpu_timer_collect(app);
            if (app->swap_interval_fn) {
                app->swap_interval_fn(app->swap_interval_ctx, 1);
                umbra_log(app, "benchmark: swap interval restored to 1");
            }
            char dev[128];
            snprintf(dev, sizeof dev, "%s", app->gl_renderer);
            char gles[40];
            short_gles(app->gl_version, gles, sizeof gles);
            int64_t len = 0;
            // Slice arguments are (pointer, length) structs across the boundary.
            sl_u8 label = {(uint8_t *)"bench", 5};
            sl_u8 devs = {(uint8_t *)dev, (int64_t)strlen(dev)};
            sl_u8 andr = {(uint8_t *)gles, (int64_t)strlen(gles)};
            // The total, not the average: Goose divides by the frame count it is
            // given, and dividing twice turned 4.1 ms into 0.04 ms in the host test.
            const uint8_t *text = umbra_bench_summary(label, devs, andr, app->gpu_time_us,
                                                      app->gpu_timer_supported ? 1 : 0,
                                                      app->bench_vsync, app->gpu_frames, &len);
            snprintf(app->bench_text, sizeof app->bench_text, "%.*s", (int)len, (const char *)text);
            umbra_log(app, "%s", app->bench_text);
            remember_bench(app);
        }
    }
}

void umbra_app_touch(umbra_app *app, int32_t x, int32_t y, bool down) {
    umbra_app_touch_id(app, 0, x, y, down ? 0 : 2);
}

// Three things a finger can mean, in the order they are tested: one of the three
// buttons, a drag that turns the head, or a hold that walks forward. A quick tap
// on the scene jumps, and a tap while the body is standing in the overview starts
// walking, which is the only way into first person from the home screen.
void umbra_app_touch_id(umbra_app *app, int32_t id, int32_t x, int32_t y, int32_t phase) {
    if (phase == 2 || phase == 3) {
        if (app->touch_look_id == id) {
            app->touch_look_id = -1;
            app->move_fwd = 0;
            // A short press that never moved the head is a tap, and a tap in first
            // person is a jump. A long one was already walking.
            int64_t held = umbra_now_us() - app->touch_down_us;
            if (phase == 2 && !app->touch_moved && held < 180000 && app->player_on) {
                // A tap that landed on the hotbar or on a hand button was already
                // answered when the finger went down; only a tap on the world jumps.
                if (app->tap_used) {
                    app->tap_used = 0;
                } else {
                    app->jump_wanted = 1;
                    umbra_log(app, "player: tap, jumping");
                }
            }
        }
        if (app->touch_walk_id == id) {
            app->touch_walk_id = -1;
            app->move_fwd = 0;
        }
        if (app->sneak_touch_id == id) {
            // The crouch ends when the finger that started it lifts, whatever else
            // happens in between.
            app->sneak_touch_id = -1;
            app->sneak_held = 0;
            app->tap_used = 0;
            umbra_log(app, "player: sneak released");
        }
        return;
    }
    if (phase == 0) {
        app->tap_used = 0;
        app->touch_down_us = umbra_now_us();
        app->touch_last_x = (float)x;
        app->touch_last_y = (float)y;
        app->touch_moved = 0;
    }
    if (app->screen == UMBRA_SCREEN_GAMEFILES) {
        // The screen's own buttons, above the "is the world ready" test: there is
        // no world yet, which is the whole reason the screen is up.
        if (phase == 0) {
            float bs = umbra_gf_scale(app->dpi_scale, app->width, app->height);
            int hit = umbra_hud_gf_hit(x, y, app->width, app->height, app->insets, bs);
            if (hit >= 0) {
                app->tap_used = 1;
                umbra_log(app, "gamefiles: button %d tapped%s", hit,
                          app->gf_job ? " (a job is already running)" : "");
                if (hit == 0) {
                    gf_start(app, 1);
                } else if (hit == 1) {
                    gf_start(app, 2);
                } else if (hit == 2) {
                    // Deferred to the frame loop: an import reads an archive and begins a
                    // mesh, and neither belongs in the middle of event dispatch.
                    app->world_wanted = 1;
                    umbra_log(app, "world: open requested");
                } else if (hit == 3) {
                    if (app->gf_state == (int)umbra_gf_state_failed()) gf_start(app, 1);
                } else if (hit == 4) {
                    if (app->jar_loaded) {
                        close_gamefiles_screen(app);
                    } else {
                        umbra_log(app, "gamefiles: back refused, no jar is loaded yet");
                    }
                }
            }
        }
        return;
    }
    if (app->mesh_state != 2) {
        // The buttons need the finished world: the self-test draws into its own
        // target but the benchmark measures the frame loop, and both would
        // measure the loading screen.
        if (phase == 0) {
            umbra_log(app, "touch ignored while meshing (%d%%)", app->mesh_progress / 10);
        }
        return;
    }
    if (app->screen == UMBRA_SCREEN_HOME && phase == 0) {
        for (int i = 0; i < 3; i++) {
            float bx, by, bw, bh;
            hud_button_rect(app, i, &bx, &by, &bw, &bh);
            if (x >= bx && x <= bx + bw && y >= by && y <= by + bh) {
                if (i == 0) {
                    // The self-test renders and reads back; it runs at a defined
                    // point in the frame rather than in the middle of event
                    // dispatch, so the GL state is ours and not the driver's.
                    app->selftest_requested = true;
                    umbra_log(app, "self-test: requested");
                } else if (i == 1) {
                    app->benching = true;
                    app->bench_start_time = umbra_now_us() / 1000000.0;
                    app->bench_text[0] = 0;
                    umbra_bench_reset();
                    gpu_timer_load(app);
                    gpu_timer_reset(app);
                    // "59 FPS" on a 60 Hz phone is the display, not the GPU. Ask for an
                    // uncapped swap interval, log whether the platform agreed, and never
                    // pretend the frame rate means something it does not.
                    app->bench_vsync = 0;
                    if (app->swap_interval_fn) {
                        int took = app->swap_interval_fn(app->swap_interval_ctx, 0);
                        app->bench_vsync = took ? 1 : 2;
                        umbra_log(app, "benchmark: uncapped swap interval %s",
                                  took ? "requested and accepted" : "refused by the platform");
                    } else {
                        umbra_log(app, "benchmark: no platform hook for the swap interval");
                    }
                    umbra_log(app, "benchmark: start, %d seconds, gpu timer %s", app->bench_seconds,
                              g_gpu_timer.ready ? "on" : "off");
                } else {
                    umbra_log(app, "share log: requested");
                    umbra_share_log(app);
                }
                return;
            }
        }
    }
    // Not a button: this finger is on the world.
    if (app->player_on && app->mesh_state == 2) {
        // The hotbar and the two action buttons take the tap when it lands on them.
        float hs = hand_scale(app);
        if (phase == 0) {
            int slot = umbra_hud_hotbar_hit(x, y, app->width, app->height, app->insets, hs);
            if (slot >= 0) {
                app->hotbar_sel = (int)umbra_hotbar_select((int64_t)slot);
                app->tap_used = 1;
                const uint8_t *nm = NULL;
                int64_t nm_len = 0;
                nm = umbra_hotbar_name((int64_t)app->hotbar_sel, &nm_len);
                char name[32];
                int k = 0;
                for (int64_t j = 0; j < nm_len && k + 1 < (int)sizeof name; j++) {
                    name[k++] = (char)nm[j];
                }
                name[k] = 0;
                umbra_log(app, "player: hotbar slot %d selected (%s)", app->hotbar_sel, name);
                return;
            }
            if (umbra_hud_sneak_hit(x, y, app->width, app->height, app->insets, hs)) {
                // Held, not toggled: the finger owns the crouch, so lifting it stands
                // the body up. Tracked by id so a second finger elsewhere cannot end it.
                app->sneak_held = 1;
                app->sneak_touch_id = id;
                app->tap_used = 1;
                umbra_log(app, "player: sneak held");
                return;
            }
            int action = umbra_hud_action_hit(x, y, app->width, app->height, app->insets, hs);
            if (action >= 0) {
                // Consumed on the next frame, not here: the edit re-meshes, and an edit
                // in the middle of event dispatch is an edit in the middle of the GL
                // driver's state.
                app->act_wanted = action;
                app->tap_used = 1;
                umbra_log(app, "player: %s tapped", action == 0 ? "break" : "place");
                return;
            }
        } else if (phase == 1) {
            // A finger that started on a hand control does not also turn the head.
            if (app->tap_used) return;
        }
    }
    if (!app->player_on) {
        // The overview is where the buttons live; touching the world starts walking.
        // The first touch is not also a drag, so the view does not jump on entry.
        player_spawn(app);
        umbra_log(app, "player: first-person view on; drag to look, hold to walk, tap to jump");
        app->touch_look_id = id;
        return;
    }
    if (app->touch_look_id < 0) {
        app->touch_look_id = id;
        return;
    }
    if (app->touch_look_id == id) {
        // Drag to look: 0.005 radians per pixel is about a 2300-pixel-wide turn on a
        // phone screen, which is a comfortable sweep of the thumb.
        float dx = (float)x - app->touch_last_x;
        float dy = (float)y - app->touch_last_y;
        if (phase == 1) {
            if (dx * dx + dy * dy > 4.0f) app->touch_moved = 1;
            umbra_player_look(&app->player, -dx * 0.005f, -dy * 0.005f);
        }
        app->touch_last_x = (float)x;
        app->touch_last_y = (float)y;
        return;
    }
    // A second finger holds "walk forward".
    if (app->touch_walk_id < 0) {
        app->touch_walk_id = id;
        app->move_fwd = 1;
        umbra_log(app, "player: walking");
    }
}
