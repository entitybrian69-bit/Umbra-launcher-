// C side of the Goose boundary: the few conversions and platform calls written
// in C because they are C-level bit operations or OS APIs. Every fallback from
// Goose to C is listed in DECISIONS.md.
#include <stdint.h>
#include <string.h>

float umbra_c_f32_from_bits(uint32_t bits) { float f; memcpy(&f, &bits, 4); return f; }
double umbra_c_f64_from_bits(uint64_t bits) { double d; memcpy(&d, &bits, 8); return d; }
