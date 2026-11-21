// Frustum culling for the world's draw ranges.
//
// The renderer draws one glDrawElements per (pass, column) -- 243 of them for a radius-4
// window -- and until now every one of them was drawn whatever the camera was looking at.
// A walking player sees at most a quarter of a 9x9 window, so three quarters of the draw
// calls, the vertex fetch and the fragment work were spent on geometry behind them.
//
// The test is the standard six-plane one: extract the frustum from the view-projection
// matrix, and reject a box that is entirely outside any plane. A box's positive vertex
// (the corner furthest along each plane's normal) is the cheapest correct test: if *that*
// corner is behind a plane, the whole box is.
//
// Column-major, GL's layout: m[col*4+row]. The rows of the view-projection give the planes
// directly -- left = row3 + row0, right = row3 - row0, and so on -- because a clip
// coordinate is kept when -w <= x <= w.

#ifndef UMBRA_CULL_H
#define UMBRA_CULL_H

#include <stdint.h>

typedef struct {
    float p[6][4];   // six planes, (a,b,c,d): a*x + b*y + c*z + d >= 0 is inside
    int enabled;
} umbra_frustum;

// Did this frame's camera actually look at anything outside the box? Counted, because a
// culling win that nobody measures is indistinguishable from culling that never ran.
typedef struct {
    int64_t ranges_total;
    int64_t ranges_drawn;
    int64_t boxes_rejected;
} umbra_cull_stats;

static inline void umbra_frustum_from_vp(umbra_frustum *f, const float *m) {
    // Rows of the matrix. GL stores column-major: element (row r, column c) is at
    // m[c*4+r], so row r is m[0*4+r], m[1*4+r], m[2*4+r], m[3*4+r].
    //
    // Both other ways of writing this walk a column instead of a row, and the symptom is
    // a cull that rejects boxes in front of the camera: the planes come out as
    // (1,0,0.2,0) rather than (1,0,0,0), the near term leaks into the x plane, and the
    // box at x = -1 falls outside it. The host's seven box checks catch it.
    float r0[4], r1[4], r2[4], r3[4];
    // Row r, element i is m[i*4 + r]: element (row r, column c) is at m[c*4+r].
    for (int i = 0; i < 4; i++) {
        r0[i] = m[i * 4 + 0];
        r1[i] = m[i * 4 + 1];
        r2[i] = m[i * 4 + 2];
        r3[i] = m[i * 4 + 3];
    }
    for (int i = 0; i < 4; i++) {
        f->p[0][i] = r3[i] + r0[i];   // left
        f->p[1][i] = r3[i] - r0[i];   // right
        f->p[2][i] = r3[i] + r1[i];   // bottom
        f->p[3][i] = r3[i] - r1[i];   // top
        f->p[4][i] = r3[i] + r2[i];   // near
        f->p[5][i] = r3[i] - r2[i];   // far
    }
    f->enabled = 1;
}

// Is any part of the box inside? Returns 0 when the box is entirely outside one plane.
// `pad` grows the box, so a column at the edge is kept when its geometry's own box is
// exact: the mesher's box holds vertices, and a vertex is a corner of a face, not the face.
static inline int umbra_frustum_box(const umbra_frustum *f, float x0, float y0, float z0,
                                    float x1, float y1, float z1, float pad) {
    if (!f->enabled) return 1;
    x0 -= pad; y0 -= pad; z0 -= pad;
    x1 += pad; y1 += pad; z1 += pad;
    for (int i = 0; i < 6; i++) {
        const float *p = f->p[i];
        // The positive vertex: the box corner furthest along this plane's normal.
        float px = p[0] >= 0.0f ? x1 : x0;
        float py = p[1] >= 0.0f ? y1 : y0;
        float pz = p[2] >= 0.0f ? z1 : z0;
        if (p[0] * px + p[1] * py + p[2] * pz + p[3] < 0.0f) return 0;
    }
    return 1;
}

#endif
