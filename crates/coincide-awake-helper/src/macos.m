#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreFoundation/CoreFoundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/pwr_mgt/IOPM.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

// These functions only observe hardware unless their names explicitly say set.
static CFTypeRef root_property(CFStringRef key) {
    io_service_t root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (root == IO_OBJECT_NULL) return NULL;
    CFTypeRef value = IORegistryEntryCreateCFProperty(root, key, kCFAllocatorDefault, 0);
    IOObjectRelease(root);
    return value;
}

static int boolean_value(CFTypeRef value) {
    if (!value) return -1;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) return CFBooleanGetValue((CFBooleanRef)value) ? 1 : 0;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int number = -1;
        if (CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number) && (number == 0 || number == 1)) return number;
    }
    return -1;
}

int coincide_awake_lid_state(void) {
    CFTypeRef value = root_property(CFSTR("AppleClamshellState"));
    int result = boolean_value(value);
    if (value) CFRelease(value);
    return result;
}

int coincide_awake_sleep_disabled(void) {
    io_service_t root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (root == IO_OBJECT_NULL) return -1;
    CFTypeRef value = IORegistryEntryCreateCFProperty(root, CFSTR("SleepDisabled"), kCFAllocatorDefault, 0);
    IOObjectRelease(root);
    // macOS omits SleepDisabled until it is set; the default is enabled sleep.
    int result = value ? boolean_value(value) : 0;
    if (value) CFRelease(value);
    return result;
}

int coincide_awake_on_battery(void) {
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (!info) return -1;
    CFStringRef source = IOPSGetProvidingPowerSourceType(info);
    int result = -1;
    if (source && (CFEqual(source, CFSTR(kIOPSBatteryPowerValue)) || CFEqual(source, CFSTR("UPS Power")))) result = 1;
    else if (source && CFEqual(source, CFSTR(kIOPSACPowerValue))) result = 0;
    CFRelease(info);
    return result;
}

double coincide_awake_idle_seconds(void) {
    io_service_t system = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"));
    if (system == IO_OBJECT_NULL) return -1.;
    CFTypeRef value = IORegistryEntryCreateCFProperty(system, CFSTR("HIDIdleTime"), kCFAllocatorDefault, 0);
    IOObjectRelease(system);
    int64_t nanoseconds = -1;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &nanoseconds);
    if (value) CFRelease(value);
    return nanoseconds >= 0 ? (double)nanoseconds / 1000000000. : -1.;
}

static AudioObjectPropertyAddress mute_address(AudioObjectPropertyElement element) {
    return (AudioObjectPropertyAddress){kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, element};
}

static bool mute_element(AudioDeviceID device, AudioObjectPropertyElement *element) {
    AudioObjectPropertyElement candidates[] = {kAudioObjectPropertyElementMain, 1};
    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        AudioObjectPropertyAddress address = mute_address(candidates[i]);
        Boolean settable = false;
        if (AudioObjectHasProperty(device, &address) &&
            AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable) {
            *element = candidates[i];
            return true;
        }
    }
    return false;
}

static AudioDeviceID device_for_uid(const char *uid) {
    if (!uid || !*uid || strnlen(uid, 1025) > 1024) return kAudioObjectUnknown;
    CFStringRef string = CFStringCreateWithCString(kCFAllocatorDefault, uid, kCFStringEncodingUTF8);
    if (!string) return kAudioObjectUnknown;
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, sizeof(string), &string, &size, &device);
    CFRelease(string);
    return status == noErr ? device : kAudioObjectUnknown;
}

static int read_mute(AudioDeviceID device, int *muted) {
    if (!muted || device == kAudioObjectUnknown) return 0;
    AudioObjectPropertyElement element;
    if (!mute_element(device, &element)) return 0;
    AudioObjectPropertyAddress address = mute_address(element);
    UInt32 value = 0, size = sizeof(value);
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &value) != noErr || size != sizeof(value)) return 0;
    *muted = value != 0;
    return 1;
}

int coincide_awake_default_output(char *uid, size_t capacity, int *muted) {
    if (!uid || capacity < 2 || !muted) return 0;
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &device) != noErr || !read_mute(device, muted)) return 0;
    address = (AudioObjectPropertyAddress){kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    CFStringRef value = NULL;
    size = sizeof(value);
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &value) != noErr || !value) return 0;
    bool copied = CFStringGetCString(value, uid, (CFIndex)capacity, kCFStringEncodingUTF8);
    CFRelease(value);
    return copied && *uid ? 1 : 0;
}

int coincide_awake_output_muted(const char *uid, int *muted) {
    return read_mute(device_for_uid(uid), muted);
}

int coincide_awake_set_output_muted(const char *uid, int muted) {
    if (muted != 0 && muted != 1) return 0;
    AudioDeviceID device = device_for_uid(uid);
    AudioObjectPropertyElement element;
    if (device == kAudioObjectUnknown || !mute_element(device, &element)) return 0;
    AudioObjectPropertyAddress address = mute_address(element);
    UInt32 value = (UInt32)muted;
    return AudioObjectSetPropertyData(device, &address, 0, NULL, sizeof(value), &value) == noErr;
}

typedef int (*CoincideAwakeCallback)(void *, int);
enum { CA_START = 0, CA_LID = 1, CA_TICK = 2, CA_STOP = 3, CA_POWER = 4 };
typedef struct {
    void *context;
    CoincideAwakeCallback callback;
    CFRunLoopTimerRef timer;
    bool stopped;
} LidLoop;

static void emit_lid(LidLoop *state, int event) {
    int needs_tick = state->callback(state->context, event);
    if (needs_tick < 0) {
        state->stopped = true;
        CFRunLoopStop(CFRunLoopGetCurrent());
    } else if (state->timer) {
        CFRunLoopTimerSetNextFireDate(state->timer, CFAbsoluteTimeGetCurrent() + (needs_tick ? 2. : 86400. * 365.));
    }
}

static void lid_changed(void *context, io_service_t service, natural_t message, void *argument) {
    (void)service; (void)argument;
    if (message == kIOPMMessageClamshellStateChange) emit_lid((LidLoop *)context, CA_LID);
}

static void lid_tick(CFRunLoopTimerRef timer, void *context) {
    (void)timer;
    emit_lid((LidLoop *)context, CA_TICK);
}

static volatile sig_atomic_t signal_fd = -1;
static void stop_signal(int signal_number) {
    (void)signal_number;
    int saved = errno;
    if (signal_fd >= 0) { char byte = 1; (void)write((int)signal_fd, &byte, 1); }
    errno = saved;
}

static void signal_ready(CFFileDescriptorRef descriptor, CFOptionFlags types, void *context) {
    (void)types;
    char bytes[32];
    (void)read(CFFileDescriptorGetNativeDescriptor(descriptor), bytes, sizeof(bytes));
    LidLoop *state = context;
    (void)state->callback(state->context, CA_STOP);
    state->stopped = true;
    CFRunLoopStop(CFRunLoopGetCurrent());
}

int coincide_awake_run_lid(void *context, CoincideAwakeCallback callback) {
    if (!callback) return 1;
    LidLoop state = {.context = context, .callback = callback};
    io_service_t root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (root == IO_OBJECT_NULL) return 1;
    IONotificationPortRef port = IONotificationPortCreate(kIOMainPortDefault);
    if (!port) { IOObjectRelease(root); return 1; }
    io_object_t notification = IO_OBJECT_NULL;
    kern_return_t result = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, lid_changed, &state, &notification);
    IOObjectRelease(root);
    if (result != KERN_SUCCESS) { IONotificationPortDestroy(port); return 1; }
    CFRunLoopSourceRef source = IONotificationPortGetRunLoopSource(port);
    if (!source) { IOObjectRelease(notification); IONotificationPortDestroy(port); return 1; }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
    CFRunLoopTimerContext timer_context = {0, &state, NULL, NULL, NULL};
    state.timer = CFRunLoopTimerCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 86400. * 365., 2., 0, 0, lid_tick, &timer_context);
    if (!state.timer) { IOObjectRelease(notification); IONotificationPortDestroy(port); return 1; }
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), state.timer, kCFRunLoopDefaultMode);

    int pipefd[2] = {-1, -1};
    if (pipe(pipefd) != 0) { CFRelease(state.timer); IOObjectRelease(notification); IONotificationPortDestroy(port); return 1; }
    (void)fcntl(pipefd[1], F_SETFL, O_NONBLOCK);
    (void)fcntl(pipefd[0], F_SETFD, FD_CLOEXEC);
    (void)fcntl(pipefd[1], F_SETFD, FD_CLOEXEC);
    CFFileDescriptorContext fd_context = {0, &state, NULL, NULL, NULL};
    CFFileDescriptorRef descriptor = CFFileDescriptorCreate(kCFAllocatorDefault, pipefd[0], true, signal_ready, &fd_context);
    CFRunLoopSourceRef signal_source = descriptor ? CFFileDescriptorCreateRunLoopSource(kCFAllocatorDefault, descriptor, 0) : NULL;
    if (!signal_source) {
        if (descriptor) { CFFileDescriptorInvalidate(descriptor); CFRelease(descriptor); } else close(pipefd[0]);
        close(pipefd[1]); CFRelease(state.timer); IOObjectRelease(notification); IONotificationPortDestroy(port); return 1;
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), signal_source, kCFRunLoopDefaultMode);
    CFFileDescriptorEnableCallBacks(descriptor, kCFFileDescriptorReadCallBack);
    struct sigaction action = {0}, old_term = {0}, old_int = {0};
    action.sa_handler = stop_signal;
    sigemptyset(&action.sa_mask);
    signal_fd = pipefd[1];
    if (sigaction(SIGTERM, &action, &old_term) != 0 || sigaction(SIGINT, &action, &old_int) != 0) {
        signal_fd = -1;
        CFFileDescriptorInvalidate(descriptor); CFRelease(signal_source); CFRelease(descriptor); close(pipefd[1]);
        CFRelease(state.timer); IOObjectRelease(notification); IONotificationPortDestroy(port); return 1;
    }
    emit_lid(&state, CA_START);
    if (!state.stopped) CFRunLoopRun();
    signal_fd = -1;
    (void)sigaction(SIGTERM, &old_term, NULL); (void)sigaction(SIGINT, &old_int, NULL);
    CFFileDescriptorInvalidate(descriptor); CFRelease(signal_source); CFRelease(descriptor); close(pipefd[1]);
    CFRunLoopTimerInvalidate(state.timer); CFRelease(state.timer);
    IOObjectRelease(notification); IONotificationPortDestroy(port);
    return 0;
}

typedef struct { void *context; CoincideAwakeCallback callback; } PowerLoop;
static void power_changed(void *context) {
    PowerLoop *state = context;
    (void)state->callback(state->context, CA_POWER);
}

static void power_retry(CFRunLoopTimerRef timer, void *context) {
    (void)timer;
    power_changed(context);
}

int coincide_awake_run_power(void *context, CoincideAwakeCallback callback) {
    if (!callback) return 1;
    PowerLoop state = {.context = context, .callback = callback};
    CFRunLoopSourceRef source = IOPSNotificationCreateRunLoopSource(power_changed, &state);
    if (!source) return 1;
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
    CFRunLoopTimerContext timer_context = {0, &state, NULL, NULL, NULL};
    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 30., 30., 0, 0, power_retry, &timer_context);
    if (!timer) { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode); CFRelease(source); return 1; }
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
    power_changed(&state);
    CFRunLoopRun();
    CFRunLoopTimerInvalidate(timer);
    CFRelease(timer);
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
    CFRelease(source);
    return 0;
}
