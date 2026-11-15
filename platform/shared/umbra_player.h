// Umbra player: one collidable body, a first-person camera, and no magic.
//
// The body is an axis-aligned box 0.6 wide and 1.8 tall, standing on the block it
// is over. Collision is resolved one axis at a time against the block grid, which
// comes in through a callback so this file knows nothing about chunks: the grid
// answers "how tall is the collision box in this cell", with 1.0 for a full block,
// 0.5 for the bottom slab the model path produces, and a negative number for
// anything that can be walked through (air, water, grass).
//
// Everything here is a pure function of its arguments plus that callback, which is
// why it is tested on the host without a GPU, a window, or a phone.
#ifndef UMBRA_PLAYER_H
#define UMBRA_PLAYER_H

#include <math.h>

#define UMBRA_PLAYER_HW 0.30f      /* half width of the body */
#define UMBRA_PLAYER_HEIGHT 1.80f
#define UMBRA_PLAYER_EYE 1.62f     /* eye height above the feet */
#define UMBRA_PLAYER_WALK 4.317f   /* blocks per second, the speed the game uses */
#define UMBRA_PLAYER_GRAVITY 32.0f
#define UMBRA_PLAYER_JUMP 8.95f    /* takes the body 1.25 blocks up */
#define UMBRA_PLAYER_TERMINAL 60.0f
#define UMBRA_PLAYER_REACH 5.0f
#define UMBRA_PLAYER_STEP 0.51f   /* the tallest step a walking body climbs */

// The grid: the top of the collision box in cell (x,y,z) above that cell's floor,
// in blocks (0..1). A negative value means the cell is not solid.
typedef float (*umbra_block_top_fn)(void *ctx, int x, int y, int z);

typedef struct {
    float x, y, z;      /* feet position */
    float vx, vy, vz;
    float yaw;          /* radians, 0 = looking down -Z */
    float pitch;        /* radians, clamped to +-89 degrees */
    int on_ground;
    int stepped;        /* how many times the body was lifted onto a low block */
} umbra_player;

static inline void umbra_player_reset(umbra_player *p, float x, float y, float z) {
    p->x = x; p->y = y; p->z = z;
    p->vx = p->vy = p->vz = 0.0f;
    p->yaw = 0.0f; p->pitch = 0.0f;
    p->on_ground = 0;
    p->stepped = 0;
}

static inline void umbra_player_look(umbra_player *p, float dyaw, float dpitch) {
    p->yaw += dyaw;
    // Keep yaw in [-pi, pi) so the HUD cannot print a number that grows forever.
    while (p->yaw >= 3.14159265f) p->yaw -= 6.28318531f;
    while (p->yaw < -3.14159265f) p->yaw += 6.28318531f;
    p->pitch += dpitch;
    // Straight up or straight down is not a look direction; stop just short of it.
    float limit = 1.55334303f; /* 89 degrees */
    if (p->pitch > limit) p->pitch = limit;
    if (p->pitch < -limit) p->pitch = -limit;
}

static inline void umbra_player_eye(const umbra_player *p, float out[3]) {
    out[0] = p->x;
    out[1] = p->y + UMBRA_PLAYER_EYE;
    out[2] = p->z;
}

// The unit vector the player is looking along.
static inline void umbra_player_forward(const umbra_player *p, float out[3]) {
    float cp = cosf(p->pitch);
    out[0] = -sinf(p->yaw) * cp;
    out[1] = sinf(p->pitch);
    out[2] = -cosf(p->yaw) * cp;
}

// Does the body at (x,y,z) overlap a solid cell?
static inline int umbra_player_blocked(umbra_block_top_fn top, void *ctx,
                                       float x, float y, float z) {
    float lo[3] = { x - UMBRA_PLAYER_HW, y, z - UMBRA_PLAYER_HW };
    float hi[3] = { x + UMBRA_PLAYER_HW, y + UMBRA_PLAYER_HEIGHT, z + UMBRA_PLAYER_HW };
    int x0 = (int)floorf(lo[0]), x1 = (int)floorf(hi[0] - 0.0001f);
    int y0 = (int)floorf(lo[1]), y1 = (int)floorf(hi[1] - 0.0001f);
    int z0 = (int)floorf(lo[2]), z1 = (int)floorf(hi[2] - 0.0001f);
    for (int by = y0; by <= y1; by++) {
        for (int bz = z0; bz <= z1; bz++) {
            for (int bx = x0; bx <= x1; bx++) {
                float t = top(ctx, bx, by, bz);
                if (t <= 0.0f) continue;
                // The cell's box is [bx,bx+1] x [by, by+t] x [bz,bz+1]; the body has
                // to actually overlap it, not merely share a plane.
                if (hi[0] <= (float)bx || lo[0] >= (float)bx + 1.0f) continue;
                if (hi[2] <= (float)bz || lo[2] >= (float)bz + 1.0f) continue;
                if (hi[1] <= (float)by || lo[1] >= (float)by + t) continue;
                return 1;
            }
        }
    }
    return 0;
}

// Move along one axis; if the destination is blocked, walk back to just touching.
// Returns 1 if the move was stopped.
static inline int umbra_player_move_axis(umbra_block_top_fn top, void *ctx, umbra_player *p,
                                         int axis, float amount) {
    if (amount == 0.0f) return 0;
    float nx = p->x, ny = p->y, nz = p->z;
    if (axis == 0) nx += amount;
    else if (axis == 1) ny += amount;
    else nz += amount;
    if (!umbra_player_blocked(top, ctx, nx, ny, nz)) {
        p->x = nx; p->y = ny; p->z = nz;
        return 0;
    }
    // Binary search the last free position: eight halvings is 4 mm at walking
    // speed and is cheaper than a per-cell clamp, and it cannot tunnel.
    float lo = 0.0f, hi = 1.0f;
    for (int i = 0; i < 12; i++) {
        float mid = (lo + hi) * 0.5f;
        float tx = p->x, ty = p->y, tz = p->z;
        if (axis == 0) tx += amount * mid;
        else if (axis == 1) ty += amount * mid;
        else tz += amount * mid;
        if (umbra_player_blocked(top, ctx, tx, ty, tz)) hi = mid;
        else { lo = mid; p->x = tx; p->y = ty; p->z = tz; }
    }
    return 1;
}

// Move horizontally, rising over a low step if that is what it takes.
static inline void umbra_player_move_with_step(umbra_block_top_fn top, void *ctx, umbra_player *p,
                                               int axis, float amount) {
    if (amount == 0.0f) return;
    if (!umbra_player_move_axis(top, ctx, p, axis, amount)) return;
    // Blocked. Try again from a little higher up, but only if the body is walking.
    if (!p->on_ground) { if (axis == 0) p->vx = 0.0f; else p->vz = 0.0f; return; }
    if (umbra_player_blocked(top, ctx, p->x, p->y + UMBRA_PLAYER_STEP, p->z)) {
        if (axis == 0) p->vx = 0.0f; else p->vz = 0.0f;
        return;
    }
    float sx = p->x, sy = p->y, sz = p->z;
    p->y += UMBRA_PLAYER_STEP;
    if (umbra_player_move_axis(top, ctx, p, axis, amount)) {
        p->x = sx; p->y = sy; p->z = sz;
        if (axis == 0) p->vx = 0.0f; else p->vz = 0.0f;
        return;
    }
    p->stepped++;
    p->vy = 0.0f;
}

// One physics step. `forward` and `strafe` are -1..1; `jump` is 1 for a press.
// dt is seconds and is sub-stepped so a long frame (a phone that stalled) cannot
// push the body through a wall.
static inline void umbra_player_step(umbra_block_top_fn top, void *ctx, umbra_player *p,
                                     float dt, float forward, float strafe, int jump) {
    if (dt <= 0.0f) return;
    if (dt > 0.25f) dt = 0.25f;      /* never integrate more than a quarter second */
    int steps = (int)ceilf(dt / (1.0f / 120.0f));
    if (steps < 1) steps = 1;
    if (steps > 30) steps = 30;
    float h = dt / (float)steps;

    // Walk direction in world space from the yaw. Forward is -Z at yaw 0.
    float sy = sinf(p->yaw), cy = cosf(p->yaw);
    float wish_x = (-sy * forward) + (cy * strafe);
    float wish_z = (-cy * forward) - (sy * strafe);
    float len = sqrtf(wish_x * wish_x + wish_z * wish_z);
    if (len > 1.0f) { wish_x /= len; wish_z /= len; }

    for (int s = 0; s < steps; s++) {
        // Ground control: the horizontal velocity is set directly, which is what a
        // walking body does; in the air only gravity and the launch velocity apply.
        if (p->on_ground) {
            p->vx = wish_x * UMBRA_PLAYER_WALK;
            p->vz = wish_z * UMBRA_PLAYER_WALK;
            if (jump) {
                p->vy = UMBRA_PLAYER_JUMP;
                p->on_ground = 0;
            }
        }
        p->vy -= UMBRA_PLAYER_GRAVITY * h;
        if (p->vy < -UMBRA_PLAYER_TERMINAL) p->vy = -UMBRA_PLAYER_TERMINAL;

        // Vertical first: landing has to happen before the horizontal move decides
        // whether the body is standing on something.
        int was_ground = p->on_ground;
        p->on_ground = 0;
        int hit = umbra_player_move_axis(top, ctx, p, 1, p->vy * h);
        if (hit) {
            if (p->vy < 0.0f) p->on_ground = 1;
            p->vy = 0.0f;
        } else if (was_ground && p->vy <= 0.0f) {
            // Walking off a block: check whether the floor is still under the feet.
            // 2 cm of tolerance holds the body steady on a slab's edge.
            if (umbra_player_blocked(top, ctx, p->x, p->y - 0.02f, p->z)) p->on_ground = 1;
        }

        // Horizontal, with a step-up attempt. A body walking into a half-block step
        // rises onto it instead of stopping at it; the lift is kept only when it buys
        // real horizontal movement, otherwise the body is put back exactly where it
        // was, which is what stops a body pressed against a wall from climbing it.
        umbra_player_move_with_step(top, ctx, p, 0, p->vx * h);
        umbra_player_move_with_step(top, ctx, p, 2, p->vz * h);
    }
}

#endif
