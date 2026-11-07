#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import "microphone_macos.h"
#include <stdlib.h>
#include <string.h>
#define CC_DEVICE_LIMIT 128
static BOOL CCInputDevice(AudioDeviceID device) {
    AudioObjectPropertyAddress address = { kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) != noErr || size < offsetof(AudioBufferList, mBuffers) || size > 1024 * 1024) return NO;
    UInt32 capacity = size;
    AudioBufferList *buffers = calloc(1, size);
    if (!buffers) return NO;
    BOOL input = NO;
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, buffers) == noErr && size >= offsetof(AudioBufferList, mBuffers) && size <= capacity &&
        buffers->mNumberBuffers <= (size - offsetof(AudioBufferList, mBuffers)) / sizeof(AudioBuffer)) {
        for (UInt32 index = 0; index < buffers->mNumberBuffers; ++index) if (buffers->mBuffers[index].mNumberChannels > 0) { input = YES; break; }
    }
    free(buffers); return input;
}
static char *CCDeviceString(AudioDeviceID device, AudioObjectPropertySelector selector, size_t limit) {
    AudioObjectPropertyAddress address = { selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef string = NULL; UInt32 size = sizeof(string);
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &string) != noErr || !string) return NULL;
    NSString *value = CFBridgingRelease(string);
    if (![value isKindOfClass:NSString.class] || !value.length || value.length > limit) return NULL;
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length || data.length > limit || memchr(data.bytes, 0, data.length)) return NULL;
    char *copy = malloc(data.length + 1); if (!copy) return NULL;
    memcpy(copy, data.bytes, data.length); copy[data.length] = 0; return copy;
}
static int CCDeviceIDs(AudioDeviceID *devices, size_t *count) {
    AudioObjectPropertyAddress address = { kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size) != noErr || size > CC_DEVICE_LIMIT * sizeof(AudioDeviceID) || size % sizeof(AudioDeviceID)) return -1;
    if (size && AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, devices) != noErr) return -1;
    if (size > CC_DEVICE_LIMIT * sizeof(AudioDeviceID) || size % sizeof(AudioDeviceID)) return -1;
    *count = size / sizeof(AudioDeviceID); return 0;
}
void cc_mic_input_devices_free(CCMicInputDevice *devices, size_t count) {
    if (!devices) return;
    for (size_t index = 0; index < count; ++index) { free(devices[index].uid); free(devices[index].name); }
    free(devices);
}
// Explicit Refresh only: CoreAudio metadata, no TCC query or audio engine.
int cc_mic_input_devices(CCMicInputDevice **out, size_t *count) {
    if (!out || !count) return -7; *out = NULL; *count = 0;
    @autoreleasepool {
        AudioDeviceID ids[CC_DEVICE_LIMIT] = {0}; size_t total = 0;
        if (CCDeviceIDs(ids, &total) != 0) return -1;
        AudioDeviceID defaultID = kAudioObjectUnknown; UInt32 size = sizeof(defaultID);
        AudioObjectPropertyAddress address = { kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &defaultID) != noErr) defaultID = kAudioObjectUnknown;
        CCMicInputDevice *devices = calloc(total ? total : 1, sizeof(CCMicInputDevice));
        if (!devices) return -1;
        size_t written = 0;
        for (size_t index = 0; index < total; ++index) {
            if (!CCInputDevice(ids[index])) continue;
            char *uid = CCDeviceString(ids[index], kAudioDevicePropertyDeviceUID, 4096);
            char *name = CCDeviceString(ids[index], kAudioObjectPropertyName, 512);
            if (!uid || !name) { free(uid); free(name); continue; }
            devices[written++] = (CCMicInputDevice){ uid, name, ids[index] == defaultID };
        }
        *out = devices; *count = written; return 0;
    }
}
// A missing/ambiguous selected UID is an error. Never return the default ID.
uint32_t cc_mic_resolve_input_device(const char *uid) {
    if (!uid || !*uid || strnlen(uid, 4097) > 4096) return kAudioObjectUnknown;
    @autoreleasepool {
        AudioDeviceID ids[CC_DEVICE_LIMIT] = {0}; size_t count = 0;
        if (CCDeviceIDs(ids, &count) != 0) return kAudioObjectUnknown;
        AudioDeviceID found = kAudioObjectUnknown;
        for (size_t index = 0; index < count; ++index) {
            if (!CCInputDevice(ids[index])) continue;
            char *candidate = CCDeviceString(ids[index], kAudioDevicePropertyDeviceUID, 4096);
            BOOL matches = candidate && strcmp(candidate, uid) == 0; free(candidate);
            if (matches) { if (found != kAudioObjectUnknown) return kAudioObjectUnknown; found = ids[index]; }
        }
        return found;
    }
}
