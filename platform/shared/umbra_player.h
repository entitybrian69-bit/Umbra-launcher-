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
// The tallest step a walking body climbs without jumping. It was 0.51 -- a slab, not a
// block -- and that left a full block as a wall you had to jump over, which on a phone
// with one finger is the difference between walking and not. The game ships this as the
// "auto-jump" setting; here it is simply what walking does, and a three-block wall still
// stops the body because there is no headroom to step into (see the host test).
#define UMBRA_PLAYER_STEP 1.01f
#define UMBRA_PLAYER_SNEAK 1.31f  /* blocks per second while sneaking: 30% of a walk */
#define UMBRA_PLAYER_EYE_SNEAK 1.27f  /* the eye drops 0.35 while sneaking, as in the game */
#define UMBRA_PLAYER_SWIM 2.20f   /* horizontal speed in water */
#define UMBRA_PLAYER_SWIM_UP 4.0f /* pressing jump in water is a swim stroke, not a jump */
#define UMBRA_PLAYER_WATER_GRAVITY 8.0f
#define UMBRA_PLAYER_SINK 3.0f    /* the fastest a body sinks in water */
#define UMBRA_PLAYER_FLOAT 0.02f  /* how fast it drifts back up with nothing pressed */

// The grid: the top of the collision box in cell (x,y,z) above that cell's floor,
// in blocks (0..1). A negative value means the cell is not solid.
typedef float (*umbra_block_top_fn)(void *ctx, int x, int y, int z);

// Is this cell a fluid a body swims in? Separate from the top function because a fluid
// is not a collision box: the body passes through it and slows down instead.
typedef int (*umbra_fluid_fn)(void *ctx, int x, int y, int z);

// The grid, as the physics needs it. Held in one struct so a step takes one argument
// that cannot be paired with the wrong context, and so a caller with no fluids (the
// host tests that predate swimming) passes a null one instead of a stub.
typedef struct {
    umbra_block_top_fn top;
    umbra_fluid_fn fluid;   /* may be NULL: nothing in this world is swimmable */
    void *ctx;
} umbra_player_world;

typedef struct {
    float forward, strafe;  /* -1..1, in the body's own frame */
    int jump;               /* 1 on the frame the button went down */
    int sneak;              /* held, not toggled */
} umbra_player_input;

typedef struct {
    float x, y, z;      /* feet position */
    float vx, vy, vz;
    float yaw;          /* radians, 0 = looking down -Z */
    float pitch;        /* radians, clamped to +-89 degrees */
    int on_ground;
    int stepped;        /* how many times the body was lifted onto a low block */
    int sneaking;       /* this step was a sneak: slower, lower eye, holds the edge */
    int in_water;       /* the body's box overlapped a fluid this step */
    int stroke;         /* how many swim strokes the body has taken */
} umbra_player;

static inline void umbra_player_reset(umbra_player *p, float x, float y, float z) {
    p->x = x; p->y = y; p->z = z;
    p->vx = p->vy = p->vz = 0.0f;
    p->yaw = 0.0f; p->pitch = 0.0f;
    p->on_ground = 0;
    p->stepped = 0;
    p->sneaking = 0;
    p->in_water = 0;
    p->stroke = 0;
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

// The eye height follows the body: a sneaking body's head is 0.35 lower, and the camera
// with it, which is the only thing that tells a player the sneak is on.
static inline void umbra_player_eye(const umbra_player *p, float out[3]) {
    out[0] = p->x;
    out[1] = p->y + (p->sneaking ? UMBRA_PLAYER_EYE_SNEAK : UMBRA_PLAYER_EYE);
    out[2] = p->z;
}

// Is any part of the body's box inside a fluid? Sampled at the feet, the waist and the
// head rather than per cell: a body standing in a pond up to its waist is swimming in
// the game, and three samples say that without a loop over the box.
static inline int umbra_player_in_fluid(const umbra_player_world *w, const umbra_player *p) {
    if (!w->fluid) return 0;
    int x = (int)floorf(p->x), z = (int)floorf(p->z);
    float ys[3] = { p->y + 0.1f, p->y + UMBRA_PLAYER_HEIGHT * 0.5f, p->y + UMBRA_PLAYER_EYE };
    for (int i = 0; i < 3; i++) {
        int y = (int)floorf(ys[i]);
        if (w->fluid(w->ctx, x, y, z)) return 1;
    }
    return 0;
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
//
// The step is the one thing that has to agree with the world in both directions: a
// body that climbs a full block by walking must not also climb a full block with no
// headroom above it, or a wall becomes a ladder. So the lift is tried first, and kept
// only if the body then fits *and* the move buys real horizontal distance; otherwise
// the body is put back exactly where it was.
static inline void umbra_player_move_with_step(const umbra_player_world *w, umbra_player *p,
                                               int axis, float amount) {
    if (amount == 0.0f) return;
    if (!umbra_player_move_axis(w->top, w->ctx, p, axis, amount)) return;
    // Blocked. A body in water does not step; it swims over, which the step function
    // does with the stroke.
    if (!p->on_ground) { if (axis == 0) p->vx = 0.0f; else p->vz = 0.0f; return; }
    // Sneaking does not climb steps at all: that is what makes it a way to stand at
    // the edge of a drop instead of walking off it.
    if (p->sneaking) { if (axis == 0) p->vx = 0.0f; else p->vz = 0.0f; return; }
    if (umbra_player_blocked(w->top, w->ctx, p->x, p->y + UMBRA_PLAYER_STEP, p->z)) {
        if (axis == 0) p->vx = 0.0f; else p->vz = 0.0f;
        return;
    }
    float sx = p->x, sy = p->y, sz = p->z;
    p->y += UMBRA_PLAYER_STEP;
    if (umbra_player_move_axis(w->top, w->ctx, p, axis, amount)) {
        p->x = sx; p->y = sy; p->z = sz;
        if (axis == 0) p->vx = 0.0f; else p->vz = 0.0f;
        return;
    }
    // It fitted, but is there floor under it? A lift that turns a wall into a fall is
    // the bug this check exists for: the body must land on the step, not step into air.
    if (!umbra_player_blocked(w->top, w->ctx, p->x, p->y - 0.02f, p->z)) {
        p->x = sx; p->y = sy; p->z = sz;
        if (axis == 0) p->vx = 0.0f; else p->vz = 0.0f;
        return;
    }
    p->stepped++;
    p->vy = 0.0f;
}

// One physics step. `in` is what the controls say this step, dt is seconds and is
// sub-stepped so a long frame (a phone that stalled) cannot push the body through a
// wall.
//
// Three bodies are integrated here and they are different shapes: walking, swimming,
// and sneaking. Water is not a wall -- the body passes through it, sinks slowly, and a
// jump press is a stroke upward -- and a sneaking body is slower, lower, and does not
// step up or walk off an edge, which is the point of sneaking at all.
static inline void umbra_player_update(const umbra_player_world *w, umbra_player *p,
                                       float dt, umbra_player_input in) {
    if (dt <= 0.0f) return;
    if (dt > 0.25f) dt = 0.25f;      /* never integrate more than a quarter second */
    int steps = (int)ceilf(dt / (1.0f / 120.0f));
    if (steps < 1) steps = 1;
    if (steps > 30) steps = 30;
    float h = dt / (float)steps;

    p->sneaking = in.sneak ? 1 : 0;

    // Walk direction in world space from the yaw. Forward is -Z at yaw 0.
    float sy = sinf(p->yaw), cy = cosf(p->yaw);
    float wish_x = (-sy * in.forward) + (cy * in.strafe);
    float wish_z = (-cy * in.forward) - (sy * in.strafe);
    float len = sqrtf(wish_x * wish_x + wish_z * wish_z);
    if (len > 1.0f) { wish_x /= len; wish_z /= len; }

    int jump = in.jump;
    for (int s = 0; s < steps; s++) {
        p->in_water = umbra_player_in_fluid(w, p);

        if (p->in_water) {
            // Swimming. The walk speed does not apply: water is slower, the body sinks
            // at a walking pace rather than falling at gravity's, and a jump press is a
            // stroke that lifts it -- which is the whole of swimming in the game's own
            // terms. Horizontal control is direct, in the air or not, because a body in
            // water is not falling.
            p->vx = wish_x * UMBRA_PLAYER_SWIM;
            p->vz = wish_z * UMBRA_PLAYER_SWIM;
            if (jump) {
                p->vy = UMBRA_PLAYER_SWIM_UP;
                p->stroke++;
                jump = 0;
            } else {
                p->vy -= UMBRA_PLAYER_WATER_GRAVITY * h;
            }
            // The caps are on the *speed*, not on how far a stroke may take the body:
            // the first version clamped upward velocity to the buoyancy drift, which
            // cancelled every stroke on the substep after it began, so a body in water
            // could not rise at all (the host test caught it in one run).
            if (p->vy > UMBRA_PLAYER_SWIM_UP) p->vy = UMBRA_PLAYER_SWIM_UP;
            if (p->vy < -UMBRA_PLAYER_SINK) p->vy = -UMBRA_PLAYER_SINK;
            p->on_ground = 0;
        } else {
            // Ground control: the horizontal velocity is set directly, which is what a
            // walking body does; in the air only gravity and the launch velocity apply.
            if (p->on_ground) {
                float speed = p->sneaking ? UMBRA_PLAYER_SNEAK : UMBRA_PLAYER_WALK;
                p->vx = wish_x * speed;
                p->vz = wish_z * speed;
                if (jump) {
                    p->vy = UMBRA_PLAYER_JUMP;
                    p->on_ground = 0;
                    jump = 0;
                }
            }
            p->vy -= UMBRA_PLAYER_GRAVITY * h;
            if (p->vy < -UMBRA_PLAYER_TERMINAL) p->vy = -UMBRA_PLAYER_TERMINAL;
        }

        // Vertical first: landing has to happen before the horizontal move decides
        // whether the body is standing on something.
        int was_ground = p->on_ground;
        p->on_ground = 0;
        int hit = umbra_player_move_axis(w->top, w->ctx, p, 1, p->vy * h);
        if (hit) {
            if (p->vy < 0.0f) p->on_ground = 1;
            p->vy = 0.0f;
        } else if (was_ground && p->vy <= 0.0f) {
            // Walking off a block: check whether the floor is still under the feet.
            // 2 cm of tolerance holds the body steady on a slab's edge.
            if (umbra_player_blocked(w->top, w->ctx, p->x, p->y - 0.02f, p->z)) p->on_ground = 1;
        }

        // Horizontal, with a step-up attempt. A body walking into a half-block step
        // rises onto it instead of stopping at it.
        //
        // Sneaking keeps the body on the edge it is standing on: the game's rule, and
        // the reason to sneak near a drop. The body is moved, then put back if the move
        // would leave it with no floor under it.
        float px = p->x, py = p->y, pz = p->z;
        umbra_player_move_with_step(w, p, 0, p->vx * h);
        if (p->sneaking && p->on_ground && !p->in_water &&
            !umbra_player_blocked(w->top, w->ctx, p->x, p->y - 0.02f, p->z)) {
            p->x = px; p->y = py; p->z = pz;
            p->vx = 0.0f;
        }
        px = p->x; py = p->y; pz = p->z;
        umbra_player_move_with_step(w, p, 2, p->vz * h);
        if (p->sneaking && p->on_ground && !p->in_water &&
            !umbra_player_blocked(w->top, w->ctx, p->x, p->y - 0.02f, p->z)) {
            p->x = px; p->y = py; p->z = pz;
            p->vz = 0.0f;
        }
    }
}

// The old entry point, kept so the host tests written before water existed say what
// they always said: no fluids, and sneak as the ninth argument is not there yet.
static inline void umbra_player_step(umbra_block_top_fn top, void *ctx, umbra_player *p,
                                     float dt, float forward, float strafe, int jump) {
    umbra_player_world w;
    w.top = top;
    w.fluid = NULL;
    w.ctx = ctx;
    umbra_player_input in;
    in.forward = forward;
    in.strafe = strafe;
    in.jump = jump;
    in.sneak = 0;
    umbra_player_update(&w, p, dt, in);
}

#endif
