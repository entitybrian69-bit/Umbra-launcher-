// Framing the home view: where the eye is, what it looks at, and how far the fog
// reaches -- from the world's bounds and the part of the screen that is not
// covered by the overlay.
//
// Pure arithmetic, like umbra_hud.h, so `platform/pc/headless_main.c` can check it
// against the owner's phone (2412x1080, a 63 px status bar, a 126 px navigation
// bar) without an emulator. The first version of this was a hand-picked distance
// of 55 blocks and a fixed look-at point, which on that phone drew a thumbnail of
// the world under a panel: the screenshot the owner sent was almost all sky.
#ifndef UMBRA_CAMERA_H
#define UMBRA_CAMERA_H

#include <math.h>

typedef struct {
    float dist;          // eye to the point it looks at, in blocks
    float look[3];       // what the eye is aimed at
    float eye[3];        // where the eye is
    float radius;        // half the diagonal of what was fitted, for the record
    float fitted_height; // the height of the world that was fitted
    float fog_near, fog_far;
    float band_fraction; // how much of the screen height the world may fill
    int ok;
} umbra_camera_fit;

// A three-quarter view from about 27 degrees up, normalised so |eye - look| is
// exactly dist.
#define UMBRA_CAMERA_DIR_X 0.617f
#define UMBRA_CAMERA_DIR_Y 0.458f
#define UMBRA_CAMERA_DIR_Z 0.640f

static umbra_camera_fit umbra_camera_fit_world(const float min[3], const float max[3],
                                               float fov_y_deg, int width, int height,
                                               float band_top, float band_bottom) {
    umbra_camera_fit fit;
    fit.ok = 0;
    fit.dist = 55.0f;
    fit.look[0] = fit.look[1] = fit.look[2] = 0.0f;
    fit.eye[0] = fit.eye[1] = fit.eye[2] = 0.0f;
    fit.radius = 1.0f;
    fit.fitted_height = 1.0f;
    fit.fog_near = 1.0f;
    fit.fog_far = 10.0f;
    fit.band_fraction = 0.0f;
    if (!min || !max || width < 16 || height < 16 || fov_y_deg <= 1.0f || fov_y_deg >= 170.0f) {
        return fit;
    }
    float span[3];
    for (int i = 0; i < 3; i++) {
        span[i] = max[i] - min[i];
        if (span[i] < 0.0f) span[i] = 0.0f;
        fit.look[i] = (min[i] + max[i]) * 0.5f;
    }
    float horiz = span[0] > span[2] ? span[0] : span[2];
    if (horiz < 1.0f) horiz = 1.0f;
    // What is worth framing is the *top* of the world: the demo mesh runs down to
    // y = -64 because that is how far a column is meshed, so the box centre is
    // 38 blocks up a wall of rock, and a camera aimed there drew exactly that -- a
    // grey wall through the middle of the screen. The height that has to fit is
    // the part above the ground, capped at the footprint so a tall thin world is
    // not pushed to the horizon.
    float fit_h = span[1] < horiz * 0.75f ? span[1] : horiz * 0.75f;
    if (fit_h < 1.0f) fit_h = 1.0f;
    fit.fitted_height = fit_h;
    fit.radius = 0.5f * sqrtf(horiz * horiz + fit_h * fit_h);

    float band = (band_bottom - band_top) / (float)height;
    if (band < 0.15f) band = 0.15f;
    if (band > 1.0f) band = 1.0f;
    fit.band_fraction = band;

    float aspect = (float)width / (float)height;
    if (aspect < 0.5f) aspect = 0.5f;
    float tan_v = tanf(fov_y_deg * 3.14159265f / 180.0f * 0.5f);
    float tan_h = tan_v * aspect;
    const float fill = 0.92f;   // a margin around the world, so nothing touches an edge

    // Fitted to the screen, then *centred* in the band by the caller's shift. A
    // world fitted strictly inside the band on a landscape phone is a thumbnail
    // between two walls of interface; one that overhangs the translucent panel a
    // little reads as a world, and nothing important is under the opaque buttons.
    float d_v = (fit_h * 0.5f) / (tan_v * fill);
    float d_h = (horiz * 0.5f) / (tan_h * fill);
    fit.dist = d_v > d_h ? d_v : d_h;
    if (fit.dist < 16.0f) fit.dist = 16.0f;
    if (fit.dist > 400.0f) fit.dist = 400.0f;

    // Aim at the middle of that visible height, which for a world whose solid
    // floor is never seen is a few blocks under the peak.
    fit.look[1] = max[1] - fit_h * 0.5f;

    fit.eye[0] = fit.look[0] + fit.dist * UMBRA_CAMERA_DIR_X;
    fit.eye[1] = fit.look[1] + fit.dist * UMBRA_CAMERA_DIR_Y;
    fit.eye[2] = fit.look[2] + fit.dist * UMBRA_CAMERA_DIR_Z;

    // Fog starts behind the point the eye is aimed at, so everything nearer than
    // the middle of the world is at full colour, and ends well past the far side.
    // The first version started it before the aim point and the island came out a
    // pale ghost of itself in the screenshot.
    // The fog is depth cueing, not weather: it has to start past the far side of
    // the world, or the world itself is what gets greyed out. With textures (0.3.2
    // onwards) a fog that began at dist + 0.2 * height washed the grass to sky
    // colour in the middle of the screen; at 0.8 it clears the whole island and
    // still fades the empty distance.
    fit.fog_near = fit.dist + fit_h * 0.80f;
    fit.fog_far = fit.dist + fit_h * 3.00f;
    if (fit.fog_near < 1.0f) fit.fog_near = 1.0f;
    fit.ok = 1;
    return fit;
}

// One world, one camera. What the mesh shader does to a vertex, in the same arithmetic, so
// the host suite can ask the question the phone answered wrongly for six runs:
//
//   view_proj * position, with the distance to the eye measured from the same eye.
//
// The shader used to subtract a second origin (`u_center`: the mesh centre for the
// overview, the player for a walking body) from the position *and* still be handed a
// world-space view matrix. Every path then drew the world translated twice. The overview
// survived by arithmetic accident -- its look-at point is the mesh centre, so the second
// subtraction landed on the first -- and first person did not: the body's own position
// jumped the world backwards by however far it had walked, a wall 3 blocks away measured
// 30, fog_far is 96, and the frame was the sky colour with 32 ranges drawn. That is runs
// 44951752864 through 449798981, six blank screenshots and a different wrong theory each.
//
// `umbra_shader_fog` below is that shader's fog term. `umbra_shader_clip` is its clip-space
// y and w, which is what decides whether a triangle is on screen at all.
static float umbra_shader_dist(const float pos[3], const float eye[3]) {
    float dx = pos[0] - eye[0], dy = pos[1] - eye[1], dz = pos[2] - eye[2];
    return sqrtf(dx * dx + dy * dy + dz * dz);
}

static float umbra_shader_fog(float dist, float near, float far) {
    if (far <= near) return 1.0f;
    float f = (dist - near) / (far - near);
    if (f < 0.0f) f = 0.0f;
    if (f > 1.0f) f = 1.0f;
    return f;
}

// The clip-space y and w of a world position through a column-major view-projection,
// which is how the rasteriser and the GPU both read it: clip.y = row 1, clip.w = row 3.
static void umbra_shader_clip(const float vp[16], const float pos[3],
                              float *out_y, float *out_w) {
    *out_y = vp[1] * pos[0] + vp[5] * pos[1] + vp[9] * pos[2] + vp[13];
    *out_w = vp[3] * pos[0] + vp[7] * pos[1] + vp[11] * pos[2] + vp[15];
}

static void umbra_camera_look_at(float *m, const float eye[3], const float target[3], const float up[3]) {
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
#endif
