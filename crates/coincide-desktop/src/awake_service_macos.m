#import <Foundation/Foundation.h>
#import <ServiceManagement/ServiceManagement.h>
#include <dispatch/dispatch.h>
#include <stdio.h>

static void message(char *out, size_t capacity, NSString *value) {
    if (!out || capacity == 0) return;
    const char *text = value.UTF8String ?: "Service Management failed";
    snprintf(out, capacity, "%s", text);
}

static SMAppService *service(int kind) API_AVAILABLE(macos(13.0)) {
    // A test/preview bundle must never register or unregister the real app's
    // background services, even if it has copied these files.
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apoorvdarshan.coincide.rust"]) return nil;
    if (kind == 0) return [SMAppService agentServiceWithPlistName:@"com.apoorvdarshan.coincide.rust.always-on.plist"];
    if (kind == 1) return [SMAppService daemonServiceWithPlistName:@"com.apoorvdarshan.coincide.rust.battery-helper.plist"];
    return nil;
}

// Returns Apple's SMAppServiceStatus values, or -1 if unavailable.
int coincide_awake_service_status(int kind) {
    @autoreleasepool {
        if (@available(macOS 13.0, *)) {
            SMAppService *item = service(kind);
            return item ? (int)item.status : -1;
        }
        return -1;
    }
}

int coincide_awake_service_register(int kind, char *error, size_t capacity) {
    @autoreleasepool {
        if (@available(macOS 13.0, *)) {
            SMAppService *item = service(kind);
            if (!item || item.status == SMAppServiceStatusNotFound) {
                message(error, capacity, @"Keep Awake helper is not included in this app build.");
                return -1;
            }
            if (item.status == SMAppServiceStatusEnabled || item.status == SMAppServiceStatusRequiresApproval) return (int)item.status;
            NSError *failure = nil;
            if (![item registerAndReturnError:&failure]) {
                if (item.status == SMAppServiceStatusRequiresApproval) return (int)item.status;
                message(error, capacity, failure.localizedDescription);
                return -1;
            }
            return (int)item.status;
        }
        message(error, capacity, @"Keep Awake background helpers require macOS 13 or later.");
        return -1;
    }
}

// Completion is required: restoring pmset while a root helper is still alive
// would let that helper race the restore. The callback owns its captured state
// even if our bounded wait expires.
int coincide_awake_service_unregister(int kind, char *error, size_t capacity) {
    @autoreleasepool {
        if (@available(macOS 13.0, *)) {
            SMAppService *item = service(kind);
            if (!item) { message(error, capacity, @"Keep Awake helper is unavailable."); return -1; }
            if (item.status == SMAppServiceStatusNotRegistered || item.status == SMAppServiceStatusNotFound) return 0;
            dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
            __block NSError *failure = nil;
            [item unregisterWithCompletionHandler:^(NSError *result) {
                failure = result;
                dispatch_semaphore_signal(semaphore);
            }];
            if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)) != 0) {
                message(error, capacity, @"Waiting for the Keep Awake helper to stop timed out; try again.");
                return -1;
            }
            if (failure) { message(error, capacity, failure.localizedDescription); return -1; }
            return 0;
        }
        message(error, capacity, @"Keep Awake background helpers require macOS 13 or later.");
        return -1;
    }
}

void coincide_awake_open_login_items(void) {
    if (@available(macOS 13.0, *)) [SMAppService openSystemSettingsLoginItems];
}
