#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdint.h>
#include <math.h>
typedef struct { double idle; uint32_t known; uint32_t locked; uint32_t asleep; } CoincideNotificationActivity;
CoincideNotificationActivity coincide_notification_activity(void) {
    @autoreleasepool {
        CoincideNotificationActivity value = {0};
        value.idle = CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState, (CGEventType)UINT32_MAX);
        if (isfinite(value.idle) && value.idle >= 0) value.known |= 1;
        CFDictionaryRef session = CGSessionCopyCurrentDictionary();
        if (session) {
            CFTypeRef locked = CFDictionaryGetValue(session, CFSTR("CGSSessionScreenIsLocked"));
            if (!locked || CFGetTypeID(locked) == CFBooleanGetTypeID()) {
                value.known |= 2;
                value.locked = locked && CFBooleanGetValue((CFBooleanRef)locked);
            }
            CFRelease(session);
        }
        value.asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0;
        value.known |= 4;
        return value;
    }
}
