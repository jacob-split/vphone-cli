#import "vphoned_hid.h"
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <unistd.h>

typedef void *IOHIDEventSystemClientRef;
typedef void *IOHIDEventRef;
typedef double IOHIDFloat;

static IOHIDEventSystemClientRef (*pCreate)(CFAllocatorRef);
static IOHIDEventRef (*pKeyboard)(CFAllocatorRef, uint64_t,
                                  uint32_t, uint32_t, int, int);
static void (*pSetSender)(IOHIDEventRef, uint64_t);
static void (*pDispatch)(IOHIDEventSystemClientRef, IOHIDEventRef);

// Digitizer (touch) event symbols — resolved lazily; touch is a no-op if absent.
static IOHIDEventRef (*pDigitizer)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                   uint32_t, uint32_t, uint32_t, IOHIDFloat,
                                   IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat,
                                   boolean_t, boolean_t, uint32_t);
static IOHIDEventRef (*pFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat,
                                IOHIDFloat, IOHIDFloat, boolean_t, boolean_t, uint32_t);
static void (*pAppend)(IOHIDEventRef, IOHIDEventRef, uint32_t);
static void (*pSetInt)(IOHIDEventRef, uint32_t, int);
static void (*pSetFloat)(IOHIDEventRef, uint32_t, IOHIDFloat);

static IOHIDEventSystemClientRef gClient;
static dispatch_queue_t gHIDQueue;

// Digitizer constants matching TrollVNC/STHIDEventGenerator's proven iOS path.
#define VP_DIG_RANGE       0x00000001u
#define VP_DIG_TOUCH       0x00000002u
#define VP_DIG_POSITION    0x00000004u
#define VP_DIG_IDENTITY    0x00000020u
#define VP_DIG_ATTRIBUTE   0x00000040u
#define VP_TRANSDUCER_HAND 3u
#define VP_FINGER_ID       2u
#define VP_FIELD_IS_BUILT_IN 4u
#define VP_FIELD_DIGITIZER_MAJOR_RADIUS ((((uint32_t)11) << 16) + 20u)
#define VP_FIELD_DIGITIZER_MINOR_RADIUS ((((uint32_t)11) << 16) + 21u)
#define VP_FIELD_IS_DISPLAY_INTEGRATED  ((((uint32_t)11) << 16) + 25u)

BOOL vp_hid_load(void) {
    if (gClient && pCreate && pKeyboard && pSetSender && pDispatch && gHIDQueue) return YES;
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!h) { NSLog(@"vphoned: dlopen IOKit failed"); return NO; }

    pCreate    = dlsym(h, "IOHIDEventSystemClientCreate");
    pKeyboard  = dlsym(h, "IOHIDEventCreateKeyboardEvent");
    pSetSender = dlsym(h, "IOHIDEventSetSenderID");
    pDispatch  = dlsym(h, "IOHIDEventSystemClientDispatchEvent");

    pDigitizer = dlsym(h, "IOHIDEventCreateDigitizerEvent");
    pFinger    = dlsym(h, "IOHIDEventCreateDigitizerFingerEvent");
    pAppend    = dlsym(h, "IOHIDEventAppendEvent");
    pSetInt    = dlsym(h, "IOHIDEventSetIntegerValue");
    pSetFloat  = dlsym(h, "IOHIDEventSetFloatValue");

    if (!pCreate || !pKeyboard || !pSetSender || !pDispatch) {
        NSLog(@"vphoned: missing IOKit symbols");
        return NO;
    }
    if (!pDigitizer || !pFinger || !pAppend || !pSetInt || !pSetFloat)
        NSLog(@"vphoned: digitizer symbols missing, touch injection disabled");

    gClient = pCreate(kCFAllocatorDefault);
    if (!gClient) { NSLog(@"vphoned: IOHIDEventSystemClientCreate returned NULL"); return NO; }

    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    gHIDQueue = dispatch_queue_create("com.vphone.vphoned.hid", attr);

    NSLog(@"vphoned: IOKit loaded");
    return YES;
}

static void send_hid_event(IOHIDEventRef event) {
    IOHIDEventRef strong = (IOHIDEventRef)CFRetain(event);
    dispatch_async(gHIDQueue, ^{
        pSetSender(strong, 0x8000000817319371);
        pDispatch(gClient, strong);
        CFRelease(strong);
    });
}

void vp_hid_press(uint32_t page, uint32_t usage) {
    if ((!gClient || !pKeyboard || !pDispatch || !gHIDQueue) && !vp_hid_load()) return;
    IOHIDEventRef down = pKeyboard(kCFAllocatorDefault, mach_absolute_time(),
                                   page, usage, 1, 0);
    if (!down) return;
    send_hid_event(down);
    CFRelease(down);

    usleep(100000);

    IOHIDEventRef up = pKeyboard(kCFAllocatorDefault, mach_absolute_time(),
                                 page, usage, 0, 0);
    if (!up) return;
    send_hid_event(up);
    CFRelease(up);
}

void vp_hid_key(uint32_t page, uint32_t usage, BOOL down) {
    if ((!gClient || !pKeyboard || !pDispatch || !gHIDQueue) && !vp_hid_load()) return;
    IOHIDEventRef ev = pKeyboard(kCFAllocatorDefault, mach_absolute_time(),
                                 page, usage, down ? 1 : 0, 0);
    if (ev) { send_hid_event(ev); CFRelease(ev); }
}

// Build the same display-integrated one-finger event shape used by
// TrollVNC's STHIDEventGenerator. x/y are normalized display coordinates.
static void dispatch_digitizer(double x, double y, int phase) {
    if (!pDigitizer || !pFinger || !pAppend || !pSetInt || !pSetFloat) return;

    const boolean_t touching = (phase != 3);
    uint32_t eventMask;
    if (phase == 1) {
        eventMask = VP_DIG_POSITION | VP_DIG_ATTRIBUTE;
    } else {
        eventMask = VP_DIG_TOUCH | VP_DIG_IDENTITY;
    }

    uint64_t ts = mach_absolute_time();
    IOHIDEventRef parent = pDigitizer(
        kCFAllocatorDefault, ts, VP_TRANSDUCER_HAND,
        0, 0, eventMask, 0,
        0, 0, 0, 0, 0,
        0, touching, 0
    );
    if (!parent) return;
    pSetInt(parent, VP_FIELD_IS_BUILT_IN, 1);
    pSetInt(parent, VP_FIELD_IS_DISPLAY_INTEGRATED, 1);

    // TrollVNC passes the GSEvent proximity bits through these boolean_t
    // parameters verbatim: InRange=1 and InTouch=2. Preserve those values
    // rather than collapsing the touch bit to boolean 1.
    const boolean_t inRange = touching ? 1 : 0;
    const boolean_t inTouch = touching ? 2 : 0;
    const IOHIDFloat radius = touching ? 5.0 : 0.0;
    IOHIDEventRef finger = pFinger(
        kCFAllocatorDefault, ts, VP_FINGER_ID, VP_FINGER_ID,
        eventMask, x, y, 0,
        0, 90.0, inRange, inTouch, 0
    );
    if (finger) {
        pSetFloat(finger, VP_FIELD_DIGITIZER_MINOR_RADIUS, radius);
        pSetFloat(finger, VP_FIELD_DIGITIZER_MAJOR_RADIUS, radius);
        pAppend(parent, finger, 0);
        CFRelease(finger);
    }

    send_hid_event(parent);
    CFRelease(parent);
}

void vp_hid_touch(int phase, double x, double y) {
    if ((!gClient || !pDispatch || !gHIDQueue) && !vp_hid_load()) return;
    // Clamp normalized coordinates exactly once at the daemon boundary.
    if (x < 0) x = 0; else if (x > 1) x = 1;
    if (y < 0) y = 0; else if (y > 1) y = 1;
    dispatch_digitizer(x, y, phase == 1 ? 1 : (phase == 0 ? 0 : 3));
}
