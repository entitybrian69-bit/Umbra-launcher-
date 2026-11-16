// A stub of the JDK's jni.h, holding only the calls platform/android uses. Enough
// to type-check the JNI inset lookups on a desktop; the real header comes from
// the NDK in the APK build.
#ifndef UMBRA_STUB_JNI_H
#define UMBRA_STUB_JNI_H
#include <stdint.h>
#include <stddef.h>

typedef int32_t jint;
typedef int64_t jlong;
typedef int8_t jboolean;
typedef int32_t jsize;
typedef void *jobject;
typedef void *jclass;
typedef void *jmethodID;
typedef void *jfieldID;
typedef void *jstring;
typedef void *jarray;
typedef struct _jobject *jref;

typedef union jvalue { jboolean z; int8_t b; uint16_t c; int16_t s; jint i; int64_t j; float f; double d; jobject l; } jvalue;

#define JNI_VERSION_1_6 0x00010006
#define JNIEXPORT
#define JNICALL
#define JNI_OK 0
#define JNI_ERR (-1)

struct JNINativeInterface;
typedef const struct JNINativeInterface *JNIEnv;

typedef struct JNINativeInterface {
    void *reserved0; void *reserved1; void *reserved2; void *reserved3;
    jint (*GetVersion)(JNIEnv *);
    jclass (*DefineClass)(JNIEnv *, const char *, jobject, const int8_t *, jsize);
    jclass (*FindClass)(JNIEnv *, const char *);
    jmethodID (*FromReflectedMethod)(JNIEnv *, jobject);
    jfieldID (*FromReflectedField)(JNIEnv *, jobject);
    jobject (*ToReflectedMethod)(JNIEnv *, jclass, jmethodID, jboolean);
    jclass (*GetSuperclass)(JNIEnv *, jclass);
    jboolean (*IsAssignableFrom)(JNIEnv *, jclass, jclass);
    jobject (*ToReflectedField)(JNIEnv *, jclass, jfieldID, jboolean);
    jint (*Throw)(JNIEnv *, jobject);
    jint (*ThrowNew)(JNIEnv *, jclass, const char *);
    jboolean (*ExceptionCheck)(JNIEnv *);
    jobject (*ExceptionOccurred_ref)(JNIEnv *);
    void (*ExceptionDescribe)(JNIEnv *);
    void (*ExceptionClear)(JNIEnv *);
    void (*FatalError)(JNIEnv *, const char *);
    void *reserved_pad[20];
    jint (*PushLocalFrame)(JNIEnv *, jint);
    jobject (*PopLocalFrame)(JNIEnv *, jobject);
    jobject (*NewGlobalRef)(JNIEnv *, jobject);
    void (*DeleteGlobalRef)(JNIEnv *, jobject);
    void (*DeleteLocalRef)(JNIEnv *, jobject);
    jboolean (*IsSameObject)(JNIEnv *, jobject, jobject);
    void *reserved_pad2[3];
    jobject (*NewObjectArray)(JNIEnv *, jsize, jclass, jobject);
    jobject (*GetObjectArrayElement)(JNIEnv *, jobject, jsize);
    void (*SetObjectArrayElement)(JNIEnv *, jobject, jsize, jobject);
    jobject (*AllocObject)(JNIEnv *, jclass);
    jobject (*NewObject)(JNIEnv *, jclass, jmethodID, ...);
    jobject (*NewObjectV)(JNIEnv *, jclass, jmethodID, void *);
    jobject (*NewObjectA)(JNIEnv *, jclass, jmethodID, const jvalue *);
    jclass (*GetObjectClass)(JNIEnv *, jobject);
    jboolean (*IsInstanceOf)(JNIEnv *, jobject, jclass);
    jmethodID (*GetMethodID)(JNIEnv *, jclass, const char *, const char *);
    jobject (*CallObjectMethod)(JNIEnv *, jobject, jmethodID, ...);
    jobject (*CallObjectMethodV)(JNIEnv *, jobject, jmethodID, void *);
    jobject (*CallObjectMethodA)(JNIEnv *, jobject, jmethodID, const jvalue *);
    jboolean (*CallBooleanMethod)(JNIEnv *, jobject, jmethodID, ...);
    int8_t (*CallByteMethod)(JNIEnv *, jobject, jmethodID, ...);
    uint16_t (*CallCharMethod)(JNIEnv *, jobject, jmethodID, ...);
    int16_t (*CallShortMethod)(JNIEnv *, jobject, jmethodID, ...);
    jint (*CallIntMethod)(JNIEnv *, jobject, jmethodID, ...);
    int64_t (*CallLongMethod)(JNIEnv *, jobject, jmethodID, ...);
    float (*CallFloatMethod)(JNIEnv *, jobject, jmethodID, ...);
    double (*CallDoubleMethod)(JNIEnv *, jobject, jmethodID, ...);
    void (*CallVoidMethod)(JNIEnv *, jobject, jmethodID, ...);
    jfieldID (*GetFieldID)(JNIEnv *, jclass, const char *, const char *);
    jobject (*GetObjectField)(JNIEnv *, jobject, jfieldID);
    jboolean (*GetBooleanField)(JNIEnv *, jobject, jfieldID);
    jint (*GetIntField)(JNIEnv *, jobject, jfieldID);
    int64_t (*GetLongField)(JNIEnv *, jobject, jfieldID);
    float (*GetFloatField)(JNIEnv *, jobject, jfieldID);
    void (*SetObjectField)(JNIEnv *, jobject, jfieldID, jobject);
    void (*SetIntField)(JNIEnv *, jobject, jfieldID, jint);
    jmethodID (*GetStaticMethodID)(JNIEnv *, jclass, const char *, const char *);
    jobject (*CallStaticObjectMethod)(JNIEnv *, jclass, jmethodID, ...);
    jint (*CallStaticIntMethod)(JNIEnv *, jclass, jmethodID, ...);
    jfieldID (*GetStaticFieldID)(JNIEnv *, jclass, const char *, const char *);
    jobject (*GetStaticObjectField)(JNIEnv *, jclass, jfieldID);
    jint (*GetStaticIntField)(JNIEnv *, jclass, jfieldID);
    jstring (*NewStringUTF)(JNIEnv *, const char *);
    jsize (*GetStringUTFLength)(JNIEnv *, jstring);
    const char *(*GetStringUTFChars)(JNIEnv *, jstring, jboolean *);
    void (*ReleaseStringUTFChars)(JNIEnv *, jstring, const char *);
    jlong (*CallStaticLongMethod)(JNIEnv *, jclass, jmethodID, ...);
    jsize (*GetArrayLength)(JNIEnv *, jarray);
} JNINativeInterface;

typedef struct JavaVMAttachArgs { jint version; const char *name; jobject group; } JavaVMAttachArgs;

typedef struct JavaVMOption { char *optionString; void *extraInfo; } JavaVMOption;

typedef struct JavaVMInitArgs { jint version; jint nOptions; JavaVMOption *options; jboolean ignoreUnrecognized; } JavaVMInitArgs;

struct JNIInvokeInterface;
typedef const struct JNIInvokeInterface *JavaVM;

struct JNIInvokeInterface {
    void *reserved0; void *reserved1; void *reserved2;
    jint (*DestroyJavaVM)(JavaVM *);
    jint (*AttachCurrentThread)(JavaVM *, JNIEnv **, void *);
    jint (*DetachCurrentThread)(JavaVM *);
    jint (*GetEnv)(JavaVM *, void **, jint);
    jint (*AttachCurrentThreadAsDaemon)(JavaVM *, JNIEnv **, void *);
};

#endif
