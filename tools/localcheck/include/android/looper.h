// Stub of <android/looper.h>: only what android_main.c asks for.
#ifndef UMBRA_STUB_ANDROID_LOOPER_H
#define UMBRA_STUB_ANDROID_LOOPER_H
#include <stdint.h>
typedef struct ALooper ALooper;
typedef struct AInputQueue AInputQueue;
typedef int (*ALooper_callbackFunc)(int fd, int events, void *data);
enum { ALOOPER_POLL_WAKE = -1, ALOOPER_POLL_CALLBACK = -2, ALOOPER_POLL_TIMEOUT = -3, ALOOPER_POLL_ERROR = -4 };
enum { ALOOPER_EVENT_INPUT = 1 << 0 };
ALooper *ALooper_forThread(void);
int32_t ALooper_pollOnce(int timeoutMillis, int *outFd, int *outEvents, void **outData);
void ALooper_wake(ALooper *looper);
AInputQueue *ALooper_pollInput(void);
#endif
