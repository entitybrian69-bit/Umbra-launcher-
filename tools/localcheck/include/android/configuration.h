// Stub of <android/configuration.h>: only what android_main.c asks for.
#ifndef UMBRA_STUB_ANDROID_CONFIGURATION_H
#define UMBRA_STUB_ANDROID_CONFIGURATION_H
#include <stdint.h>
typedef struct AConfiguration AConfiguration;
enum { ACONFIGURATION_DENSITY_ANY = 0xfffe };
int32_t AConfiguration_getDensity(const AConfiguration *config);
#endif
