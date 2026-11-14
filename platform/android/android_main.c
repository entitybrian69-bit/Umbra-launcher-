// Android entry point: a NativeActivity driven by android_native_app_glue,
// which owns the ALooper/main-thread event pump. No Java code of ours runs;
// the APK's Java is the framework's NativeActivity.
#include <android_native_app_glue.h>
#include <android/log.h>
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <jni.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>

#include "umbra_app.h"

#define TAG "umbra"
#define ALOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)
#define ALOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)

typedef struct {
    struct android_app *state;
    EGLDisplay display;
    EGLSurface surface;
    EGLContext context;
    int32_t width, height;
    bool egl_ready;
    int pending_restart;   // set when the window comes back after a pause
    struct umbra_app app;
    bool app_ready;
    char files_dir[512];
} android_state;

static android_state g_st;

static int init_egl(android_state *st) {
    st->display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (st->display == EGL_NO_DISPLAY) { ALOGE("no EGL display"); return 0; }
    if (!eglInitialize(st->display, NULL, NULL)) { ALOGE("eglInitialize failed"); return 0; }

    // GLES 3.0, 8-bit colour and a 24-bit depth buffer (the brief says avoid
    // 16-bit depth: it shows as z-fighting on real phones).
    const EGLint config_attribs[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8,
        EGL_NONE
    };
    EGLConfig config;
    EGLint num = 0;
    if (!eglChooseConfig(st->display, config_attribs, &config, 1, &num) || num == 0) {
        ALOGE("no EGL config with GLES3 and 24-bit depth; retrying with 16-bit depth");
        const EGLint loose[] = {
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
            EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
            EGL_DEPTH_SIZE, 16,
            EGL_NONE
        };
        if (!eglChooseConfig(st->display, loose, &config, 1, &num) || num == 0) {
            ALOGE("no EGL config supports GLES 3.0");
            return 0;
        }
    }
    const EGLint ctx_attribs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    st->context = eglCreateContext(st->display, config, EGL_NO_CONTEXT, ctx_attribs);
    if (st->context == EGL_NO_CONTEXT) { ALOGE("eglCreateContext failed"); return 0; }
    st->surface = eglCreateWindowSurface(st->display, config, st->state->window, NULL);
    if (st->surface == EGL_NO_SURFACE) { ALOGE("eglCreateWindowSurface failed"); return 0; }
    if (!eglMakeCurrent(st->display, st->surface, st->surface, st->context)) {
        ALOGE("eglMakeCurrent failed");
        return 0;
    }
    EGLint w = 0, h = 0;
    eglQuerySurface(st->display, st->surface, EGL_WIDTH, &w);
    eglQuerySurface(st->display, st->surface, EGL_HEIGHT, &h);
    st->width = w;
    st->height = h;
    ALOGI("EGL up: %dx%d GL_VERSION %s", w, h, (const char *)glGetString(GL_VERSION));
    st->egl_ready = true;
    return 1;
}

static void destroy_egl(android_state *st) {
    if (st->display != EGL_NO_DISPLAY) {
        eglMakeCurrent(st->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (st->context != EGL_NO_CONTEXT) eglDestroyContext(st->display, st->context);
        if (st->surface != EGL_NO_SURFACE) eglDestroySurface(st->display, st->surface);
        eglTerminate(st->display);
    }
    st->display = EGL_NO_DISPLAY;
    st->context = EGL_NO_CONTEXT;
    st->surface = EGL_NO_SURFACE;
    st->egl_ready = false;
}

// --- Java interop: the Share log button --------------------------------

void umbra_share_log(umbra_app *app) {
    JNIEnv *env = NULL;
    struct android_app *state = g_st.state;
    if (!state || !state->activity) return;
    JavaVM *vm = state->activity->vm;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        if ((*vm)->AttachCurrentThread(vm, &env, NULL) != JNI_OK) {
            ALOGE("share log: cannot attach thread");
            return;
        }
    }
    // Read the log into memory (truncated to what an Intent extra can carry).
    char *text = (char *)calloc(1, 64000);
    FILE *f = fopen(app->log_path, "rb");
    size_t n = 0;
    if (f && text) {
        n = fread(text, 1, 63000, f);
        fclose(f);
    }
    if (!text) return;
    text[n] = 0;

    jobject activity = state->activity->clazz;
    jclass activity_class = (*env)->GetObjectClass(env, activity);
    jclass intent_class = (*env)->FindClass(env, "android/content/Intent");
    jmethodID intent_ctor = (*env)->GetMethodID(env, intent_class, "<init>", "(Ljava/lang/String;)V");
    jstring action = (*env)->NewStringUTF(env, "android.intent.action.SEND");
    jobject intent = (*env)->NewObject(env, intent_class, intent_ctor, action);
    jmethodID put_extra = (*env)->GetMethodID(env, intent_class, "putExtra",
                                              "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;");
    jstring key = (*env)->NewStringUTF(env, "android.intent.extra.TEXT");
    jstring value = (*env)->NewStringUTF(env, text);
    (*env)->CallObjectMethod(env, intent, put_extra, key, value);
    jmethodID set_type = (*env)->GetMethodID(env, intent_class, "setType",
                                             "(Ljava/lang/String;)Landroid/content/Intent;");
    jstring mime = (*env)->NewStringUTF(env, "text/plain");
    (*env)->CallObjectMethod(env, intent, set_type, mime);
    jmethodID chooser_title_cls = (*env)->FindClass(env, "android/content/Intent");
    (void)chooser_title_cls;
    jclass intent_cls = (*env)->FindClass(env, "android/content/Intent");
    jmethodID create_chooser = (*env)->GetStaticMethodID(
        env, intent_cls, "createChooser",
        "(Landroid/content/Intent;Ljava/lang/CharSequence;)Landroid/content/Intent;");
    jstring title = (*env)->NewStringUTF(env, "Umbra log");
    jobject chooser = (*env)->CallStaticObjectMethod(env, intent_cls, create_chooser, intent, title);
    jmethodID start_activity = (*env)->GetMethodID(env, activity_class, "startActivity",
                                                   "(Landroid/content/Intent;)V");
    if (start_activity) {
        (*env)->CallVoidMethod(env, activity, start_activity, chooser);
        umbra_log(app, "share log: intent sent (%zu bytes)", n);
    } else {
        umbra_log(app, "share log: NativeActivity has no startActivity");
    }
    free(text);
}

// --- input and lifecycle -----------------------------------------------

static int32_t handle_input(struct android_app *state, AInputEvent *event) {
    if (AInputEvent_getType(event) == AINPUT_EVENT_TYPE_MOTION) {
        int32_t action = AMotionEvent_getAction(event) & AMOTION_EVENT_ACTION_MASK;
        if (action == AMOTION_EVENT_ACTION_DOWN) {
            float x = AMotionEvent_getX(event, 0);
            float y = AMotionEvent_getY(event, 0);
            umbra_app_touch(&g_st.app, (int32_t)x, (int32_t)y, true);
            return 1;
        }
    }
    (void)state;
    return 0;
}

static void handle_cmd(struct android_app *state, int32_t cmd) {
    android_state *st = (android_state *)state->userData;
    switch (cmd) {
        case APP_CMD_INIT_WINDOW:
            if (state->window && !st->egl_ready) {
                init_egl(st);
            }
            break;
        case APP_CMD_TERM_WINDOW:
            destroy_egl(st);
            break;
        case APP_CMD_WINDOW_RESIZED:
        case APP_CMD_CONFIG_CHANGED:
            if (st->egl_ready) {
                EGLint w = 0, h = 0;
                eglQuerySurface(st->display, st->surface, EGL_WIDTH, &w);
                eglQuerySurface(st->display, st->surface, EGL_HEIGHT, &h);
                st->width = w;
                st->height = h;
            }
            break;
        case APP_CMD_LOW_MEMORY:
            ALOGI("low memory");
            break;
        default:
            break;
    }
}

void android_main(struct android_app *state) {
    memset(&g_st, 0, sizeof g_st);
    g_st.state = state;
    state->userData = &g_st;
    state->onAppCmd = handle_cmd;
    state->onInputEvent = handle_input;
    snprintf(g_st.files_dir, sizeof g_st.files_dir, "%s", state->activity->internalDataPath);
    snprintf(g_st.app.log_path, sizeof g_st.app.log_path, "%s/umbra.log", g_st.files_dir);
    snprintf(g_st.app.marker_path, sizeof g_st.app.marker_path, "%s/session.marker", g_st.files_dir);
    ALOGI("android_main: files %s", g_st.files_dir);

    bool started = false;
    while (!state->destroyRequested) {
        int events;
        struct android_app *source;
        // Poll for events; android_app_glue dispatches them to handle_cmd and
        // handle_input. No timeout keeps this a tight frame loop.
        int timeout = 0;
        while (ALooper_pollOnce(timeout, NULL, &events, (void **)&source) >= 0) {
            timeout = 0;
        }
        if (!g_st.egl_ready) continue;
        if (!started) {
            g_st.app.width = g_st.width;
            g_st.app.height = g_st.height;
            if (!umbra_app_init(&g_st.app)) {
                ALOGE("app init failed");
                return;
            }
            g_st.app_ready = true;
            started = true;
        }
        g_st.app.width = g_st.width;
        g_st.app.height = g_st.height;
        umbra_app_frame(&g_st.app);
        eglSwapBuffers(g_st.display, g_st.surface);
    }
    if (started) umbra_app_shutdown(&g_st.app);
}
