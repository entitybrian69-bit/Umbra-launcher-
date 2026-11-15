// Stub of <android/input.h>: only what android_main.c asks for.
#ifndef UMBRA_STUB_ANDROID_INPUT_H
#define UMBRA_STUB_ANDROID_INPUT_H
#include <stdint.h>
typedef struct AInputEvent AInputEvent;
enum { AINPUT_EVENT_TYPE_KEY = 1, AINPUT_EVENT_TYPE_MOTION = 2 };
enum { AKEY_EVENT_ACTION_DOWN = 0, AKEY_EVENT_ACTION_UP = 1 };
enum { AMOTION_EVENT_ACTION_DOWN = 0, AMOTION_EVENT_ACTION_UP = 1, AMOTION_EVENT_ACTION_MOVE = 2, AMOTION_EVENT_ACTION_MASK = 0xff };
enum { AINPUT_SOURCE_TOUCHSCREEN = 0x00001002 };
enum { AINPUT_SOURCE_CLASS_POINTER = 0x00000004 };
int32_t AInputEvent_getType(const AInputEvent *event);
int32_t AInputEvent_getSource(const AInputEvent *event);
int32_t AKeyEvent_getAction(const AInputEvent *event);
int32_t AKeyEvent_getKeyCode(const AInputEvent *event);
int32_t AMotionEvent_getAction(const AInputEvent *event);
float AMotionEvent_getX(const AInputEvent *event, size_t pointer_index);
float AMotionEvent_getY(const AInputEvent *event, size_t pointer_index);
#endif
