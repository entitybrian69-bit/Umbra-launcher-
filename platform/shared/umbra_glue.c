// C side of the Goose boundary: the few conversions and platform calls written
// in C because they are C-level bit operations or OS APIs. Every fallback from
// Goose to C is listed in DECISIONS.md.
#include <stdint.h>
#include <string.h>

float umbra_c_f32_from_bits(uint32_t bits) { float f; memcpy(&f, &bits, 4); return f; }
double umbra_c_f64_from_bits(uint64_t bits) { double d; memcpy(&d, &bits, 8); return d; }
uint32_t umbra_c_bits_of_f32(float v) { uint32_t b; memcpy(&b, &v, 4); return b; }
uint64_t umbra_c_bits_of_f64(double v) { uint64_t b; memcpy(&b, &v, 8); return b; }

#include <time.h>
uint32_t umbra_c_time_seconds(void) { return (uint32_t)time(NULL); }

// Monotonic microseconds. Goose asks for this to measure how much of a frame's
// meshing budget it has used; the sliced mesher cannot be timed from C without
// handing the loop back and forth once per section.
#ifdef _WIN32
#include <windows.h>
int64_t umbra_c_now_us(void) {
    static LARGE_INTEGER freq;
    LARGE_INTEGER now;
    if (!freq.QuadPart) QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&now);
    return (int64_t)((double)now.QuadPart * 1000000.0 / (double)freq.QuadPart);
}
#else
int64_t umbra_c_now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}
#endif
