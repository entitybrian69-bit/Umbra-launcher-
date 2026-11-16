// Stub of <android/native_activity.h>: only the fields android_main.c reads.
#ifndef UMBRA_STUB_ANDROID_NATIVE_ACTIVITY_H
#define UMBRA_STUB_ANDROID_NATIVE_ACTIVITY_H
#include <jni.h>
#include <android/native_window.h>
#include <android/log.h>
typedef struct ANativeActivityCallbacks ANativeActivityCallbacks;
typedef struct ANativeActivity {
    ANativeActivityCallbacks *callbacks;
    JavaVM *vm;
    JNIEnv *env;
    jobject clazz;
    const char *internalDataPath;
    const char *externalDataPath;
    int32_t sdkVersion;
    void *instance;
    void *assetManager;
    const char *obbPath;
} ANativeActivity;
#endif
