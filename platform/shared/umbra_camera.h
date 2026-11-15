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
    fit.fog_near = fit.dist + fit_h * 0.20f;
    fit.fog_far = fit.dist + fit_h * 2.20f;
    if (fit.fog_near < 1.0f) fit.fog_near = 1.0f;
    fit.ok = 1;
    return fit;
}

#endif
