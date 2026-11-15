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
#include <stdarg.h>
#include <time.h>
#include <math.h>

#ifdef __ANDROID__
#include <GLES3/gl3.h>
#include <EGL/egl.h>
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
    "out float v_dist;\n"
    "void main() {\n"
    "    vec3 p = a_pos - u_center;\n"
    "    v_col = a_col;  // face shade and ambient occlusion are baked in\n"
    "    v_dist = length(p);\n"
    "    gl_Position = u_viewproj * vec4(p, 1.0);\n"
    "}\n";

static const char *FS_MESH =
    "#version 300 es\n"
    "precision highp float;\n"
    "in vec3 v_col;\n"
    "in float v_dist;\n"
    "uniform vec2 u_fog;\n"
    "out vec4 o_col;\n"
    "void main() {\n"
    "    float fog = clamp((v_dist - u_fog.x) / (u_fog.y - u_fog.x), 0.0, 1.0);\n"
    "    vec3 sky = vec3(0.55, 0.70, 0.92);\n"
    "    o_col = vec4(mix(v_col, sky, fog), 1.0);\n"
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
    umbra_log(app, "mesh uploaded: %.1f MB vertices, %.1f MB indices", vlen / 1048576.0,
              ilen / 1048576.0);
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
static void finish_scene(umbra_app *app) {
    app->vert_count = (int32_t)umbra_vert_count();
    app->index_count = (int32_t)umbra_index_count();
    for (int b = 0; b < 3; b++) {
        app->batch_start[b] = umbra_batch_start(b);
        app->batch_count[b] = umbra_batch_count(b);
    }
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
    upload_mesh(app);
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
    umbra_log(app, "mesh: %d vertices, %d indices; batches %lld/%lld/%lld", app->vert_count,
              app->index_count, (long long)app->batch_count[0], (long long)app->batch_count[1],
              (long long)app->batch_count[2]);
    umbra_log(app, "startup: meshed in %.1f ms over %lld calls (worst call %.1f ms, worst unit %.1f ms), "
                   "longest frame %.1f ms, frames over 250 ms: %lld",
              app->mesh_total_us / 1000.0, (long long)app->mesh_calls,
              app->mesh_worst_call_us / 1000.0, umbra_demo_mesh_worst_unit_us() / 1000.0,
              app->max_frame_us / 1000.0, (long long)app->long_frames);
}

// Build the world (fast) and start meshing it (slow, sliced by the frame loop).
static void begin_scene(umbra_app *app) {
    int64_t t0 = umbra_now_us();
    umbra_demo_build(20261114);
    int64_t t1 = umbra_now_us();
    umbra_demo_mesh_begin();
    app->mesh_state = 1;
    app->mesh_progress = 0;
    app->mesh_calls = 0;
    app->mesh_worst_call_us = 0;
    app->mesh_total_us = 0;
    app->screen = UMBRA_SCREEN_LOADING;
    umbra_log(app, "demo world built in %.1f ms; meshing starts in slices of at most %d ms",
              (t1 - t0) / 1000.0, UMBRA_MESH_BUDGET_MS);
}

// Called once per frame while the mesh is incomplete. The budget is a soft cap:
// a single section cannot be interrupted, so a call can overrun it by one
// section's work, which the worst-call number above reports.
static void pump_mesh(umbra_app *app) {
    if (app->mesh_state != 1) return;
    int64_t t = umbra_now_us();
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
        finish_scene(app);
        app->screen = UMBRA_SCREEN_HOME;
    }
}

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
    app->screen = UMBRA_SCREEN_HOME;
    app->bench_seconds = 60;
    // 55 degrees is a phone-friendly vertical field of view; the distance that
    // fits the world into it is computed from the mesh, per screen aspect.
    app->fov_y = 55.0f;
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

    char err[1024];
    app->prog_mesh = link_program(VS_MESH, FS_MESH, err, sizeof err);
    if (!app->prog_mesh) { umbra_log(app, "mesh program: %s", err); return 0; }
    app->prog_hud = link_program(VS_HUD, FS_HUD, err, sizeof err);
    if (!app->prog_hud) { umbra_log(app, "hud program: %s", err); return 0; }
    app->prog_pattern = link_program(VS_FULL, FS_PATTERN, err, sizeof err);
    if (!app->prog_pattern) { umbra_log(app, "pattern program: %s", err); return 0; }
    app->prog_cube = link_program(VS_CUBE, FS_CUBE, err, sizeof err);
    if (!app->prog_cube) { umbra_log(app, "cube program: %s", err); return 0; }

    query_gl_info(app);
    umbra_log(app, "GL_RENDERER %s", app->gl_renderer);
    umbra_log(app, "GL_VERSION %s", app->gl_version);
    umbra_log(app, "GL_VENDOR %s", app->gl_vendor);
    umbra_log(app, "depth bits %d, vertex highp %s, fragment highp %s", app->depth_bits,
              app->highp_vertex, app->highp_fragment);

    create_font_texture(app);
    create_fullscreen_quad(app);
    create_cube_geometry(app);
    create_hud_buffers(app);
    create_mesh_buffers(app);
    begin_scene(app);

    glEnable(GL_DEPTH_TEST);
    glDepthFunc(GL_LESS);
    glDisable(GL_CULL_FACE);  // the mesher's winding is verified, but the cube
                              // geometry and the HUD share this state; culling
                              // comes back with the real renderer.
    app->last_frame_time = 0.0;
    // The button rectangles are logged from the frame loop instead of here: at
    // this point the surface may still be 1x1, and a layout computed from that
    // is nonsense (run 43687356640 logged "button 0 at 25,-269 size -49x63").
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
    device_note(app, "gpu timer query", app->gpu_timer_note, timer_ext);

    // Every program that linked is reported by name: a shader that fails on one
    // driver and not another is the single most likely device-specific failure.
    snprintf(buf, sizeof buf, "mesh %s, hud %s, pattern %s, cube %s",
             app->prog_mesh ? "ok" : "FAILED", app->prog_hud ? "ok" : "FAILED",
             app->prog_pattern ? "ok" : "FAILED", app->prog_cube ? "ok" : "FAILED");
    int all = app->prog_mesh && app->prog_hud && app->prog_pattern && app->prog_cube;
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
                 "SELFTEST PASS (0 bad of %lld px, %.0f ms, %s)",
                 (long long)checked, app->selftest_us / 1000.0,
                 app->st_offscreen ? "offscreen" : "window");
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
        int64_t len = 0;
        const uint8_t *t = umbra_selftest_first_bad_text(&len);
        umbra_log(app, "self-test: first mismatch %.*s", (int)len, (const char *)t);
    }
    if (app->st_skip_px > 0) {
        umbra_log(app, "self-test: %lld px not compared (under the overlay)",
                  (long long)app->st_skip_px);
    }
    umbra_log(app, "self-test: end after %.0f ms, %d steps",
              app->selftest_us / 1000.0, app->st_row);
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
    app->st_tile_rows = umbra_selftest_tile_rows(app->st_w, app->st_h);
    app->st_offscreen = 0;
    app->st_fbo_status = 0;
    app->st_reason[0] = 0;
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

static int64_t selftest_take_mismatches(umbra_app *app) {
    (void)app;
    int64_t n = umbra_selftest_mismatches();
    umbra_selftest_reset();
    return n;
}

// One bounded step, called once per frame while the test is running.
static void selftest_step(umbra_app *app) {
    if (app->st_state <= ST_IDLE || app->st_state >= ST_DONE) return;
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
                app->st_pattern_bad = selftest_take_mismatches(app);
                app->st_pattern_checked = umbra_selftest_checked();
                umbra_selftest_reset();
                umbra_log(app, "self-test: pattern compared, %lld of %lld px differ, max channel "
                               "diff %lld",
                          (long long)app->st_pattern_bad, (long long)app->st_pattern_checked,
                          (long long)umbra_selftest_max_diff());
                umbra_selftest_reset();
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
        case ST_COMPARE_CUBE:
            if (selftest_compare_step(app, 0)) {
                app->st_cube_bad = selftest_take_mismatches(app);
                app->st_cube_checked = umbra_selftest_checked();
                umbra_log(app, "self-test: cube compared, %lld of %lld px differ",
                          (long long)app->st_cube_bad, (long long)app->st_cube_checked);
                umbra_selftest_reset();
                glEnable(GL_DEPTH_TEST);
                selftest_end(app, app->st_pattern_bad == 0 && app->st_cube_bad == 0, NULL);
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
    camera_eye(app, eye);
    app->eye[0] = eye[0];
    app->eye[1] = eye[1];
    app->eye[2] = eye[2];
    float up[3] = {0.0f, 1.0f, 0.0f};
    mat4_look_at(view, eye, app->look, up);
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
    glUniform2f(glGetUniformLocation(app->prog_mesh, "u_fog"), app->fog_near, app->fog_far);
    glUniform3f(glGetUniformLocation(app->prog_mesh, "u_center"), app->center[0], app->center[1], app->center[2]);
    glBindVertexArray(app->vao_mesh);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, app->ibo_mesh);
    // PASS_OPAQUE and PASS_CUTOUT draw with depth writing on; PASS_TRANSLUCENT
    // blends with depth writes off, which is the vanilla order.
    app->draw_calls = 0;
    for (int pass = PASS_OPAQUE; pass <= PASS_TRANSLUCENT; pass++) {
        int b = pass - PASS_OPAQUE;
        if (app->batch_count[b] <= 0) continue;
        app->draw_calls++;
        if (pass == PASS_TRANSLUCENT) {
            glEnable(GL_BLEND);
            glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
            glDepthMask(GL_FALSE);
        }
        glDrawElements(GL_TRIANGLES, (GLsizei)app->batch_count[b], GL_UNSIGNED_INT,
                       (void *)(uintptr_t)(app->batch_start[b] * 4));
        if (pass == PASS_TRANSLUCENT) {
            glDepthMask(GL_TRUE);
            glDisable(GL_BLEND);
        }
    }
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
    snprintf(buf, sizeof buf, "cam %.1f %.1f %.1f -> %.1f %.1f %.1f",
             app->eye[0], app->eye[1], app->eye[2], app->look[0], app->look[1], app->look[2]);
    hud_text(x, y, s, 0.7f, 0.85f, 0.7f, 1, buf);
    y += line;
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
    if (app->mesh_uploaded && !app->render_fallback) {
        gpu_timer_begin(app);
        draw_scene(app);
        gpu_timer_end(app);
    }
    draw_hud(app);
    app->frames_drawn++;
    gpu_timer_collect(app);

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
    if (!down) return;
    if (app->mesh_state != 2) {
        // The buttons need the finished world: the self-test draws into its own
        // target but the benchmark measures the frame loop, and both would
        // measure the loading screen.
        umbra_log(app, "touch ignored while meshing (%d%%)", app->mesh_progress / 10);
        return;
    }
    if (app->screen != UMBRA_SCREEN_HOME) return;
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
        }
    }
}
