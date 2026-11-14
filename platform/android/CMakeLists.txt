# Builds libumbra_core (Goose -> C, generated before CMake runs) and libumbra
# (the C platform layer) into one shared library for the APK.
cmake_minimum_required(VERSION 3.22.1)
project(umbra C)

set(CMAKE_C_STANDARD 11)

# Where the build system put the generated C and header.
set(UMBRA_GEN_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../build/gen)
set(UMBRA_GIT_COMMIT "unknown" CACHE STRING "git commit recorded in the app")

add_library(umbra SHARED
    ${UMBRA_GEN_DIR}/umbra_core.c
    ../../platform/shared/umbra_app.c
    ../../platform/shared/umbra_glue.c
    android_main.c
    ${ANDROID_NDK}/sources/android/native_app_glue/android_native_app_glue.c)

target_include_directories(umbra PRIVATE
    ${UMBRA_GEN_DIR}
    ../../platform/shared)

target_compile_definitions(umbra PRIVATE
    UMBRA_GIT_COMMIT="${UMBRA_GIT_COMMIT}")

target_compile_options(umbra PRIVATE -O2 -fno-finite-math-only -Wall -Wno-unused-parameter)
target_link_libraries(umbra PRIVATE android log EGL GLESv3 m)
