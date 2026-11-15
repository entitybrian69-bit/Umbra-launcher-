// A stub of the NDK's android_native_app_glue.h, holding only what
// platform/android/android_main.c uses. It exists so tools/check_c.sh compiles
// the real Android source on a desktop before a ten-minute CI round trip: the
// JNI inset code that crashed the emulator was never compiled by that script,
// because the header was missing here.
#ifndef UMBRA_STUB_ANDROID_NATIVE_APP_GLUE_H
#define UMBRA_STUB_ANDROID_NATIVE_APP_GLUE_H
#include <jni.h>
#include <android/log.h>
#include <android/asset_manager.h>
#include <android/configuration.h>
#include <android/input.h>
#include <android/looper.h>
#include <android/native_activity.h>
#include <android/native_window.h>
#include <EGL/egl.h>

enum {
    APP_CMD_INPUT_CHANGED = 1,
    APP_CMD_INIT_WINDOW = 2,
    APP_CMD_TERM_WINDOW = 3,
    APP_CMD_WINDOW_RESIZED = 4,
    APP_CMD_CONFIG_CHANGED = 5,
    APP_CMD_LOW_MEMORY = 6,
    APP_CMD_START = 7,
    APP_CMD_RESUME = 8,
    APP_CMD_SAVE_STATE = 9,
    APP_CMD_PAUSE = 10,
    APP_CMD_STOP = 11,
    APP_CMD_DESTROY = 12
};

struct android_app {
    void *userData;
    void (*onAppCmd)(struct android_app *app, int32_t cmd);
    int32_t (*onInputEvent)(struct android_app *app, AInputEvent *event);
    ANativeActivity *activity;
    AConfiguration *config;
    ANativeWindow *window;
    ALooper *looper;
    void *inputQueue;
    int32_t (*onInputQueueCreated)(struct android_app *app, void *queue);
    void (*onInputQueueDestroyed)(struct android_app *app, void *queue);
    int destroyRequested;
    void *mutex_unused;
};

struct android_poll_source {
    int32_t id;
    struct android_app *app;
    void (*process)(struct android_app *app, struct android_poll_source *source);
};

void app_dummy(void);

#endif
