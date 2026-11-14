// Umbra's application shell: EGL/GLES3 setup, the render pass graph, the HUD,
// the GPU self-test, the 60-second benchmark, the crash marker and the log.
//
// Game logic is not here: it is in goose/ and reached through umbra_core.h.
// This file draws and measures.
#include "umbra_app.h"
#include "umbra_vertex.h"
#include "umbra_font.h"
#include "umbra_core.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <time.h>

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
    "    v_col = a_col * a_ao;\n"
    "    v_dist = length(p);\n"
    "    gl_Position = u_viewproj * vec4(p, 1.0);\n"
    "}\n";

static const char *FS_MESH =
    "#version 300 es\n"
    "precision highp float;\n"
    "in vec3 v_col;\n"
    "in float v_dist;\n"
    "out vec4 o_col;\n"
    "void main() {\n"
    "    float fog = clamp((v_dist - 40.0) / 60.0, 0.0, 1.0);\n"
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

static void hud_rect(float x, float y, float w, float h, float r, float g, float b, float a) {
    hud_quad(x, y, w, h, 0.0f, 0.0f, 0.0f, 0.0f, r, g, b, a);
}

static void hud_text(float x, float y, float scale, float cr, float cg, float cb, float ca,
                     const char *text) {
    // The font texture is 16x8 cells of 8x8 texels: 128x64 texels total.
    const float cell = 1.0f / 16.0f;
    const float row = 1.0f / 8.0f;
    float cx = x;
    for (const char *p = text; *p; p++) {
        unsigned char c = (unsigned char)*p;
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

static void build_scene(umbra_app *app) {
    int64_t t0 = umbra_now_us();
    umbra_demo_build(20261114);
    int64_t t1 = umbra_now_us();
    umbra_demo_mesh();
    int64_t t2 = umbra_now_us();
    app->vert_count = (int32_t)umbra_vert_count();
    app->index_count = (int32_t)umbra_index_count();
    for (int b = 0; b < 3; b++) {
        app->batch_start[b] = umbra_batch_start(b);
        app->batch_count[b] = umbra_batch_count(b);
    }
    app->center[0] = (umbra_mesh_min_x() + umbra_mesh_max_x()) * 0.5f;
    app->center[1] = (umbra_mesh_min_y() + umbra_mesh_max_y()) * 0.5f;
    app->center[2] = (umbra_mesh_min_z() + umbra_mesh_max_z()) * 0.5f;
    umbra_log(app, "demo world built in %.1f ms, meshed in %.1f ms", (t1 - t0) / 1000.0, (t2 - t1) / 1000.0);
    umbra_log(app, "mesh: %d vertices, %d indices; batches %lld/%lld/%lld", app->vert_count,
              app->index_count, (long long)app->batch_count[0], (long long)app->batch_count[1],
              (long long)app->batch_count[2]);
}

int umbra_app_init(umbra_app *app) {
    memset(app, 0, sizeof *app);
    app->screen = UMBRA_SCREEN_HOME;
    app->dpi_scale = 1.0f;
    app->bench_seconds = 60;
    snprintf(app->build_text, sizeof app->build_text, "Umbra %s (%s)", "(see HUD)", UMBRA_GIT_COMMIT);

    log_open(app);
    umbra_log(app, "---- Umbra starting, build %s ----", UMBRA_GIT_COMMIT);
    umbra_log(app, "core: %.*s", 40, umbra_core_selftest_name() ? "loaded" : "missing");

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
    build_scene(app);
    create_mesh_buffers(app);

    glEnable(GL_DEPTH_TEST);
    glDepthFunc(GL_LESS);
    glDisable(GL_CULL_FACE);  // the mesher's winding is verified, but the cube
                              // geometry and the HUD share this state; culling
                              // comes back with the real renderer.
    app->last_frame_time = 0.0;
    return 1;
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

static void run_selftest(umbra_app *app) {
    umbra_log(app, "self-test: begin (%dx%d)", app->width, app->height);
    umbra_selftest_reset();
    glViewport(0, 0, app->width, app->height);
    glDisable(GL_DEPTH_TEST);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

    // 1. Fullscreen pattern: the fragment colour is a pure function of
    //    gl_FragCoord, so any viewport or attribute-layout error shows.
    glUseProgram(app->prog_pattern);
    glUniform1i(glGetUniformLocation(app->prog_pattern, "u_w"), app->width);
    glUniform1i(glGetUniformLocation(app->prog_pattern, "u_h"), app->height);
    glBindVertexArray(app->vao_full);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glFinish();

    int w = app->width, h = app->height;
    unsigned char *px = (unsigned char *)malloc((size_t)w * h * 3);
    if (!px) {
        umbra_log(app, "self-test: out of memory");
        return;
    }
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, w, h, GL_RGB, GL_UNSIGNED_BYTE, px);
    // The verdict is Goose's: hand it every pixel and let it compare.
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            const unsigned char *p = px + ((size_t)y * w + x) * 3;
            umbra_selftest_pattern_pixel(x, y, w, h, p[0], p[1], p[2]);
        }
    }
    glEnable(GL_DEPTH_TEST);
    int64_t pattern_mismatches = umbra_selftest_mismatches();
    int64_t pattern_checked = umbra_selftest_checked();
    int64_t pattern_diff = umbra_selftest_max_diff();
    umbra_log(app, "self-test: pattern %lld pixels checked, %lld mismatched, max channel diff %lld",
              (long long)pattern_checked, (long long)pattern_mismatches, (long long)pattern_diff);

    // 2. A cube through a perspective matrix with a depth test: a transposed
    //    upload, a wrong depth range or a wrong aspect all fail this.
    umbra_selftest_reset();
    glClearColor(0.02f, 0.03f, 0.06f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    float proj[16], view[16], vp[16];
    mat4_perspective(proj, 60.0f * 3.14159265f / 180.0f, (float)w / (float)h, 0.1f, 100.0f);
    float eye[3] = {0.0f, 0.0f, 3.0f};
    float target[3] = {0.0f, 0.0f, 0.0f};
    float up[3] = {0.0f, 1.0f, 0.0f};
    mat4_look_at(view, eye, target, up);
    mat4_mul(vp, proj, view);
    glUseProgram(app->prog_cube);
    glUniformMatrix4fv(glGetUniformLocation(app->prog_cube, "u_viewproj"), 1, GL_FALSE, vp);
    glBindVertexArray(app->vao_cube);
    glDrawElements(GL_TRIANGLES, 36, GL_UNSIGNED_SHORT, 0);
    glFinish();
    glReadPixels(0, 0, w, h, GL_RGB, GL_UNSIGNED_BYTE, px);
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            const unsigned char *p = px + ((size_t)y * w + x) * 3;
            umbra_selftest_cube_pixel(x, y, w, h, p[0], p[1], p[2]);
        }
    }
    int64_t cube_mismatches = umbra_selftest_mismatches();
    int64_t cube_checked = umbra_selftest_checked();
    free(px);
    umbra_log(app, "self-test: cube %lld pixels checked, %lld mismatched",
              (long long)cube_checked, (long long)cube_mismatches);

    int64_t total_bad = pattern_mismatches + cube_mismatches;
    app->selftest_ran = true;
    app->selftest_ok = total_bad == 0;
    app->selftest_mismatches = total_bad;
    app->selftest_checked = pattern_checked + cube_checked;
    app->selftest_max_diff = pattern_diff;
    app->selftest_first_bad = umbra_selftest_first_bad();
    snprintf(app->selftest_text, sizeof app->selftest_text, "SELFTEST %s (%lld bad of %lld px)",
             app->selftest_ok ? "PASS" : "FAIL", (long long)total_bad, (long long)app->selftest_checked);
    umbra_log(app, "%s", app->selftest_text);
    if (!app->selftest_ok) {
        umbra_log(app, "self-test: first bad pixel index %lld", (long long)app->selftest_first_bad);
    }
}

// --- frame --------------------------------------------------------------

static void draw_scene(umbra_app *app) {
    float proj[16], view[16], vp[16];
    mat4_perspective(proj, 62.0f * 3.14159265f / 180.0f, (float)app->width / (float)app->height, 0.05f, 400.0f);
    float t = (float)(app->frames_drawn % 3600) * 0.002f;
    float eye[3] = {app->center[0] + 34.0f * cosf(t), app->center[1] + 26.0f, app->center[2] + 34.0f * sinf(t)};
    float target[3] = {app->center[0], app->center[1] - 6.0f, app->center[2]};
    float up[3] = {0.0f, 1.0f, 0.0f};
    mat4_look_at(view, eye, target, up);
    mat4_mul(vp, proj, view);
    glUseProgram(app->prog_mesh);
    glUniformMatrix4fv(glGetUniformLocation(app->prog_mesh, "u_viewproj"), 1, GL_FALSE, vp);
    glUniform3f(glGetUniformLocation(app->prog_mesh, "u_center"), app->center[0], app->center[1], app->center[2]);
    glBindVertexArray(app->vao_mesh);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, app->ibo_mesh);
    // PASS_OPAQUE and PASS_CUTOUT draw with depth writing on; PASS_TRANSLUCENT
    // blends with depth writes off, which is the vanilla order.
    for (int pass = PASS_OPAQUE; pass <= PASS_TRANSLUCENT; pass++) {
        int b = pass - PASS_OPAQUE;
        if (app->batch_count[b] <= 0) continue;
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

static void draw_hud(umbra_app *app) {
    hud_begin();
    float s = 1.0f;
    float y = 8.0f + (float)app->insets[1];
    float x = 8.0f + (float)app->insets[0];
    float line = 10.0f * s;
    char buf[256];

    hud_rect(0, 0, (float)app->width, (float)(220 + app->insets[1]), 0.0f, 0.0f, 0.0f, 0.55f);
    hud_text(x, y, s, 1, 1, 1, 1, "UMBRA - not an official Minecraft product");
    y += line * 1.6f;
    snprintf(buf, sizeof buf, "build %s  gl %s", UMBRA_GIT_COMMIT, app->gl_version);
    hud_text(x, y, s, 0.8f, 0.9f, 1.0f, 1, buf);
    y += line;
    snprintf(buf, sizeof buf, "renderer %s", app->gl_renderer);
    hud_text(x, y, s, 0.8f, 0.9f, 1.0f, 1, buf);
    y += line;
    snprintf(buf, sizeof buf, "depth %d bits  highp vs %s fs %s", app->depth_bits,
             app->highp_vertex, app->highp_fragment);
    hud_text(x, y, s, 0.8f, 0.9f, 1.0f, 1, buf);
    y += line;
    snprintf(buf, sizeof buf, "mesh %d verts %d indices  frame %.2f ms",
             app->vert_count, app->index_count, app->frame_us / 1000.0);
    hud_text(x, y, s, 0.8f, 0.9f, 1.0f, 1, buf);
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
        snprintf(buf, sizeof buf, "benchmark %.0f/%.0f s  frames %lld", elapsed,
                 (double)app->bench_seconds, (long long)umbra_bench_frames());
        hud_text(x, y, s, 1.0f, 0.9f, 0.4f, 1, buf);
    } else if (app->bench_text[0]) {
        hud_text(x, y, s, 0.7f, 1.0f, 0.7f, 1, app->bench_text);
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
    float bw = (float)app->width - 2 * x;
    float bh = 34.0f;
    float by = (float)app->height - (float)app->insets[3] - 3 * (bh + 8) - 8;
    struct { const char *label; int id; } buttons[3] = {
        {"RUN GPU SELF-TEST", 0}, {"RUN 60 s BENCHMARK", 1}, {"SHARE LOG", 2}};
    for (int i = 0; i < 3; i++) {
        float yy = by + i * (bh + 8);
        bool active = (i == 0 && app->selftest_ran) || (i == 1 && app->benching);
        hud_rect(x, yy, bw, bh, active ? 0.25f : 0.15f, active ? 0.55f : 0.25f, active ? 0.3f : 0.15f, 0.9f);
        hud_text(x + 8, yy + bh * 0.3f, 1.3f, 1, 1, 1, 1, buttons[i].label);
    }
    hud_flush(app);
}

void umbra_app_frame(umbra_app *app) {
    int64_t t0 = umbra_now_us();
    if (app->last_frame_time > 0) {
        app->frame_us = t0 - (int64_t)app->last_frame_time;
    }
    app->last_frame_time = (double)t0;

    glViewport(0, 0, app->width, app->height);
    glClearColor(0.55f, 0.70f, 0.92f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    draw_scene(app);
    draw_hud(app);
    app->frames_drawn++;

    if (app->benching) {
        umbra_bench_add(app->frame_us);
        double elapsed = (umbra_now_us() / 1000000.0) - app->bench_start_time;
        if (elapsed >= app->bench_seconds) {
            app->benching = false;
            char dev[128];
            snprintf(dev, sizeof dev, "%s", app->gl_renderer);
            int64_t len = 0;
            const uint8_t *text = umbra_bench_summary("bench", dev, app->gl_version, &len);
            snprintf(app->bench_text, sizeof app->bench_text, "%.*s", (int)len, (const char *)text);
            umbra_log(app, "%s", app->bench_text);
        }
    }
}

void umbra_app_touch(umbra_app *app, int32_t x, int32_t y, bool down) {
    if (!down) return;
    if (app->screen != UMBRA_SCREEN_HOME) return;
    float bh = 34.0f;
    float by = (float)app->height - (float)app->insets[3] - 3 * (bh + 8) - 8;
    float bx = 8.0f + (float)app->insets[0];
    float bw = (float)app->width - 2 * bx;
    for (int i = 0; i < 3; i++) {
        float yy = by + i * (bh + 8);
        if (x >= bx && x <= bx + bw && y >= yy && y <= yy + bh) {
            if (i == 0) {
                run_selftest(app);
            } else if (i == 1) {
                app->benching = true;
                app->bench_start_time = umbra_now_us() / 1000000.0;
                app->bench_text[0] = 0;
                umbra_bench_reset();
                umbra_log(app, "benchmark: start, %d seconds", app->bench_seconds);
            } else {
                umbra_log(app, "share log: requested");
                umbra_share_log(app);
            }
        }
    }
}
