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
#define ALOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)

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

// System property override, for testing on a device or emulator that has no
// status bar of its own: `adb shell setprop debug.umbra.insets "0,63,126,0"`.
// The emulator reports a top inset of zero, so CI could not otherwise exercise
// the case that broke the owner's first run.
#define UMBRA_PROP_VALUE_MAX 92   // PROP_VALUE_MAX from <sys/system_properties.h>
extern int __system_property_get(const char *name, char *value);

static void parse_override(int32_t insets[4], int *found) {
    char value[UMBRA_PROP_VALUE_MAX];
    *found = 0;
    if (__system_property_get("debug.umbra.insets", value) <= 0) return;
    int l = 0, t = 0, r = 0, b = 0;
    if (sscanf(value, "%d,%d,%d,%d", &l, &t, &r, &b) != 4) {
        ALOGE("insets: debug.umbra.insets is not \"l,t,r,b\": %s", value);
        return;
    }
    insets[0] = l;
    insets[1] = t;
    insets[2] = r;
    insets[3] = b;
    *found = 1;
}

// A failed JNI lookup leaves a pending exception, and the next JNI call with one
// pending aborts the process -- which is exactly what the emulator run of 0.3.1
// did ("Throwing new exception ... with unexpected pending exception"). Every
// lookup clears what it caused, so a missing method costs a wrong inset, never
// the app.
static void jni_clear(JNIEnv *env, const char *what) {
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        ALOGW("insets: %s is not available on this device", what);
    }
}

static int jint_call(JNIEnv *env, jobject obj, jclass cls, const char *name, const char *sig, int *out) {
    jmethodID m = (*env)->GetMethodID(env, cls, name, sig);
    if (!m) {
        jni_clear(env, name);
        return 0;
    }
    *out = (int)(*env)->CallIntMethod(env, obj, m);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        return 0;
    }
    return 1;
}

// android.graphics.Insets has public int fields and no getters: the first
// version of this called getLeft() and friends, which do not exist.
static int insets_field(JNIEnv *env, jobject obj, jclass cls, const char *name, int *out) {
    jfieldID f = (*env)->GetFieldID(env, cls, name, "I");
    if (!f) {
        jni_clear(env, name);
        return 0;
    }
    *out = (int)(*env)->GetIntField(env, obj, f);
    return 1;
}

// The five ways Android has reported insets, in order of preference:
//   getInsets(systemBars|displayCutout)  API 30+, knows about cutouts and
//                                        returns the bar sizes even when the
//                                        app is drawn edge-to-edge (which is
//                                        what the owner's phone does -- the
//                                        legacy call reports 0 there);
//   getSystemWindowInset*                API 20-29, or a device where the modern
//                                        call returns nothing;
//   getDisplayCutout().getSafeInset*     API 28+, a notch or a punch-hole;
//   the window's own content inset       last resort.
// The largest value wins, because every one of them is a lower bound on what the
// app must keep clear of.
static void fill_insets(android_state *st) {
    umbra_app *app = &st->app;
    int32_t insets[4] = {0, 0, 0, 0};
    int cutout[4] = {0, 0, 0, 0};
    int legacy[4] = {0, 0, 0, 0};
    int modern[4] = {0, 0, 0, 0};
    const char *source = "none";

    // Density: the configuration carries the bucket, and the HUD's text is
    // scaled by it so a 6-inch phone and a 4-inch phone look alike.
    int dpi = 0;
    if (st->state && st->state->config) {
        dpi = AConfiguration_getDensity(st->state->config);
    }
    if (dpi <= 0) dpi = 320;
    app->dpi_scale = (float)dpi / 160.0f;

    JNIEnv *env = activity_env(st);
    jobject insets_obj = NULL;
    jclass insets_cls = NULL;
    if (env) {
        jobject activity = st->state->activity->clazz;
        jclass cls = (*env)->GetObjectClass(env, activity);
        jmethodID getWindow = cls ? (*env)->GetMethodID(env, cls, "getWindow", "()Landroid/view/Window;") : NULL;
        jobject window = getWindow ? (*env)->CallObjectMethod(env, activity, getWindow) : NULL;
        jclass window_cls = window ? (*env)->GetObjectClass(env, window) : NULL;
        jmethodID getDecorView = window_cls ? (*env)->GetMethodID(env, window_cls, "getDecorView", "()Landroid/view/View;") : NULL;
        jobject decor = getDecorView ? (*env)->CallObjectMethod(env, window, getDecorView) : NULL;
        jclass view_cls = decor ? (*env)->GetObjectClass(env, decor) : NULL;
        jmethodID getRootWindowInsets =
            view_cls ? (*env)->GetMethodID(env, view_cls, "getRootWindowInsets", "()Landroid/view/WindowInsets;") : NULL;
        insets_obj = getRootWindowInsets ? (*env)->CallObjectMethod(env, decor, getRootWindowInsets) : NULL;
        insets_cls = insets_obj ? (*env)->GetObjectClass(env, insets_obj) : NULL;
    }
    if (!insets_obj) {
        ALOGI("insets: the decor view has no insets yet");
    } else {
        // API 30: WindowInsets.getInsets(int) with systemBars(7) | displayCutout(128).
        jmethodID getInsets = (*env)->GetMethodID(env, insets_cls, "getInsets", "(I)Landroid/graphics/Insets;");
        if (getInsets) {
            jobject iobj = (*env)->CallObjectMethod(env, insets_obj, getInsets, (jint)(7 | 128));
            if ((*env)->ExceptionCheck(env)) {
                (*env)->ExceptionClear(env);
                iobj = NULL;
            }
            if (iobj) {
                jclass icls = (*env)->GetObjectClass(env, iobj);
                int ok = insets_field(env, iobj, icls, "left", &modern[0]);
                ok &= insets_field(env, iobj, icls, "top", &modern[1]);
                ok &= insets_field(env, iobj, icls, "right", &modern[2]);
                ok &= insets_field(env, iobj, icls, "bottom", &modern[3]);
                if (ok) source = "getInsets(systemBars|cutout)";
                (*env)->DeleteLocalRef(env, icls);
                (*env)->DeleteLocalRef(env, iobj);
            } else {
                ALOGW("insets: getInsets(int) returned nothing");
            }
        }
        // Legacy: what the emulator answered with, and what returns 0 when the
        // window is laid out edge-to-edge.
        const char *names[4] = {"getSystemWindowInsetLeft", "getSystemWindowInsetTop",
                                "getSystemWindowInsetRight", "getSystemWindowInsetBottom"};
        int legacy_ok = 0;
        for (int i = 0; i < 4; i++) {
            legacy_ok |= jint_call(env, insets_obj, insets_cls, names[i], "()I", &legacy[i]);
        }
        if (legacy_ok && source[0] == 'n') source = "getSystemWindowInset";
        // API 28: the notch, which is not a "system window" at all.
        jmethodID getCutout = (*env)->GetMethodID(env, insets_cls, "getDisplayCutout",
                                                  "()Landroid/view/DisplayCutout;");
        if (!getCutout) jni_clear(env, "getDisplayCutout");
        jobject cut = getCutout ? (*env)->CallObjectMethod(env, insets_obj, getCutout) : NULL;
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
            cut = NULL;
        }
        if (cut) {
            jclass ccls = (*env)->GetObjectClass(env, cut);
            int ok = jint_call(env, cut, ccls, "getSafeInsetLeft", "()I", &cutout[0]);
            ok &= jint_call(env, cut, ccls, "getSafeInsetTop", "()I", &cutout[1]);
            ok &= jint_call(env, cut, ccls, "getSafeInsetRight", "()I", &cutout[2]);
            ok &= jint_call(env, cut, ccls, "getSafeInsetBottom", "()I", &cutout[3]);
            if (ok) source = "getInsets + displayCutout";
            (*env)->DeleteLocalRef(env, ccls);
            (*env)->DeleteLocalRef(env, cut);
        }
    }

    for (int i = 0; i < 4; i++) {
        int v = modern[i] > legacy[i] ? modern[i] : legacy[i];
        if (cutout[i] > v) v = cutout[i];
        insets[i] = v;
    }
    int overridden = 0;
    parse_override(insets, &overridden);
    if (overridden) source = "debug.umbra.insets override";

    for (int i = 0; i < 4; i++) app->insets[i] = insets[i];
    ALOGI("insets: L,T,R,B = %d,%d,%d,%d (modern %d,%d,%d,%d, legacy %d,%d,%d,%d, cutout %d,%d,%d,%d, "
          "source %s) on %dx%d, density bucket %d (scale %.2f)",
          insets[0], insets[1], insets[2], insets[3],
          modern[0], modern[1], modern[2], modern[3],
          legacy[0], legacy[1], legacy[2], legacy[3],
          cutout[0], cutout[1], cutout[2], cutout[3],
          source, app->width, app->height, dpi, app->dpi_scale);
}

// The benchmark's request for an uncapped swap interval. eglSwapInterval returns
// EGL_TRUE when EGL accepted it, which on Android says nothing about the
// compositor: the platform still throttles to the display's refresh rate in many
// configurations. The app logs what it got and reports the frame rate as capped
// unless it can prove otherwise.
static int android_swap_interval(void *ctx, int interval) {
    android_state *st = (android_state *)ctx;
    if (!st || !st->display || st->display == EGL_NO_DISPLAY ||
        !st->surface || st->surface == EGL_NO_SURFACE) {
        return 0;
    }
    EGLBoolean ok = eglSwapInterval(st->display, interval);
    ALOGI("swap interval %d: %s", interval, ok ? "accepted by EGL" : "refused by EGL");
    return ok ? 1 : 0;
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


// --- the "get game files" hooks ----------------------------------------
//
// The app's screen asks for the jar; these three functions are how the platform
// answers. TLS is Java's (the NDK has no TLS client) and the file picker is an
// activity result, which android.app.NativeActivity cannot receive -- so both live
// in org.umbra.client.UmbraNet, and the app's activity is UmbraNet$UmbraActivity
// (see AndroidManifest.xml).
//
// The class is looked up once, in JNI_OnLoad, while a class loader that knows the
// app's own classes is on the stack. FindClass from a worker thread would look in
// the system loader and fail, which is a mistake worth not making twice.
static JavaVM *g_vm = NULL;
static jclass g_umbra_net = NULL;
static jmethodID g_m_download = NULL;
static jmethodID g_m_pick = NULL;
static jmethodID g_m_got = NULL;
static jmethodID g_m_total = NULL;
static jmethodID g_m_error = NULL;

// Set once the Java class is reachable from a thread that can see the app's own
// classes. Not set by JNI_OnLoad: android.app.NativeActivity dlopens the library
// itself with dlopen(), which does not call JNI_OnLoad at all, so on the device
// that constructor never ran, every hook found g_umbra_net null, and the game-files
// screen's download said "no Java network class in this APK" (run 43951429395).
// The lookup therefore happens from android_main, on the thread the activity
// started us on, where FindClass resolves against the app's class loader.
static int g_net_ready = 0;

static void net_init(ANativeActivity *activity) {
    if (g_net_ready) return;
    if (!g_vm && activity) g_vm = activity->vm;
    if (!g_vm) {
        ALOGE("net: no JavaVM from the activity: the game-files screen cannot download");
        return;
    }
    JNIEnv *env = NULL;
    int attached = 0;
    if ((*g_vm)->GetEnv(g_vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        if ((*g_vm)->AttachCurrentThread(g_vm, &env, NULL) != JNI_OK) {
            ALOGE("net: this thread could not attach to the JVM");
            return;
        }
        attached = 1;
    }
    // FindClass is not enough: on a thread that was attached from native code it
    // searches the *system* class loader, which cannot see the app's own classes,
    // so it answered "not in this APK" on a device whose dex has the class in it
    // (run 43953686713). The activity's own class loader is the one that knows
    // this app, and asking it by name is what makes the lookup work on the thread
    // android_main runs on.
    jclass local = NULL;
    if (activity && activity->clazz) {
        jclass activity_class = (*env)->GetObjectClass(env, activity->clazz);
        if (activity_class) {
            jmethodID get_loader = (*env)->GetMethodID(env, activity_class, "getClassLoader",
                                                       "()Ljava/lang/ClassLoader;");
            if (get_loader) {
                jobject loader = (*env)->CallObjectMethod(env, activity->clazz, get_loader);
                if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); loader = NULL; }
                if (loader) {
                    jclass loader_class = (*env)->FindClass(env, "java/lang/ClassLoader");
                    if (loader_class) {
                        jmethodID load_class = (*env)->GetMethodID(env, loader_class, "loadClass",
                                                                   "(Ljava/lang/String;)Ljava/lang/Class;");
                        if (load_class) {
                            jstring name = (*env)->NewStringUTF(env, "org.umbra.client.UmbraNet");
                            local = (jclass)(*env)->CallObjectMethod(env, loader, load_class, name);
                            if ((*env)->ExceptionCheck(env)) {
                                (*env)->ExceptionClear(env);
                                local = NULL;
                            }
                            (*env)->DeleteLocalRef(env, name);
                        }
                    }
                    (*env)->DeleteLocalRef(env, loader);
                }
            }
            (*env)->DeleteLocalRef(env, activity_class);
        }
    }
    if (!local) {
        // The activity's loader could not answer; try the plain lookup anyway, so
        // the log distinguishes "no class loader" from "no class".
        local = (*env)->FindClass(env, "org/umbra/client/UmbraNet");
    }
    if (!local) {
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
        ALOGE("net: org.umbra.client.UmbraNet is not in this APK: "
              "the game-files screen cannot download or import");
        if (attached) (*g_vm)->DetachCurrentThread(g_vm);
        return;
    }
    g_umbra_net = (jclass)(*env)->NewGlobalRef(env, local);
    g_m_download = (*env)->GetStaticMethodID(env, g_umbra_net, "download",
                                             "(Ljava/lang/String;Ljava/lang/String;)J");
    g_m_pick = (*env)->GetStaticMethodID(env, g_umbra_net, "pickAndCopy",
                                         "(Landroid/app/Activity;Ljava/lang/String;[Ljava/lang/String;)J");
    g_m_got = (*env)->GetStaticMethodID(env, g_umbra_net, "progressGot", "()J");
    g_m_total = (*env)->GetStaticMethodID(env, g_umbra_net, "progressTotal", "()J");
    g_m_error = (*env)->GetStaticMethodID(env, g_umbra_net, "lastError", "()Ljava/lang/String;");
    if (!g_m_download || !g_m_pick || !g_m_got || !g_m_total || !g_m_error) {
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
        // Named one by one: "missing a method" sent this run looking at the dex
        // when the fault was a single wrong signature in the table below.
        ALOGE("net: UmbraNet is missing a method: download %s, pickAndCopy %s, "
              "progressGot %s, progressTotal %s, lastError %s",
              g_m_download ? "ok" : "MISSING", g_m_pick ? "ok" : "MISSING",
              g_m_got ? "ok" : "MISSING", g_m_total ? "ok" : "MISSING",
              g_m_error ? "ok" : "MISSING");
        g_umbra_net = NULL;
        if (attached) (*g_vm)->DetachCurrentThread(g_vm);
        return;
    }
    g_net_ready = 1;
    ALOGI("net: UmbraNet loaded: download and the file picker are available");
    if (attached) (*g_vm)->DetachCurrentThread(g_vm);
}

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    // Only the JavaVM is remembered here. The class and its methods are looked up
    // in net_init(), from android_main: android.app.NativeActivity dlopens this
    // library, so JNI_OnLoad is not called on the device at all, and a lookup table
    // that exists in two places can disagree with itself (it did: this copy kept
    // the old pickAndCopy signature for a run).
    if (vm) g_vm = vm;
    return JNI_VERSION_1_6;
}

static JNIEnv *net_env(void) {
    if (!g_vm) return NULL;
    JNIEnv *env = NULL;
    if ((*g_vm)->GetEnv(g_vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        if ((*g_vm)->AttachCurrentThread(g_vm, &env, NULL) != JNI_OK) return NULL;
    }
    return env;
}

static jstring net_string(JNIEnv *env, const char *s) {
    return (*env)->NewStringUTF(env, s ? s : "");
}

static void net_throw_away(JNIEnv *env) {
    if ((*env)->ExceptionCheck(env)) {
        // An exception left pending would abort the next call; the message is kept
        // for the screen instead of the process being killed for it.
        (*env)->ExceptionClear(env);
    }
}

// Copies the Java-side error message into the app's buffer.
static void net_record_error(umbra_app *app) {
    JNIEnv *env = net_env();
    if (!env || !g_umbra_net || !g_m_error) return;
    jstring s = (jstring)(*env)->CallStaticObjectMethod(env, g_umbra_net, g_m_error);
    if ((*env)->ExceptionCheck(env)) { net_throw_away(env); return; }
    if (!s) return;
    const char *utf = (*env)->GetStringUTFChars(env, s, NULL);
    if (utf) {
        snprintf(app->gf_platform_error, sizeof app->gf_platform_error, "%s", utf);
        (*env)->ReleaseStringUTFChars(env, s, utf);
    }
    (*env)->DeleteLocalRef(env, s);
}

// The download: URL in, a file on disk out, and the byte count. Runs on the worker
// thread the app's game-files job started.
static int android_download(void *ctx, const char *url, const char *dest, long long *got) {
    android_state *st = (android_state *)ctx;
    umbra_app *app = st ? &st->app : NULL;
    JNIEnv *env = net_env();
    if (!env || !g_umbra_net || !g_m_download) {
        if (app) snprintf(app->gf_platform_error, sizeof app->gf_platform_error,
                          "no Java network class in this APK");
        return -1;
    }
    jstring jurl = net_string(env, url);
    jstring jdest = net_string(env, dest);
    jlong n = (*env)->CallStaticLongMethod(env, g_umbra_net, g_m_download, jurl, jdest);
    int failed = 0;
    if ((*env)->ExceptionCheck(env)) { net_throw_away(env); failed = 1; }
    (*env)->DeleteLocalRef(env, jurl);
    (*env)->DeleteLocalRef(env, jdest);
    if (got) *got = (long long)n;
    ALOGI("download: %s -> %s: %lld bytes%s", url, dest, (long long)n, failed ? " (threw)" : "");
    if (n <= 0 && app) net_record_error(app);
    return (n > 0) ? 0 : -1;
}

// The picker: the activity shows ACTION_OPEN_DOCUMENT, the worker waits for the
// result, and the chosen stream is copied to `dest`.
static int android_pick_file(void *ctx, const char *dest, const char *mime, long long *got) {
    android_state *st = (android_state *)ctx;
    umbra_app *app = st ? &st->app : NULL;
    JNIEnv *env = net_env();
    if (!env || !g_umbra_net || !g_m_pick || !st || !st->state || !st->state->activity) {
        if (app) snprintf(app->gf_platform_error, sizeof app->gf_platform_error,
                          "no file picker in this build");
        return -1;
    }
    jobject activity = st->state->activity->clazz;
    jstring jdest = net_string(env, dest);
    jstring jmime = net_string(env, mime ? mime : "*/*");
    // pickAndCopy takes String[] for the MIME types (one file picker, several kinds
    // of file), and the signature above said String: GetStaticMethodID found
    // nothing, which cost the whole bridge on run 43956343069 -- "UmbraNet is
    // missing a method the app calls" -- and read like a missing class instead.
    jclass string_class = (*env)->FindClass(env, "java/lang/String");
    jobject jmimes = string_class
        ? (*env)->NewObjectArray(env, 1, string_class, jmime) : NULL;
    jlong n = (*env)->CallStaticLongMethod(env, g_umbra_net, g_m_pick, activity, jdest,
                                           jmimes ? jmimes : jmime);
    int failed = 0;
    if ((*env)->ExceptionCheck(env)) { net_throw_away(env); failed = 1; }
    (*env)->DeleteLocalRef(env, jdest);
    (*env)->DeleteLocalRef(env, jmime);
    if (jmimes) (*env)->DeleteLocalRef(env, jmimes);
    if (got) *got = (long long)n;
    ALOGI("pick: -> %s: %lld bytes%s", dest, (long long)n, failed ? " (threw)" : "");
    if (n <= 0 && app) net_record_error(app);
    return (n > 0) ? 0 : -1;
}

// The world picker: the same document picker, filtered to the two MIME types a zip of a
// save arrives as. Android reports a zip as application/zip from some providers and
// application/octet-stream from others, and a picker filtered to neither shows a list
// with every world greyed out -- which reads as "Umbra cannot open saves".
static int android_pick_world(void *ctx, const char *dest, long long *got) {
    android_state *st = (android_state *)ctx;
    umbra_app *app = st ? &st->app : NULL;
    JNIEnv *env = net_env();
    if (!env || !g_umbra_net || !g_m_pick || !st || !st->state || !st->state->activity) {
        if (app) snprintf(app->gf_platform_error, sizeof app->gf_platform_error,
                          "no file picker in this build");
        return -1;
    }
    jobject activity = st->state->activity->clazz;
    jstring jdest = net_string(env, dest);
    jstring mime_zip = net_string(env, "application/zip");
    jstring mime_bin = net_string(env, "application/octet-stream");
    jclass string_class = (*env)->FindClass(env, "java/lang/String");
    jobject jmimes = string_class ? (*env)->NewObjectArray(env, 2, string_class, mime_zip) : NULL;
    if (jmimes && mime_bin) (*env)->SetObjectArrayElement(env, jmimes, 1, mime_bin);
    jlong n = (*env)->CallStaticLongMethod(env, g_umbra_net, g_m_pick, activity, jdest,
                                           jmimes ? jmimes : jdest);
    int failed = 0;
    if ((*env)->ExceptionCheck(env)) { net_throw_away(env); failed = 1; }
    (*env)->DeleteLocalRef(env, jdest);
    (*env)->DeleteLocalRef(env, mime_zip);
    (*env)->DeleteLocalRef(env, mime_bin);
    if (jmimes) (*env)->DeleteLocalRef(env, jmimes);
    if (got) *got = (long long)n;
    ALOGI("pick world: -> %s: %lld bytes%s", dest, (long long)n, failed ? " (threw)" : "");
    if (n <= 0 && app) net_record_error(app);
    return (n > 0) ? 0 : -1;
}

static void android_progress(void *ctx, long long *got, long long *total) {
    (void)ctx;
    JNIEnv *env = net_env();
    if (!env || !g_umbra_net || !g_m_got || !g_m_total) return;
    jlong g = (*env)->CallStaticLongMethod(env, g_umbra_net, g_m_got);
    if ((*env)->ExceptionCheck(env)) { net_throw_away(env); return; }
    jlong t = (*env)->CallStaticLongMethod(env, g_umbra_net, g_m_total);
    if ((*env)->ExceptionCheck(env)) { net_throw_away(env); return; }
    if (got) *got = (long long)g;
    if (total) *total = (long long)t;
}

// --- input and lifecycle -----------------------------------------------

static int32_t handle_input(struct android_app *state, AInputEvent *event) {
    if (AInputEvent_getType(event) != AINPUT_EVENT_TYPE_MOTION) {
        (void)state;
        return 0;
    }
    int32_t action = AMotionEvent_getAction(event);
    int32_t masked = action & AMOTION_EVENT_ACTION_MASK;
    // Which pointer this event is about: the index for a move/up, and the pointer
    // id that just arrived or left for the pointer actions. Without this the app
    // cannot tell the finger that is looking from the finger that is walking.
    int32_t idx = (action & AMOTION_EVENT_ACTION_POINTER_INDEX_MASK) >>
                  AMOTION_EVENT_ACTION_POINTER_INDEX_SHIFT;
    size_t count = AMotionEvent_getPointerCount(event);
    if (masked == AMOTION_EVENT_ACTION_MOVE) {
        for (size_t i = 0; i < count; i++) {
            umbra_app_touch_id(&g_st.app, AMotionEvent_getPointerId(event, i),
                               (int32_t)AMotionEvent_getX(event, i),
                               (int32_t)AMotionEvent_getY(event, i), 1);
        }
        return 1;
    }
    if ((size_t)idx >= count) idx = 0;
    int32_t phase = 0;
    if (masked == AMOTION_EVENT_ACTION_UP || masked == AMOTION_EVENT_ACTION_POINTER_UP) phase = 2;
    else if (masked == AMOTION_EVENT_ACTION_CANCEL) phase = 3;
    umbra_app_touch_id(&g_st.app, AMotionEvent_getPointerId(event, idx),
                       (int32_t)AMotionEvent_getX(event, idx),
                       (int32_t)AMotionEvent_getY(event, idx), phase);
    return 1;
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
        case APP_CMD_PAUSE:
        case APP_CMD_STOP:
        case APP_CMD_DESTROY:
            // Home button, app switcher, a swipe away, or the system stopping us:
            // none of those is a crash, so the marker is set to clean and the next
            // start does not accuse the previous one.
            if (st->egl_ready) umbra_session_set(&st->app, "clean");
            break;
        case APP_CMD_RESUME:
        case APP_CMD_START:
            if (st->egl_ready) umbra_session_set(&st->app, "running");
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
    // The app's private directory: where the log, the marker, the results and the
    // client jar live. Nothing here is readable by another app, and uninstalling
    // Umbra removes the jar with it -- which is what keeps the game's files out of
    // anything the owner did not ask for.
    snprintf(g_st.files_dir, sizeof g_st.files_dir, "%s", state->activity->internalDataPath);
    snprintf(g_st.app.files_dir, sizeof g_st.app.files_dir, "%s", g_st.files_dir);
    snprintf(g_st.app.log_path, sizeof g_st.app.log_path, "%s/umbra.log", g_st.files_dir);
    snprintf(g_st.app.marker_path, sizeof g_st.app.marker_path, "%s/session.marker", g_st.files_dir);
    ALOGI("android_main: files %s", g_st.files_dir);

    // The Goose runtime must be initialised before any exported umbra_*
    // function is called: the generated exports panic otherwise, and a panic
    // in the frame loop kills the process a few milliseconds after start.
    static char *goose_argv[] = {(char *)"umbra", NULL};
    goose_init(1, goose_argv);
    ALOGI("goose core initialised");
    // Before anything can ask for the game's files: the Java bridge is looked up
    // here, not in JNI_OnLoad, which NativeActivity never calls (see net_init).
    net_init(state->activity);

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
            // Before init: umbra_app_init keeps these across its memset.
            g_st.app.swap_interval_fn = android_swap_interval;
            g_st.app.swap_interval_ctx = &g_st;
            // The game-files screen's hooks: a download, a file picker and the
            // progress of both. Without them the app says so on the screen rather
            // than pretending it can fetch a jar.
            g_st.app.download_fn = android_download;
            g_st.app.pick_file_fn = android_pick_file;
            g_st.app.pick_world_fn = android_pick_world;
            g_st.app.progress_fn = android_progress;
            g_st.app.net_ctx = &g_st;
            snprintf(g_st.app.files_dir, sizeof g_st.app.files_dir, "%s", g_st.files_dir);
            fill_insets(&g_st);
            if (!umbra_app_init(&g_st.app)) {
                ALOGE("app init failed");
                return;
            }
            g_st.app_ready = true;
            started = true;
        }
        // Ask the surface for its size every frame. On run 43687356640 the
        // surface came up at 1x1 and no resize event ever arrived, so the app
        // drew into a one-pixel viewport and the screenshot gate saw a blank
        // screen. eglQuerySurface is cheap and it cannot go stale.
        if (g_st.egl_ready) {
            EGLint w = 0, h = 0;
            eglQuerySurface(g_st.display, g_st.surface, EGL_WIDTH, &w);
            eglQuerySurface(g_st.display, g_st.surface, EGL_HEIGHT, &h);
            if (w != g_st.width || h != g_st.height) {
                ALOGI("surface is now %dx%d (was %dx%d)", w, h, g_st.width, g_st.height);
                g_st.width = w;
                g_st.height = h;
                g_st.app.width = w;
                g_st.app.height = h;
                fill_insets(&g_st);
            }
        }
        g_st.app.width = g_st.width;
        g_st.app.height = g_st.height;
        umbra_app_frame(&g_st.app);
        eglSwapBuffers(g_st.display, g_st.surface);
    }
    if (started) umbra_app_shutdown(&g_st.app);
}
