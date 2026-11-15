// Minimal stub of the NDK's android/log.h, for compile-checking the shared C on a
// machine without the NDK. Only the macro the app uses is provided.
#pragma once
#define ANDROID_LOG_INFO 4
#define ANDROID_LOG_WARN 5
#define ANDROID_LOG_ERROR 6
int __android_log_print(int prio, const char *tag, const char *fmt, ...);
