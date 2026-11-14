// The vertex the GPU reads. Must match `struct Vertex` in goose/core/mesh.goose
// (12 packed f32), and the attribute setup in umbra_app.c.
#pragma once
#include <stddef.h>

typedef struct __attribute__((packed)) {
    float x, y, z;      // position, block units
    float nx, ny, nz;   // normal
    float u, v;         // atlas UV
    float r, g, b;      // tint * face shade
    float ao;           // baked ambient occlusion
} umbra_vertex;
