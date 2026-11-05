#import "computer_use_macos.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dispatch/dispatch.h>
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#define CU_SCREEN_KIT 1
#else
#define CU_SCREEN_KIT 0
#endif
#include <math.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

@interface CUElement : NSObject
@property(nonatomic, assign) AXUIElementRef element;
@property(nonatomic, assign) AXUIElementRef window;
@property(nonatomic) pid_t pid;
@property(nonatomic) CGWindowID windowID;
@property(nonatomic) CGRect bounds;
@property(nonatomic) CGRect elementBounds;
@property(nonatomic, strong) NSString *observedRole;
@property(nonatomic, strong) NSString *observedTitle;
@property(nonatomic, strong) NSString *observedValue;
@end
@implementation CUElement
- (void)dealloc {
  if (_element)
    CFRelease(_element);
  if (_window)
    CFRelease(_window);
}
@end
@interface CUContext : NSObject
@property(nonatomic, strong)
    NSMutableDictionary<NSNumber *, CUElement *> *elements;
@property(nonatomic) uint64_t nextID;
@property(nonatomic) pid_t pid;
@property(nonatomic) CGWindowID windowID;
@property(nonatomic) CGRect bounds;
@property(nonatomic, assign) bool (*check)(const void *);
@property(nonatomic, assign) const void *guard;
@end
@implementation CUContext
- (instancetype)init {
  if ((self = [super init])) {
    _elements = [NSMutableDictionary dictionary];
    _nextID = 1;
  }
  return self;
}
@end
static NSDictionary *CUError(NSString *message) {
  return @{@"error" : message};
}
static NSArray *CUWindows(void) {
  return CFBridgingRelease(
             CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly |
                                            kCGWindowListExcludeDesktopElements,
                                        kCGNullWindowID))
             ?: @[];
}
static NSDictionary *CUWindow(CGWindowID wid, pid_t pid) {
  for (NSDictionary *w in CUWindows())
    if ([w[(id)kCGWindowNumber] unsignedIntValue] == wid &&
        [w[(id)kCGWindowOwnerPID] intValue] == pid &&
        [w[(id)kCGWindowLayer] intValue] == 0)
      return w;
  return nil;
}
static CGRect CUBounds(NSDictionary *w) {
  if (!w)
    return CGRectZero;
  CGRect r = CGRectZero;
  CGRectMakeWithDictionaryRepresentation(
      (__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &r);
  return r;
}
static BOOL CUSame(CGRect a, CGRect b) {
  return fabs(a.origin.x - b.origin.x) < 1 &&
         fabs(a.origin.y - b.origin.y) < 1 &&
         fabs(a.size.width - b.size.width) < 1 &&
         fabs(a.size.height - b.size.height) < 1;
}
static CFTypeRef CUCopy(AXUIElementRef e, CFStringRef attribute) {
  CFTypeRef value = NULL;
  if (AXUIElementCopyAttributeValue(e, attribute, &value) != kAXErrorSuccess) {
    if (value)
      CFRelease(value);
    return NULL;
  }
  return value;
}
static NSString *CUString(AXUIElementRef e, CFStringRef attribute,
                          NSUInteger limit) {
  CFTypeRef v = CUCopy(e, attribute);
  if (!v)
    return @"";
  NSString *s =
      CFGetTypeID(v) == CFStringGetTypeID() ? (__bridge NSString *)v : @"";
  NSString *result = [s substringToIndex:MIN(s.length, limit)];
  CFRelease(v);
  return result;
}
static BOOL CUSecure(AXUIElementRef e) {
  return [CUString(e, kAXSubroleAttribute, 128)
      isEqualToString:@"AXSecureTextField"];
}
static CGRect CUAXBounds(AXUIElementRef e) {
  CGPoint p = CGPointZero;
  CGSize size = CGSizeZero;
  CFTypeRef position = CUCopy(e, kAXPositionAttribute),
            dimensions = CUCopy(e, kAXSizeAttribute);
  if (position && CFGetTypeID(position) == AXValueGetTypeID())
    AXValueGetValue(position, kAXValueCGPointType, &p);
  if (dimensions && CFGetTypeID(dimensions) == AXValueGetTypeID())
    AXValueGetValue(dimensions, kAXValueCGSizeType, &size);
  if (position)
    CFRelease(position);
  if (dimensions)
    CFRelease(dimensions);
  return (CGRect){p, size};
}
static AXUIElementRef CUFindWindow(pid_t pid, CGRect bounds) {
  AXUIElementRef app = AXUIElementCreateApplication(pid);
  AXUIElementSetMessagingTimeout(app, 0.15);
  CFArrayRef windows = NULL;
  if (AXUIElementCopyAttributeValues(app, kAXWindowsAttribute, 0, 129,
                                     &windows) != kAXErrorSuccess) {
    if (windows)
      CFRelease(windows);
    windows = NULL;
  }
  AXUIElementRef result = NULL;
  NSUInteger matches = 0;
  CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 0.6;
  CFIndex total = windows ? CFArrayGetCount(windows) : 0, inspected = 0;
  if (windows && total <= 128 && CFGetTypeID(windows) == CFArrayGetTypeID())
    for (CFIndex i = 0; i < total && CFAbsoluteTimeGetCurrent() < deadline;
         i++) {
      inspected++;
      AXUIElementRef w = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
      if (CUSame(CUAXBounds(w), bounds)) {
        matches++;
        if (!result)
          result = (AXUIElementRef)CFRetain(w);
      }
    }
  if (windows)
    CFRelease(windows);
  CFRelease(app);
  if (matches != 1 || inspected != total) {
    if (result)
      CFRelease(result);
    return NULL;
  }
  return result;
}
static BOOL CUValidate(CUElement *entry) {
  NSDictionary *w = CUWindow(entry.windowID, entry.pid);
  if (!w || !CUSame(CUBounds(w), entry.bounds))
    return NO;
  pid_t pid = 0;
  if (AXUIElementGetPid(entry.element, &pid) != kAXErrorSuccess ||
      pid != entry.pid)
    return NO;
  AXUIElementRef current = CUFindWindow(pid, entry.bounds);
  BOOL same = current && CFEqual(current, entry.window);
  if (current)
    CFRelease(current);
  if (!same || CUSecure(entry.element))
    return NO;
  if (![CUString(entry.element, kAXRoleAttribute, 128)
          isEqual:entry.observedRole] ||
      ![CUString(entry.element, kAXTitleAttribute, 256)
          isEqual:entry.observedTitle] ||
      ![CUString(entry.element, kAXValueAttribute, 1024)
          isEqual:entry.observedValue] ||
      !CUSame(CUAXBounds(entry.element), entry.elementBounds))
    return NO;
  CFTypeRef parent = CUCopy(entry.element, kAXWindowAttribute);
  BOOL belongs = CFEqual(entry.element, entry.window) ||
                 (parent && CFEqual(parent, entry.window));
  if (parent)
    CFRelease(parent);
  return belongs;
}
@interface CUAsync : NSObject
@property(nonatomic, strong) dispatch_semaphore_t ready;
@property(nonatomic, strong) id value;
@end
@implementation CUAsync
- (instancetype)init {
  if ((self = [super init]))
    _ready = dispatch_semaphore_create(0);
  return self;
}
@end
static NSDictionary *CUScreenshot(CGWindowID wid, pid_t pid, CGRect bounds) {
#if CU_SCREEN_KIT && defined(__MAC_OS_X_VERSION_MAX_ALLOWED) &&                \
    __MAC_OS_X_VERSION_MAX_ALLOWED >= 140000
  if (@available(macOS 14.0, *)) {
    if (!CGPreflightScreenCaptureAccess())
      return CUError(@"permission_denied");
    CUAsync *list = [CUAsync new];
    [SCShareableContent
        getShareableContentExcludingDesktopWindows:YES
                               onScreenWindowsOnly:YES
                                 completionHandler:^(
                                     SCShareableContent *content,
                                     NSError *error) {
                                   list.value = error ? nil : content;
                                   dispatch_semaphore_signal(list.ready);
                                 }];
    if (dispatch_semaphore_wait(
            list.ready, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)))
      return CUError(@"timed_out");
    SCWindow *target = nil;
    for (SCWindow *window in [(SCShareableContent *)list.value windows])
      if (window.windowID == wid && window.owningApplication.processID == pid)
        target = window;
    if (!target || !CUSame(target.frame, bounds))
      return CUError(@"stale_observation");
    SCContentFilter *filter =
        [[SCContentFilter alloc] initWithDesktopIndependentWindow:target];
    SCStreamConfiguration *configuration = [SCStreamConfiguration new];
    double scale =
        MIN(1.0, 1600.0 / MAX(bounds.size.width, bounds.size.height));
    configuration.width = MAX(1, (size_t)(bounds.size.width * scale));
    configuration.height = MAX(1, (size_t)(bounds.size.height * scale));
    configuration.showsCursor = NO;
    configuration.ignoreShadowsSingleWindow = YES;
    configuration.scalesToFit = YES;
    configuration.preservesAspectRatio = YES;
    CUAsync *capture = [CUAsync new];
    [SCScreenshotManager
        captureImageWithFilter:filter
                 configuration:configuration
             completionHandler:^(CGImageRef image, NSError *error) {
               @try {
                 if (image && !error) {
                   NSBitmapImageRep *rep =
                       [[NSBitmapImageRep alloc] initWithCGImage:image];
                   NSData *png =
                       [rep representationUsingType:NSBitmapImageFileTypePNG
                                         properties:@{}];
                   if (!png)
                     capture.value = CUError(@"native");
                   else if (png.length > 2000000)
                     capture.value = CUError(@"too_large");
                   else
                     capture.value = @{
                       @"png_base64" : [png base64EncodedStringWithOptions:0],
                       @"width" : @(CGImageGetWidth(image)),
                       @"height" : @(CGImageGetHeight(image))
                     };
                 }
               } @catch (NSException *__unused exception) {
                 capture.value = CUError(@"native");
               }
               dispatch_semaphore_signal(capture.ready);
             }];
    if (dispatch_semaphore_wait(
            capture.ready, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)))
      return CUError(@"timed_out");
    return capture.value ?: CUError(@"native");
  }
#endif
  return CUError(@"unsupported");
}
static BOOL CUIsBrowser(pid_t pid) {
  NSString *bundle =
      [NSRunningApplication runningApplicationWithProcessIdentifier:pid]
              .bundleIdentifier
          ?: @"";
  for (NSString *prefix in @[
         @"com.apple.Safari", @"com.google.Chrome", @"org.mozilla.firefox",
         @"com.microsoft.edgemac", @"com.brave.Browser",
         @"company.thebrowser.Browser", @"com.operasoftware.Opera"
       ])
    if ([bundle hasPrefix:prefix])
      return YES;
  return NO;
}
static NSDictionary *CUObserve(CUContext *ctx, NSDictionary *request) {
  pid_t pid = [request[@"pid"] intValue];
  CGWindowID wid = [request[@"window"] unsignedIntValue];
  if (CUIsBrowser(pid))
    return CUError(@"unsupported");
  NSUInteger limit = MIN(MAX([request[@"limit"] unsignedIntegerValue], 1), 128);
  NSDictionary *info = CUWindow(wid, pid);
  if (!info)
    return CUError(@"stale_observation");
  CGRect bounds = CUBounds(info);
  if (!isfinite(bounds.origin.x) || !isfinite(bounds.origin.y) ||
      !isfinite(bounds.size.width) || !isfinite(bounds.size.height) ||
      bounds.size.width <= 0 || bounds.size.height <= 0 ||
      bounds.size.width > 100000 || bounds.size.height > 100000)
    return CUError(@"native");
  AXUIElementRef window = CUFindWindow(pid, bounds);
  if (!window)
    return CUError(@"stale_observation");
  [ctx.elements removeAllObjects];
  ctx.pid = pid;
  ctx.windowID = wid;
  ctx.bounds = bounds;
  CUElement *root = [CUElement new];
  root.element = (AXUIElementRef)CFRetain(window);
  root.window = (AXUIElementRef)CFRetain(window);
  root.pid = pid;
  root.windowID = wid;
  root.bounds = bounds;
  NSMutableArray *queue = [NSMutableArray arrayWithObject:@{
    @"node" : root,
    @"depth" : @0
  }],
                 *nodes = [NSMutableArray array];
  CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 0.6;
  while (queue.count && nodes.count < limit &&
         CFAbsoluteTimeGetCurrent() < deadline) {
    NSDictionary *job = queue.firstObject;
    [queue removeObjectAtIndex:0];
    CUElement *record = job[@"node"];
    NSUInteger depth = [job[@"depth"] unsignedIntegerValue];
    AXUIElementRef element = record.element;
    AXUIElementSetMessagingTimeout(element, 0.15);
    BOOL secure = CUSecure(element);
    record.observedRole = CUString(element, kAXRoleAttribute, 128);
    if ([record.observedRole isEqualToString:@"AXWebArea"]) {
      [ctx.elements removeAllObjects];
      CFRelease(window);
      return CUError(@"unsupported");
    }
    record.observedTitle = CUString(element, kAXTitleAttribute, 256);
    record.observedValue =
        secure ? @"" : CUString(element, kAXValueAttribute, 1024);
    record.elementBounds = CUAXBounds(element);
    CFTypeRef focus = CUCopy(element, kAXFocusedAttribute);
    BOOL focused = focus && CFGetTypeID(focus) == CFBooleanGetTypeID() &&
                   CFBooleanGetValue(focus);
    if (focus)
      CFRelease(focus);
    NSNumber *identity = @(ctx.nextID++);
    ctx.elements[identity] = record;
    [nodes addObject:@{
      @"native_id" : identity,
      @"role" : record.observedRole,
      @"title" : record.observedTitle,
      @"value" : secure ? [NSNull null] : record.observedValue,
      @"secure" : @(secure),
      @"focused" : @(focused)
    }];
    if (depth >= 4 || secure)
      continue;
    CFArrayRef children = NULL;
    CFIndex remaining = (CFIndex)(limit - nodes.count - queue.count);
    if (remaining > 0 && AXUIElementCopyAttributeValues(
                             element, kAXChildrenAttribute, 0, remaining,
                             &children) != kAXErrorSuccess) {
      if (children)
        CFRelease(children);
      children = NULL;
    }
    if (children && CFGetTypeID(children) == CFArrayGetTypeID())
      for (CFIndex i = 0;
           i < CFArrayGetCount(children) && queue.count + nodes.count < limit;
           i++) {
        AXUIElementRef child =
            (AXUIElementRef)CFArrayGetValueAtIndex(children, i);
        if (CFGetTypeID(child) != AXUIElementGetTypeID())
          continue;
        CUElement *next = [CUElement new];
        next.element = (AXUIElementRef)CFRetain(child);
        next.window = (AXUIElementRef)CFRetain(window);
        next.pid = pid;
        next.windowID = wid;
        next.bounds = bounds;
        [queue addObject:@{@"node" : next, @"depth" : @(depth + 1)}];
      }
    if (children)
      CFRelease(children);
  }
  CFRelease(window);
  NSMutableDictionary *result = [@{
    @"nodes" : nodes,
    @"width" : @(bounds.size.width),
    @"height" : @(bounds.size.height)
  } mutableCopy];
  if ([request[@"screenshot"] boolValue]) {
    NSDictionary *image = CUScreenshot(wid, pid, bounds);
    if (image[@"error"]) {
      [ctx.elements removeAllObjects];
      return image;
    }
    result[@"screenshot"] = image;
  }
  return result;
}
static NSDictionary *CUInput(CUContext *ctx, NSDictionary *request) {
  if (!ctx.check || !ctx.check(ctx.guard))
    return CUError(@"revoked");
  NSString *op = request[@"op"];
  CUElement *record = ctx.elements[request[@"native"]];
  if ([op isEqualToString:@"point"]) {
    pid_t pid = [request[@"pid"] intValue];
    CGWindowID wid = [request[@"window"] unsignedIntValue];
    double x = [request[@"x"] doubleValue], y = [request[@"y"] doubleValue];
    if (pid != ctx.pid || wid != ctx.windowID || !isfinite(x) || !isfinite(y) ||
        x < 0 || y < 0 || x >= ctx.bounds.size.width ||
        y >= ctx.bounds.size.height ||
        !CUSame(CUBounds(CUWindow(wid, pid)), ctx.bounds))
      return CUError(@"stale_observation");
    if (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier !=
        pid)
      return CUError(@"stale_observation");
    CGPoint p = CGPointMake(ctx.bounds.origin.x + x, ctx.bounds.origin.y + y);
    BOOL target = NO;
    for (NSDictionary *w in CUWindows())
      if ([w[(id)kCGWindowLayer] intValue] == 0 &&
          CGRectContainsPoint(CUBounds(w), p)) {
        target = [w[(id)kCGWindowNumber] unsignedIntValue] == wid;
        break;
      }
    if (!target)
      return CUError(@"stale_observation");
    CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, p,
                                              kCGMouseButtonLeft),
               up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, p,
                                            kCGMouseButtonLeft);
    if (!down || !up) {
      if (down)
        CFRelease(down);
      if (up)
        CFRelease(up);
      return CUError(@"native");
    }
    if (!ctx.check || !ctx.check(ctx.guard)) {
      CFRelease(down);
      CFRelease(up);
      return CUError(@"revoked");
    }
    CGEventPost(kCGHIDEventTap, down);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(down);
    CFRelease(up);
    return @{@"done" : @YES};
  }
  if (!record || !CUValidate(record))
    return CUError(@"stale_observation");
  if ([op isEqualToString:@"press"]) {
    if (!ctx.check || !ctx.check(ctx.guard))
      return CUError(@"revoked");
    if (AXUIElementPerformAction(record.element, kAXPressAction) !=
        kAXErrorSuccess)
      return CUError(@"unsupported");
  } else if ([op isEqualToString:@"set_value"]) {
    Boolean settable = false;
    if (AXUIElementIsAttributeSettable(record.element, kAXValueAttribute,
                                       &settable) != kAXErrorSuccess ||
        !settable)
      return CUError(@"unsupported");
    NSString *text = request[@"text"];
    if (![text isKindOfClass:NSString.class] || text.length > 16384)
      return CUError(@"invalid_request");
    if (!ctx.check || !ctx.check(ctx.guard))
      return CUError(@"revoked");
    if (AXUIElementSetAttributeValue(record.element, kAXValueAttribute,
                                     (__bridge CFStringRef)text) !=
        kAXErrorSuccess)
      return CUError(@"native");
  } else if ([op isEqualToString:@"key"]) {
    CFTypeRef focused = CUCopy(record.element, kAXFocusedAttribute);
    BOOL isFocused = focused && CFGetTypeID(focused) == CFBooleanGetTypeID() &&
                     CFBooleanGetValue(focused);
    if (focused)
      CFRelease(focused);
    if (!isFocused ||
        NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier !=
            record.pid)
      return CUError(@"stale_observation");
    NSDictionary *keys = @{
      @"enter" : @36,
      @"escape" : @53,
      @"tab" : @48,
      @"backspace" : @51,
      @"left" : @123,
      @"right" : @124,
      @"up" : @126,
      @"down" : @125
    };
    NSNumber *key = keys[request[@"key"]];
    if (!key)
      return CUError(@"invalid_request");
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, key.unsignedShortValue,
                                                 true),
               up = CGEventCreateKeyboardEvent(NULL, key.unsignedShortValue,
                                               false);
    if (!down || !up) {
      if (down)
        CFRelease(down);
      if (up)
        CFRelease(up);
      return CUError(@"native");
    }
    CGEventSetFlags(down, 0);
    CGEventSetFlags(up, 0);
    if (!ctx.check || !ctx.check(ctx.guard)) {
      CFRelease(down);
      CFRelease(up);
      return CUError(@"revoked");
    }
    CGEventPost(kCGHIDEventTap, down);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(down);
    CFRelease(up);
  } else
    return CUError(@"unsupported");
  return @{@"done" : @YES};
}
static NSDictionary *CUExecute(CUContext *ctx, NSDictionary *r) {
  NSString *op = r[@"op"];
  if ([op isEqualToString:@"invalidate"]) {
    [ctx.elements removeAllObjects];
    ctx.windowID = 0;
    return @{@"done" : @YES};
  }
  if ([op isEqualToString:@"request_ax"]) {
    NSDictionary *options =
        @{(__bridge NSString *)kAXTrustedCheckOptionPrompt : @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
  }
  if ([op isEqualToString:@"request_screen"]) {
    CGRequestScreenCaptureAccess();
  }
  if ([op isEqualToString:@"permissions"] || [op hasPrefix:@"request_"])
    return @{
      @"ax" : @(AXIsProcessTrusted()),
      @"screen" : @(CGPreflightScreenCaptureAccess())
    };
  if (!AXIsProcessTrusted())
    return CUError(@"permission_denied");
  if ([op isEqualToString:@"apps"]) {
    NSMutableArray *apps = [NSMutableArray array];
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace
             .runningApplications) {
      if (app.activationPolicy != NSApplicationActivationPolicyRegular)
        continue;
      [apps addObject:@{
        @"pid" : @(app.processIdentifier),
        @"name" : app.localizedName ?: @"",
        @"bundle_id" : app.bundleIdentifier ?: @""
      }];
      if (apps.count >= 128)
        break;
    }
    return @{@"data" : apps};
  }
  if ([op isEqualToString:@"windows"]) {
    NSMutableArray *windows = [NSMutableArray array];
    pid_t pid = [r[@"pid"] intValue];
    for (NSDictionary *w in CUWindows()) {
      if ([w[(id)kCGWindowLayer] intValue] != 0 ||
          (pid > 0 && [w[(id)kCGWindowOwnerPID] intValue] != pid))
        continue;
      CGRect b = CUBounds(w);
      [windows addObject:@{
        @"pid" : w[(id)kCGWindowOwnerPID],
        @"window_id" : w[(id)kCGWindowNumber],
        @"title" : w[(id)kCGWindowName] ?: @"",
        @"x" : @(b.origin.x),
        @"y" : @(b.origin.y),
        @"width" : @(b.size.width),
        @"height" : @(b.size.height)
      }];
      if (windows.count >= 128)
        break;
    }
    return @{@"data" : windows};
  }
  if ([op isEqualToString:@"observe"])
    return CUObserve(ctx, r);
  return CUInput(ctx, r);
}
void *coincide_cu_create(void) {
  @autoreleasepool {
    return (__bridge_retained void *)[CUContext new];
  }
}
void coincide_cu_destroy(void *context) {
  if (context) {
    id released = CFBridgingRelease(context);
    (void)released;
  }
}
char *coincide_cu_call(void *context, const unsigned char *request,
                       size_t length, size_t *result_length,
                       bool (*check)(const void *), const void *guard) {
  @autoreleasepool {
    if (!result_length)
      return NULL;
    *result_length = 0;
    NSDictionary *answer = CUError(@"invalid_request");
    if (context && request && length <= 262144) {
      @try {
        id r = [NSJSONSerialization
            JSONObjectWithData:[NSData dataWithBytes:request length:length]
                       options:0
                         error:NULL];
        if ([r isKindOfClass:NSDictionary.class] &&
            [r[@"op"] isKindOfClass:NSString.class]) {
          CUContext *ctx = (__bridge CUContext *)context;
          ctx.check = check;
          ctx.guard = guard;
          @try {
            answer = CUExecute(ctx, r);
          } @finally {
            ctx.check = NULL;
            ctx.guard = NULL;
          }
        }
      } @catch (NSException *__unused exception) {
        answer = CUError(@"native");
      }
    }
    NSData *bytes = nil;
    @try {
      bytes = [NSJSONSerialization dataWithJSONObject:answer
                                              options:0
                                                error:NULL];
      if (!bytes || bytes.length > 4194304)
        bytes = [NSJSONSerialization dataWithJSONObject:CUError(@"too_large")
                                                options:0
                                                  error:NULL];
    } @catch (NSException *__unused exception) {
      static const char failure[] = "{\"error\":\"native\"}";
      bytes = [NSData dataWithBytes:failure length:sizeof(failure) - 1];
    }
    if (!bytes)
      return NULL;
    char *out = malloc(bytes.length + 1);
    if (!out)
      return NULL;
    memcpy(out, bytes.bytes, bytes.length);
    out[bytes.length] = 0;
    *result_length = bytes.length;
    return out;
  }
}
void coincide_cu_free(char *buffer) { free(buffer); }
