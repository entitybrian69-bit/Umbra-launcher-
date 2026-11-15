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
#include "umbra_core.h"

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

// --- system insets and density -----------------------------------------
//
// The app draws edge to edge, which since Android 15 is not a choice, so the
// HUD has to stay inside the status bar, the navigation bar and the cutout. The
// NDK exposes none of that: the values come from the framework through JNI.
// WindowInsets.getSystemWindowInset* is deprecated but still implemented on
// every API level this app supports (24 and up), and it is the only variant that
// exists on all of them, so it is what is used. Failures are not fatal: zero
// insets means the HUD moves under the bars, which is bad but not a crash.
static JNIEnv *activity_env(android_state *st) {
    if (!st->state || !st->state->activity || !st->state->activity->vm) return NULL;
    JavaVM *vm = st->state->activity->vm;
    JNIEnv *env = NULL;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        if ((*vm)->AttachCurrentThread(vm, &env, NULL) != JNI_OK) return NULL;
    }
    return env;
}

static void fill_insets(android_state *st) {
    umbra_app *app = &st->app;
    for (int i = 0; i < 4; i++) app->insets[i] = 0;
    // Density: the configuration carries the bucket, and the HUD's text is
    // scaled by it so a 6-inch phone and a 4-inch phone look alike.
    int dpi = 0;
    if (st->state && st->state->config) {
        dpi = AConfiguration_getDensity(st->state->config);
    }
    if (dpi <= 0) dpi = 320;
    app->dpi_scale = (float)dpi / 160.0f;

    JNIEnv *env = activity_env(st);
    if (!env) { ALOGI("insets: no JNI environment, using zero"); return; }
    jobject activity = st->state->activity->clazz;
    jclass cls = (*env)->GetObjectClass(env, activity);
    if (!cls) return;

    jmethodID getWindow = (*env)->GetMethodID(env, cls, "getWindow", "()Landroid/view/Window;");
    if (!getWindow) { ALOGI("insets: no getWindow"); return; }
    jobject window = (*env)->CallObjectMethod(env, activity, getWindow);
    if (!window) { ALOGI("insets: no window"); return; }
    jclass window_cls = (*env)->GetObjectClass(env, window);
    jmethodID getDecorView = (*env)->GetMethodID(env, window_cls, "getDecorView", "()Landroid/view/View;");
    if (!getDecorView) return;
    jobject decor = (*env)->CallObjectMethod(env, window, getDecorView);
    if (!decor) return;
    jclass view_cls = (*env)->GetObjectClass(env, decor);
    jmethodID getRootWindowInsets = (*env)->GetMethodID(env, view_cls, "getRootWindowInsets",
                                                        "()Landroid/view/WindowInsets;");
    if (!getRootWindowInsets) {
        ALOGI("insets: getRootWindowInsets missing (API < 23?)");
        return;
    }
    jobject insets = (*env)->CallObjectMethod(env, decor, getRootWindowInsets);
    if (!insets) { ALOGI("insets: the decor view has no insets yet"); return; }
    jclass insets_cls = (*env)->GetObjectClass(env, insets);
    struct { const char *name; int slot; } fields[4] = {
        {"getSystemWindowInsetLeft", 0}, {"getSystemWindowInsetTop", 1},
        {"getSystemWindowInsetRight", 2}, {"getSystemWindowInsetBottom", 3},
    };
    for (int i = 0; i < 4; i++) {
        jmethodID m = (*env)->GetMethodID(env, insets_cls, fields[i].name, "()I");
        if (!m) continue;
        app->insets[fields[i].slot] = (*env)->CallIntMethod(env, insets, m);
    }
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        ALOGE("insets: a JNI call threw; insets may be wrong");
    }
    ALOGI("insets: %d,%d,%d,%d on %dx%d, density bucket %d (scale %.2f)",
          app->insets[0], app->insets[1], app->insets[2], app->insets[3],
          app->width, app->height, dpi, app->dpi_scale);
}

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
    // Every lifecycle command is logged: when the window never arrives, the
    // log says which commands did, which is the difference between "the
    // framework never created a surface" and "we ignored it".
    ALOGI("app cmd %d, window %p", cmd, (void *)state->window);
    switch (cmd) {
        case APP_CMD_INIT_WINDOW:
            if (state->window && !st->egl_ready) {
                init_egl(st);
            }
            break;
        case APP_CMD_TERM_WINDOW:
            destroy_egl(st);
            // The GL objects died with the context; the app is rebuilt from
            // umbra_app_init() when a window comes back.
            st->pending_restart = 1;
            break;
        case APP_CMD_WINDOW_RESIZED:
        case APP_CMD_CONFIG_CHANGED:
            // Rotation, a fold, the bars appearing or a different density all
            // land here; the HUD has to be re-laid out with the new insets.
            fill_insets(st);
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

    // The Goose runtime must be initialised before any exported umbra_*
    // function is called: the generated exports panic otherwise, and a panic
    // in the frame loop kills the process a few milliseconds after start.
    static char *goose_argv[] = {(char *)"umbra", NULL};
    goose_init(1, goose_argv);
    ALOGI("goose core initialised");

    bool started = false;
    bool announced_wait = false;
    while (!state->destroyRequested) {
        int events;
        struct android_poll_source *source = NULL;
        // android_app_glue hands out poll sources rather than callbacks: the
        // loop has to call source->process() itself, which is what turns a
        // readable command pipe into handle_cmd()/handle_input(). Without that
        // call no command ever arrives and the app never sees a window.
        // With a window the loop polls without waiting so it stays a tight
        // frame loop; without one there is nothing to draw, so it blocks
        // instead of spinning a core (a paused game must not burn the battery).
        int timeout = g_st.egl_ready ? 0 : -1;
        int ident;
        while ((ident = ALooper_pollOnce(timeout, NULL, &events, (void **)&source)) >= 0) {
            if (source != NULL) {
                source->process(state, source);
                source = NULL;
            }
            timeout = 0;
        }
        if (!g_st.egl_ready) {
            if (!announced_wait) {
                ALOGI("no window yet: waiting for the activity to become visible");
                announced_wait = true;
            }
            continue;
        }
        announced_wait = false;
        if (started && g_st.pending_restart) {
            umbra_app_shutdown(&g_st.app);
            started = false;
            g_st.app_ready = false;
            g_st.pending_restart = 0;
        }
        if (!started) {
            g_st.app.width = g_st.width;
            g_st.app.height = g_st.height;
            fill_insets(&g_st);
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
