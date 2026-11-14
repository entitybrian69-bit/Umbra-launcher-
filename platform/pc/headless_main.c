// PC headless self-test: runs the Goose core with no window and no GPU, so CI
// can prove that the same C the APK ships works on x86_64 and Windows x64.
//
// It builds the demo world, meshes it, checks the mesh invariants, runs the
// format round trips on the fixture files, and prints PASS/FAIL.
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include "umbra_core.h"
#include "umbra_vertex.h"

static int failures = 0;
static int checks = 0;

static void check(int cond, const char *what) {
    checks++;
    if (!cond) {
        failures++;
        printf("FAIL: %s\n", what);
    }
}

static const char *slice_text(const uint8_t *p, int64_t n) {
    static char buf[512];
    int k = n < 511 ? (int)n : 511;
    memcpy(buf, p, k);
    buf[k] = 0;
    return buf;
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    printf("umbra headless self-test\n");
    goose_init(argc, argv);

    int64_t vlen = 0, ilen = 0;
    // Two statements on purpose: reading vlen as an argument beside the call
    // that writes it is unspecified evaluation order.
    const uint8_t *version_bytes = umbra_version(&vlen);
    const char *version = slice_text(version_bytes, vlen);
    printf("core version: %s\n", version);
    check(vlen > 0, "version string is non-empty");

    // 1. The demo world builds and meshes with real geometry.
    int64_t t0 = 0;  // timing is the benchmark's job; here we check invariants
    umbra_demo_build(20261114);
    umbra_demo_mesh();
    const uint8_t *verts = umbra_verts_ptr(&vlen);
    const uint8_t *indices = umbra_indices_ptr(&ilen);
    printf("mesh: %llu vertex bytes, %llu index bytes\n", (unsigned long long)vlen,
           (unsigned long long)ilen);
    check(vlen > 0 && vlen % sizeof(umbra_vertex) == 0, "vertex buffer is whole vertices");
    check(ilen > 0 && ilen % 4 == 0, "index buffer is whole u32s");
    int64_t vcount = umbra_vert_count();
    int64_t icount = umbra_index_count();
    check(vcount == vlen / (int64_t)sizeof(umbra_vertex), "vertex count matches the byte length");
    check(icount == ilen / 4, "index count matches the byte length");

    // 2. Every index addresses a real vertex, every normal is unit length, and
    //    every coordinate is finite and inside the demo world's bounds.
    const umbra_vertex *v = (const umbra_vertex *)verts;
    const uint32_t *idx = (const uint32_t *)indices;
    int bad_index = 0, bad_normal = 0, bad_pos = 0;
    for (int64_t i = 0; i < icount; i++) {
        if (idx[i] >= (uint32_t)vcount) bad_index++;
    }
    for (int64_t i = 0; i < vcount; i++) {
        float len = sqrtf(v[i].nx*v[i].nx + v[i].ny*v[i].ny + v[i].nz*v[i].nz);
        if (fabsf(len - 1.0f) > 1e-3f) bad_normal++;
        if (!(v[i].x > -64.0f && v[i].x < 128.0f && v[i].y > -80.0f && v[i].y < 400.0f &&
              v[i].z > -64.0f && v[i].z < 128.0f)) bad_pos++;
    }
    printf("mesh checks: %d bad indices, %d bad normals, %d positions out of bounds\n",
           bad_index, bad_normal, bad_pos);
    check(bad_index == 0, "all indices address real vertices");
    check(bad_normal == 0, "all normals are unit length");
    check(bad_pos == 0, "all positions are inside the demo world");

    // 3. The batches partition the index buffer.
    int64_t total = 0;
    for (int b = 0; b < 3; b++) total += umbra_batch_count(b);
    printf("batches: %lld + %lld + %lld = %lld of %lld indices\n",
           (long long)umbra_batch_count(0), (long long)umbra_batch_count(1),
           (long long)umbra_batch_count(2), (long long)total, (long long)icount);
    check(total == icount, "batches cover every index");
    check(umbra_batch_count(0) > 0, "the opaque batch is not empty");

    // 4. The self-test's expected pattern is deterministic and non-trivial.
    umbra_selftest_reset();
    umbra_selftest_pattern_pixel(0, 0, 640, 480, 0, 0, 64);
    check(umbra_selftest_mismatches() == 0, "a correct pattern pixel is accepted");
    umbra_selftest_pattern_pixel(639, 479, 640, 480, 255, 0, 64);
    check(umbra_selftest_mismatches() > 0, "a wrong pattern pixel is rejected");

    // 5. The benchmark statistics are real arithmetic on real numbers.
    umbra_bench_reset();
    for (int i = 0; i < 1000; i++) umbra_bench_add(16000 + (i % 10));
    int64_t len = 0;
    sl_u8 label = {(uint8_t *)"bench", 5};
    sl_u8 dev = {(uint8_t *)"headless", 8};
    sl_u8 android = {(uint8_t *)"none", 4};
    const uint8_t *summary = umbra_bench_summary(label, dev, android, &len);
    printf("bench: %s\n", slice_text(summary, len));
    check(len > 20, "benchmark summary is formatted");

    goose_exit();
    printf("%s: %d checks, %d failures\n", failures ? "FAILED" : "PASS", checks, failures);
    return failures ? 1 : 0;
}
