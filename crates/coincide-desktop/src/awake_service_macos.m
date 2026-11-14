#import <Foundation/Foundation.h>
#import <ServiceManagement/ServiceManagement.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <sys/stat.h>

// Test builds use unique fixture identities; production always uses these.
#ifndef COINCIDE_AWAKE_BUNDLE_ID
#define COINCIDE_AWAKE_BUNDLE_ID @"com.apoorvdarshan.coincide.rust"
#endif
#ifndef COINCIDE_AWAKE_AGENT_PLIST
#define COINCIDE_AWAKE_AGENT_PLIST @"com.apoorvdarshan.coincide.rust.always-on.plist"
#endif
#ifndef COINCIDE_AWAKE_DAEMON_PLIST
#define COINCIDE_AWAKE_DAEMON_PLIST @"com.apoorvdarshan.coincide.rust.battery-helper.plist"
#endif

static void message(char *out, size_t capacity, NSString *value) {
    if (!out || capacity == 0) return;
    const char *text = value.UTF8String ?: "Service Management failed";
    snprintf(out, capacity, "%s", text);
}

static SMAppService *service(int kind) API_AVAILABLE(macos(13.0)) {
    // A test/preview bundle must never register or unregister the real app's
    // background services, even if it has copied these files.
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:COINCIDE_AWAKE_BUNDLE_ID]) return nil;
    if (kind == 0) return [SMAppService agentServiceWithPlistName:COINCIDE_AWAKE_AGENT_PLIST];
    if (kind == 1) return [SMAppService daemonServiceWithPlistName:COINCIDE_AWAKE_DAEMON_PLIST];
    return nil;
}

static BOOL regular_file(NSString *path, BOOL executable) {
    struct stat metadata;
    const char *name = path.fileSystemRepresentation;
    return name && lstat(name, &metadata) == 0 && S_ISREG(metadata.st_mode) &&
        (!executable || (metadata.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) != 0);
}

// BTM returns NotFound for a valid, never-registered item on some macOS
// versions. Inspect the signed bundle separately before calling register.
int coincide_awake_service_present(int kind) {
    @autoreleasepool {
        if (@available(macOS 13.0, *)) {
            if (!service(kind)) return -1;
            NSString *directory = kind == 0 ? @"LaunchAgents" : @"LaunchDaemons";
            NSString *name = kind == 0 ? COINCIDE_AWAKE_AGENT_PLIST : COINCIDE_AWAKE_DAEMON_PLIST;
            NSString *contents = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents"];
            NSString *plist = [[[contents stringByAppendingPathComponent:@"Library"] stringByAppendingPathComponent:directory] stringByAppendingPathComponent:name];
            NSString *helper = [[contents stringByAppendingPathComponent:@"MacOS"] stringByAppendingPathComponent:@"coincide-awake-helper"];
            return regular_file(plist, NO) && regular_file(helper, YES) ? 1 : 0;
        }
        return -1;
    }
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
            if (!item || coincide_awake_service_present(kind) != 1) {
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
