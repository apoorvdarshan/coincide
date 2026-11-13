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
#include <unistd.h>

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
@property(nonatomic, strong) NSString *screenshot;
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
      if (CFGetTypeID(w) != AXUIElementGetTypeID())
        continue;
      AXUIElementSetMessagingTimeout(w, 0.15);
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
// Captures a window, or a region of it in window points (zoom), as PNG.
static NSDictionary *CUCapture(CGWindowID wid, pid_t pid, CGRect bounds,
                               CGRect source, double maxScale) {
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
    CGSize area = CGRectIsNull(source) ? bounds.size : source.size;
    double scale = MIN(maxScale, 1600.0 / MAX(area.width, area.height));
    configuration.width = MAX(1, (size_t)(area.width * scale));
    configuration.height = MAX(1, (size_t)(area.height * scale));
    if (!CGRectIsNull(source))
      configuration.sourceRect = source;
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
static NSDictionary *CUScreenshot(CGWindowID wid, pid_t pid, CGRect bounds) {
  return CUCapture(wid, pid, bounds, CGRectNull, 1.0);
}
static BOOL CUIsBrowserBundle(NSString *bundle) {
  bundle = bundle ?: @"";
  for (NSString *prefix in @[
         @"com.apple.Safari", @"com.google.Chrome", @"org.mozilla.firefox",
         @"com.microsoft.edgemac", @"com.brave.Browser",
         @"company.thebrowser.Browser", @"com.operasoftware.Opera"
       ])
    if ([bundle hasPrefix:prefix])
      return YES;
  return NO;
}
static BOOL CUIsBrowser(pid_t pid) {
  return CUIsBrowserBundle(
      [NSRunningApplication runningApplicationWithProcessIdentifier:pid]
          .bundleIdentifier);
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
  ctx.screenshot = nil;
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
    pid_t actualPID = 0;
    if (AXUIElementGetPid(element, &actualPID) != kAXErrorSuccess ||
        actualPID != pid)
      continue;
    if (!CFEqual(element, window)) {
      CFTypeRef containing = CUCopy(element, kAXWindowAttribute);
      BOOL same = containing && CFEqual(containing, window);
      if (containing)
        CFRelease(containing);
      if (!same)
        continue;
    }
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
    ctx.screenshot = image[@"png_base64"];
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
    if (!target || !ctx.screenshot)
      return CUError(@"stale_observation");
    // Pixel input is denied if the captured window content changed since the
    // observation. Re-capture is bounded and never creates an input fallback.
    NSDictionary *fresh = CUScreenshot(wid, pid, ctx.bounds);
    if (fresh[@"error"])
      return fresh;
    if (![fresh[@"png_base64"] isEqualToString:ctx.screenshot])
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
// MARK: Extended tools. Every target is rechecked here, immediately before
// input, exactly as for click_point and press_key; nothing is retried.
static BOOL CUTopmost(CGPoint p, CGWindowID wid) {
  for (NSDictionary *w in CUWindows())
    if ([w[(id)kCGWindowLayer] intValue] == 0 &&
        CGRectContainsPoint(CUBounds(w), p))
      return [w[(id)kCGWindowNumber] unsignedIntValue] == wid;
  return NO;
}
static BOOL CUFrontmost(pid_t pid) {
  return NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier ==
         pid;
}
// A point of the current screenshot observation, in screen points. Pixel
// input is denied if the captured window content changed since then.
static NSDictionary *CUObservedPoint(CUContext *ctx, NSDictionary *target,
                                     BOOL recapture, CGPoint *out) {
  if (![target isKindOfClass:NSDictionary.class])
    return CUError(@"invalid_request");
  pid_t pid = [target[@"pid"] intValue];
  CGWindowID wid = [target[@"window"] unsignedIntValue];
  double x = [target[@"x"] doubleValue], y = [target[@"y"] doubleValue];
  if (pid != ctx.pid || wid != ctx.windowID || !isfinite(x) || !isfinite(y) ||
      x < 0 || y < 0 || x >= ctx.bounds.size.width ||
      y >= ctx.bounds.size.height ||
      !CUSame(CUBounds(CUWindow(wid, pid)), ctx.bounds) || !CUFrontmost(pid))
    return CUError(@"stale_observation");
  CGPoint p = CGPointMake(ctx.bounds.origin.x + x, ctx.bounds.origin.y + y);
  if (!CUTopmost(p, wid) || !ctx.screenshot)
    return CUError(@"stale_observation");
  if (recapture) {
    NSDictionary *fresh = CUScreenshot(wid, pid, ctx.bounds);
    if (fresh[@"error"])
      return fresh;
    if (![fresh[@"png_base64"] isEqualToString:ctx.screenshot])
      return CUError(@"stale_observation");
  }
  *out = p;
  return nil;
}
// The center of a validated element in the foreground app.
static NSDictionary *CUElementPoint(CUElement *record, CGPoint *out) {
  if (!record || !CUValidate(record) || !CUFrontmost(record.pid))
    return CUError(@"stale_observation");
  CGRect b = record.elementBounds;
  if (b.size.width <= 0 || b.size.height <= 0)
    return CUError(@"unsupported");
  CGPoint p = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
  if (!CUTopmost(p, record.windowID))
    return CUError(@"stale_observation");
  *out = p;
  return nil;
}
static NSDictionary *CUTarget(CUContext *ctx, NSDictionary *target,
                              CUElement **element, CGPoint *out) {
  if (![target isKindOfClass:NSDictionary.class])
    return CUError(@"invalid_request");
  if (target[@"native"]) {
    *element = ctx.elements[target[@"native"]];
    return CUElementPoint(*element, out);
  }
  *element = nil;
  return CUObservedPoint(ctx, target, YES, out);
}
// Posts every event after one final authority check, then releases them. A
// press is never left without its release.
static NSDictionary *CUPost(CUContext *ctx, CGEventRef *events, size_t count) {
  BOOL complete = YES;
  for (size_t i = 0; i < count; i++)
    complete = complete && events[i];
  NSDictionary *result = nil;
  if (!complete)
    result = CUError(@"native");
  else if (!ctx.check || !ctx.check(ctx.guard))
    result = CUError(@"revoked");
  else
    for (size_t i = 0; i < count; i++) {
      CGEventSetFlags(events[i], 0);
      CGEventPost(kCGHIDEventTap, events[i]);
    }
  for (size_t i = 0; i < count; i++)
    if (events[i])
      CFRelease(events[i]);
  return result ?: @{@"done" : @YES};
}
static CGEventRef CUMouse(CGEventType type, CGPoint p, CGMouseButton button,
                          int64_t clicks) {
  CGEventRef event = CGEventCreateMouseEvent(NULL, type, p, button);
  if (event && clicks)
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, clicks);
  return event;
}
static NSDictionary *CUPointer(CUContext *ctx, NSDictionary *r) {
  NSString *action = r[@"action"];
  CUElement *element = nil;
  CGPoint p = CGPointZero;
  if ([action isEqualToString:@"move"]) {
    NSDictionary *error = CUObservedPoint(ctx, r[@"target"], NO, &p);
    if (error)
      return error;
    CGEventRef events[] = {
        CUMouse(kCGEventMouseMoved, p, kCGMouseButtonLeft, 0)};
    return CUPost(ctx, events, 1);
  }
  NSDictionary *target = r[@"target"];
  if ([action isEqualToString:@"right_click"] &&
      [target isKindOfClass:NSDictionary.class] && target[@"native"]) {
    // A control with its own menu action needs no pointer or foreground.
    // The choice is made before input; a failed action is never retried.
    element = ctx.elements[target[@"native"]];
    if (!element || !CUValidate(element))
      return CUError(@"stale_observation");
    CFArrayRef names = NULL;
    BOOL menu = AXUIElementCopyActionNames(element.element, &names) ==
                    kAXErrorSuccess &&
                names &&
                [(__bridge NSArray *)names
                    containsObject:(__bridge NSString *)kAXShowMenuAction];
    if (names)
      CFRelease(names);
    if (menu) {
      if (!ctx.check || !ctx.check(ctx.guard))
        return CUError(@"revoked");
      return AXUIElementPerformAction(element.element, kAXShowMenuAction) ==
                     kAXErrorSuccess
                 ? @{@"done" : @YES}
                 : CUError(@"native");
    }
  }
  NSDictionary *error = CUTarget(ctx, target, &element, &p);
  if (error)
    return error;
  if ([action isEqualToString:@"double_click"]) {
    CGEventRef events[] = {
        CUMouse(kCGEventLeftMouseDown, p, kCGMouseButtonLeft, 1),
        CUMouse(kCGEventLeftMouseUp, p, kCGMouseButtonLeft, 1),
        CUMouse(kCGEventLeftMouseDown, p, kCGMouseButtonLeft, 2),
        CUMouse(kCGEventLeftMouseUp, p, kCGMouseButtonLeft, 2)};
    return CUPost(ctx, events, 4);
  }
  if ([action isEqualToString:@"right_click"]) {
    CGEventRef events[] = {
        CUMouse(kCGEventRightMouseDown, p, kCGMouseButtonRight, 1),
        CUMouse(kCGEventRightMouseUp, p, kCGMouseButtonRight, 1)};
    return CUPost(ctx, events, 2);
  }
  if ([action isEqualToString:@"scroll"]) {
    int32_t amount = MAX(1, MIN(50, [r[@"amount"] intValue]));
    NSString *direction = r[@"direction"];
    int32_t vertical = [direction isEqualToString:@"up"]     ? amount
                       : [direction isEqualToString:@"down"] ? -amount
                                                             : 0;
    int32_t horizontal = [direction isEqualToString:@"left"]    ? amount
                         : [direction isEqualToString:@"right"] ? -amount
                                                                : 0;
    if (!vertical && !horizontal)
      return CUError(@"invalid_request");
    CGEventRef wheel = CGEventCreateScrollWheelEvent(
        NULL, kCGScrollEventUnitLine, 2, vertical, horizontal);
    if (wheel)
      CGEventSetLocation(wheel, p);
    CGEventRef events[] = {
        CUMouse(kCGEventMouseMoved, p, kCGMouseButtonLeft, 0), wheel};
    return CUPost(ctx, events, 2);
  }
  return CUError(@"unsupported");
}
static NSDictionary *CUDrag(CUContext *ctx, NSDictionary *r) {
  CGPoint from = CGPointZero;
  NSDictionary *error = CUObservedPoint(ctx, r, YES, &from);
  if (error)
    return error;
  double x = [r[@"to_x"] doubleValue], y = [r[@"to_y"] doubleValue];
  if (!isfinite(x) || !isfinite(y) || x < 0 || y < 0 ||
      x >= ctx.bounds.size.width || y >= ctx.bounds.size.height)
    return CUError(@"stale_observation");
  CGPoint to = CGPointMake(ctx.bounds.origin.x + x, ctx.bounds.origin.y + y);
  enum { steps = 12 };
  CGEventRef events[steps + 3];
  events[0] = CUMouse(kCGEventMouseMoved, from, kCGMouseButtonLeft, 0);
  events[1] = CUMouse(kCGEventLeftMouseDown, from, kCGMouseButtonLeft, 1);
  for (int i = 1; i <= steps; i++) {
    double t = (double)i / steps;
    CGPoint p = CGPointMake(from.x + (to.x - from.x) * t,
                            from.y + (to.y - from.y) * t);
    events[1 + i] = CUMouse(kCGEventLeftMouseDragged, p, kCGMouseButtonLeft, 1);
  }
  events[steps + 2] = CUMouse(kCGEventLeftMouseUp, to, kCGMouseButtonLeft, 1);
  return CUPost(ctx, events, steps + 3);
}
// The element must still be focused in the foreground app, as for press_key.
static NSDictionary *CUFocused(CUContext *ctx, NSDictionary *r,
                               CUElement **out) {
  CUElement *record = ctx.elements[r[@"native"]];
  if (!record || !CUValidate(record))
    return CUError(@"stale_observation");
  CFTypeRef focused = CUCopy(record.element, kAXFocusedAttribute);
  BOOL isFocused = focused && CFGetTypeID(focused) == CFBooleanGetTypeID() &&
                   CFBooleanGetValue(focused);
  if (focused)
    CFRelease(focused);
  if (!isFocused || !CUFrontmost(record.pid))
    return CUError(@"stale_observation");
  *out = record;
  return nil;
}
static NSDictionary *CUTypeText(CUContext *ctx, NSDictionary *r) {
  CUElement *record = nil;
  NSDictionary *error = CUFocused(ctx, r, &record);
  if (error)
    return error;
  NSString *text = r[@"text"];
  if (![text isKindOfClass:NSString.class] || !text.length ||
      text.length > 16384)
    return CUError(@"invalid_request");
  enum { chunk = 16 };
  for (NSUInteger start = 0; start < text.length;) {
    NSRange range = [text
        rangeOfComposedCharacterSequencesForRange:NSMakeRange(
                                                      start,
                                                      MIN((NSUInteger)chunk,
                                                          text.length -
                                                              start))];
    if (range.length > 2 * chunk)
      return CUError(@"invalid_request");
    unichar buffer[2 * chunk];
    [text getCharacters:buffer range:range];
    CGEventRef events[] = {CGEventCreateKeyboardEvent(NULL, 0, true),
                           CGEventCreateKeyboardEvent(NULL, 0, false)};
    for (int i = 0; i < 2; i++)
      if (events[i])
        CGEventKeyboardSetUnicodeString(events[i], range.length, buffer);
    NSDictionary *posted = CUPost(ctx, events, 2);
    if (posted[@"error"])
      return posted;
    start = NSMaxRange(range);
    usleep(2000);
  }
  return @{@"done" : @YES};
}
static NSDictionary *CUHotkey(CUContext *ctx, NSDictionary *r) {
  CUElement *record = nil;
  NSDictionary *error = CUFocused(ctx, r, &record);
  if (error)
    return error;
  NSDictionary *codes = @{
    @"a" : @0,      @"s" : @1,         @"d" : @2,      @"f" : @3,
    @"h" : @4,      @"g" : @5,         @"z" : @6,      @"x" : @7,
    @"c" : @8,      @"v" : @9,         @"b" : @11,     @"q" : @12,
    @"w" : @13,     @"e" : @14,        @"r" : @15,     @"y" : @16,
    @"t" : @17,     @"1" : @18,        @"2" : @19,     @"3" : @20,
    @"4" : @21,     @"6" : @22,        @"5" : @23,     @"=" : @24,
    @"9" : @25,     @"7" : @26,        @"-" : @27,     @"8" : @28,
    @"0" : @29,     @"]" : @30,        @"o" : @31,     @"u" : @32,
    @"[" : @33,     @"i" : @34,        @"p" : @35,     @"l" : @37,
    @"j" : @38,     @"'" : @39,        @"k" : @40,     @";" : @41,
    @"\\" : @42,    @"," : @43,        @"/" : @44,     @"n" : @45,
    @"m" : @46,     @"." : @47,        @"`" : @50,     @"enter" : @36,
    @"tab" : @48,   @"space" : @49,    @"backspace" : @51,
    @"escape" : @53, @"delete" : @117, @"home" : @115, @"end" : @119,
    @"page_up" : @116, @"page_down" : @121, @"left" : @123, @"right" : @124,
    @"down" : @125, @"up" : @126,      @"f1" : @122,   @"f2" : @120,
    @"f3" : @99,    @"f4" : @118,      @"f5" : @96,    @"f6" : @97,
    @"f7" : @98,    @"f8" : @100,      @"f9" : @101,   @"f10" : @109,
    @"f11" : @103,  @"f12" : @111
  };
  NSNumber *key = [r[@"key"] isKindOfClass:NSString.class] ? codes[r[@"key"]]
                                                           : nil;
  if (!key || ![r[@"modifiers"] isKindOfClass:NSArray.class])
    return CUError(@"unsupported");
  CGEventFlags flags = 0;
  for (NSString *modifier in r[@"modifiers"]) {
    if ([modifier isEqual:@"command"])
      flags |= kCGEventFlagMaskCommand;
    else if ([modifier isEqual:@"control"])
      flags |= kCGEventFlagMaskControl;
    else if ([modifier isEqual:@"option"])
      flags |= kCGEventFlagMaskAlternate;
    else if ([modifier isEqual:@"shift"])
      flags |= kCGEventFlagMaskShift;
    else
      return CUError(@"invalid_request");
  }
  if (!flags)
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
  CGEventSetFlags(down, flags);
  CGEventSetFlags(up, flags);
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
// The AXMenu under a menu bar item or menu item.
static AXUIElementRef CUSubmenu(AXUIElementRef item) {
  CFArrayRef children = NULL;
  AXUIElementRef menu = NULL;
  if (AXUIElementCopyAttributeValues(item, kAXChildrenAttribute, 0, 4,
                                     &children) == kAXErrorSuccess &&
      children && CFGetTypeID(children) == CFArrayGetTypeID())
    for (CFIndex i = 0; i < CFArrayGetCount(children) && !menu; i++) {
      AXUIElementRef child =
          (AXUIElementRef)CFArrayGetValueAtIndex(children, i);
      if (CFGetTypeID(child) == AXUIElementGetTypeID() &&
          [CUString(child, kAXRoleAttribute, 128) isEqual:@"AXMenu"])
        menu = (AXUIElementRef)CFRetain(child);
    }
  if (children)
    CFRelease(children);
  return menu;
}
static NSDictionary *CUInvokeMenu(CUContext *ctx, NSDictionary *r) {
  pid_t pid = [r[@"pid"] intValue];
  NSArray *path = r[@"path"];
  if (pid <= 0 || ![path isKindOfClass:NSArray.class] || !path.count ||
      path.count > 8)
    return CUError(@"invalid_request");
  NSRunningApplication *app =
      [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
  if (!app || app.activationPolicy != NSApplicationActivationPolicyRegular)
    return CUError(@"stale_observation");
  if (CUIsBrowser(pid))
    return CUError(@"unsupported");
  AXUIElementRef application = AXUIElementCreateApplication(pid);
  AXUIElementSetMessagingTimeout(application, 0.3);
  AXUIElementRef current = (AXUIElementRef)CUCopy(application,
                                                  kAXMenuBarAttribute);
  CFRelease(application);
  if (current && CFGetTypeID(current) != AXUIElementGetTypeID()) {
    CFRelease(current);
    current = NULL;
  }
  for (NSUInteger depth = 0; current && depth < path.count; depth++) {
    NSString *title = path[depth];
    if (![title isKindOfClass:NSString.class]) {
      CFRelease(current);
      return CUError(@"invalid_request");
    }
    if (depth > 0) {
      AXUIElementRef menu = CUSubmenu(current);
      CFRelease(current);
      current = menu;
      if (!current)
        break;
    }
    AXUIElementSetMessagingTimeout(current, 0.3);
    CFArrayRef children = NULL;
    AXUIElementRef match = NULL;
    if (AXUIElementCopyAttributeValues(current, kAXChildrenAttribute, 0, 256,
                                       &children) == kAXErrorSuccess &&
        children && CFGetTypeID(children) == CFArrayGetTypeID())
      for (CFIndex i = 0; i < CFArrayGetCount(children) && !match; i++) {
        AXUIElementRef child =
            (AXUIElementRef)CFArrayGetValueAtIndex(children, i);
        if (CFGetTypeID(child) == AXUIElementGetTypeID() &&
            [[CUString(child, kAXTitleAttribute, 256)
                stringByTrimmingCharactersInSet:NSCharacterSet
                                                    .whitespaceCharacterSet]
                caseInsensitiveCompare:
                    [title stringByTrimmingCharactersInSet:
                               NSCharacterSet.whitespaceCharacterSet]] ==
                NSOrderedSame)
          match = (AXUIElementRef)CFRetain(child);
      }
    if (children)
      CFRelease(children);
    CFRelease(current);
    current = match;
  }
  if (!current)
    return CUError(@"stale_observation");
  CFTypeRef enabled = CUCopy(current, kAXEnabledAttribute);
  BOOL isEnabled = enabled && CFGetTypeID(enabled) == CFBooleanGetTypeID() &&
                   CFBooleanGetValue(enabled);
  if (enabled)
    CFRelease(enabled);
  NSDictionary *result = nil;
  if (!isEnabled)
    result = CUError(@"unsupported");
  else if (!ctx.check || !ctx.check(ctx.guard))
    result = CUError(@"revoked");
  else if (AXUIElementPerformAction(current, kAXPressAction) !=
           kAXErrorSuccess)
    result = CUError(@"native");
  CFRelease(current);
  return result ?: @{@"done" : @YES};
}
static NSDictionary *CULaunch(CUContext *ctx, NSDictionary *r) {
  NSString *bundle = r[@"bundle_id"];
  if (![bundle isKindOfClass:NSString.class] || !bundle.length ||
      bundle.length > 255)
    return CUError(@"invalid_request");
  if (CUIsBrowserBundle(bundle))
    return CUError(@"unsupported");
  NSURL *url =
      [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:bundle];
  if (!url)
    return CUError(@"unsupported");
  if (!ctx.check || !ctx.check(ctx.guard))
    return CUError(@"revoked");
  NSWorkspaceOpenConfiguration *configuration =
      [NSWorkspaceOpenConfiguration configuration];
  configuration.activates = YES;
  CUAsync *launch = [CUAsync new];
  [NSWorkspace.sharedWorkspace
      openApplicationAtURL:url
             configuration:configuration
         completionHandler:^(NSRunningApplication *app, NSError *error) {
           launch.value = app && !error ? @(app.processIdentifier) : nil;
           dispatch_semaphore_signal(launch.ready);
         }];
  if (dispatch_semaphore_wait(launch.ready,
                              dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)))
    return CUError(@"timed_out");
  if (!launch.value)
    return CUError(@"native");
  return @{@"data" : @{@"pid" : launch.value, @"bundle_id" : bundle}};
}
static NSDictionary *CUSetFrame(CUContext *ctx, NSDictionary *r) {
  pid_t pid = [r[@"pid"] intValue];
  CGWindowID wid = [r[@"window"] unsignedIntValue];
  CGPoint origin = CGPointMake([r[@"x"] doubleValue], [r[@"y"] doubleValue]);
  CGSize size = CGSizeMake([r[@"width"] doubleValue], [r[@"height"] doubleValue]);
  if (!isfinite(origin.x) || !isfinite(origin.y) || !isfinite(size.width) ||
      !isfinite(size.height) || size.width < 1 || size.height < 1)
    return CUError(@"invalid_request");
  if (CUIsBrowser(pid))
    return CUError(@"unsupported");
  NSDictionary *info = CUWindow(wid, pid);
  if (!info)
    return CUError(@"stale_observation");
  AXUIElementRef window = CUFindWindow(pid, CUBounds(info));
  if (!window)
    return CUError(@"stale_observation");
  Boolean movable = false, sizable = false;
  AXUIElementIsAttributeSettable(window, kAXPositionAttribute, &movable);
  AXUIElementIsAttributeSettable(window, kAXSizeAttribute, &sizable);
  NSDictionary *result = nil;
  AXValueRef position = AXValueCreate(kAXValueCGPointType, &origin),
             dimensions = AXValueCreate(kAXValueCGSizeType, &size);
  if (!movable || !sizable)
    result = CUError(@"unsupported");
  else if (!position || !dimensions)
    result = CUError(@"native");
  else if (!ctx.check || !ctx.check(ctx.guard))
    result = CUError(@"revoked");
  else if (AXUIElementSetAttributeValue(window, kAXPositionAttribute,
                                        position) != kAXErrorSuccess ||
           AXUIElementSetAttributeValue(window, kAXSizeAttribute,
                                        dimensions) != kAXErrorSuccess)
    result = CUError(@"native");
  if (position)
    CFRelease(position);
  if (dimensions)
    CFRelease(dimensions);
  CFRelease(window);
  if (wid == ctx.windowID)
    [ctx.elements removeAllObjects];
  return result ?: @{@"done" : @YES};
}
// The main display without web browsers' windows, in screen points.
static NSDictionary *CUDesktop(void) {
#if CU_SCREEN_KIT && defined(__MAC_OS_X_VERSION_MAX_ALLOWED) &&                \
    __MAC_OS_X_VERSION_MAX_ALLOWED >= 140000
  if (@available(macOS 14.0, *)) {
    if (!CGPreflightScreenCaptureAccess())
      return CUError(@"permission_denied");
    CUAsync *list = [CUAsync new];
    [SCShareableContent
        getShareableContentExcludingDesktopWindows:NO
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
    SCShareableContent *content = list.value;
    SCDisplay *display = nil;
    for (SCDisplay *candidate in content.displays)
      if (candidate.displayID == CGMainDisplayID())
        display = candidate;
    if (!display)
      return CUError(@"native");
    NSMutableArray<SCRunningApplication *> *browsers = [NSMutableArray array];
    for (SCRunningApplication *app in content.applications)
      if (CUIsBrowserBundle(app.bundleIdentifier))
        [browsers addObject:app];
    SCContentFilter *filter =
        [[SCContentFilter alloc] initWithDisplay:display
                           excludingApplications:browsers
                                exceptingWindows:@[]];
    CGRect frame = CGDisplayBounds(display.displayID);
    SCStreamConfiguration *configuration = [SCStreamConfiguration new];
    double scale =
        MIN(1.0, 1600.0 / MAX(frame.size.width, frame.size.height));
    configuration.width = MAX(1, (size_t)(frame.size.width * scale));
    configuration.height = MAX(1, (size_t)(frame.size.height * scale));
    configuration.showsCursor = NO;
    configuration.scalesToFit = YES;
    configuration.preservesAspectRatio = YES;
    CUAsync *capture = [CUAsync new];
    [SCScreenshotManager
        captureImageWithFilter:filter
                 configuration:configuration
             completionHandler:^(CGImageRef image, NSError *error) {
               @try {
                 if (image && !error) {
                   NSData *png = [[[NSBitmapImageRep alloc]
                       initWithCGImage:image]
                       representationUsingType:NSBitmapImageFileTypePNG
                                    properties:@{}];
                   if (!png)
                     capture.value = CUError(@"native");
                   else if (png.length > 2000000)
                     capture.value = CUError(@"too_large");
                   else
                     capture.value = @{
                       @"encoding" : @"png_base64",
                       @"data" : [png base64EncodedStringWithOptions:0],
                       @"width" : @(CGImageGetWidth(image)),
                       @"height" : @(CGImageGetHeight(image)),
                       @"display" : @{
                         @"x" : @(frame.origin.x),
                         @"y" : @(frame.origin.y),
                         @"width" : @(frame.size.width),
                         @"height" : @(frame.size.height)
                       }
                     };
                 }
               } @catch (NSException *__unused exception) {
                 capture.value = CUError(@"native");
               }
               dispatch_semaphore_signal(capture.ready);
             }];
    if (dispatch_semaphore_wait(
            capture.ready, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)))
      return CUError(@"timed_out");
    NSDictionary *image = capture.value ?: CUError(@"native");
    return image[@"error"] ? image : @{@"data" : @{@"screenshot" : image}};
  }
#endif
  return CUError(@"unsupported");
}
static NSDictionary *CUZoom(CUContext *ctx, NSDictionary *r) {
  pid_t pid = [r[@"pid"] intValue];
  CGWindowID wid = [r[@"window"] unsignedIntValue];
  CGRect region = CGRectMake([r[@"x"] doubleValue], [r[@"y"] doubleValue],
                             [r[@"width"] doubleValue],
                             [r[@"height"] doubleValue]);
  if (pid != ctx.pid || wid != ctx.windowID ||
      !CUSame(CUBounds(CUWindow(wid, pid)), ctx.bounds))
    return CUError(@"stale_observation");
  if (!isfinite(region.origin.x) || !isfinite(region.origin.y) ||
      !isfinite(region.size.width) || !isfinite(region.size.height) ||
      region.size.width < 1 || region.size.height < 1 ||
      CGRectGetMaxX(region) > ctx.bounds.size.width + 0.5 ||
      CGRectGetMaxY(region) > ctx.bounds.size.height + 0.5)
    return CUError(@"invalid_request");
  NSDictionary *image = CUCapture(wid, pid, ctx.bounds, region, 2.0);
  if (image[@"error"])
    return image;
  return @{
    @"data" : @{
      @"image" : @{
        @"encoding" : @"png_base64",
        @"data" : image[@"png_base64"],
        @"width" : image[@"width"],
        @"height" : image[@"height"]
      },
      @"region" : @{
        @"x" : @(region.origin.x),
        @"y" : @(region.origin.y),
        @"width" : @(region.size.width),
        @"height" : @(region.size.height)
      },
      @"coordinateSpace" : @"window_points"
    }
  };
}
static NSDictionary *CUExtended(CUContext *ctx, NSDictionary *r) {
  NSString *op = r[@"op"];
  if ([op isEqualToString:@"desktop_screenshot"])
    return CUDesktop();
  if ([op isEqualToString:@"zoom"])
    return CUZoom(ctx, r);
  if (!ctx.check || !ctx.check(ctx.guard))
    return CUError(@"revoked");
  if ([op isEqualToString:@"pointer"])
    return CUPointer(ctx, r);
  if ([op isEqualToString:@"drag"])
    return CUDrag(ctx, r);
  if ([op isEqualToString:@"type_text"])
    return CUTypeText(ctx, r);
  if ([op isEqualToString:@"hotkey"])
    return CUHotkey(ctx, r);
  if ([op isEqualToString:@"invoke_menu"])
    return CUInvokeMenu(ctx, r);
  if ([op isEqualToString:@"launch_app"])
    return CULaunch(ctx, r);
  if ([op isEqualToString:@"set_window_frame"])
    return CUSetFrame(ctx, r);
  return CUError(@"unsupported");
}
static NSDictionary *CUExecute(CUContext *ctx, NSDictionary *r) {
  NSString *op = r[@"op"];
  if ([op isEqualToString:@"invalidate"]) {
    [ctx.elements removeAllObjects];
    ctx.windowID = 0;
    ctx.screenshot = nil;
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
      // AXIsProcessTrusted returns a byte-sized Boolean. Boxing it directly
      // serializes 0/1 as JSON numbers, which the Rust bridge rejects.
      @"ax" : AXIsProcessTrusted() ? @YES : @NO,
      @"screen" : CGPreflightScreenCaptureAccess() ? @YES : @NO
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
  if ([@[
        @"pointer", @"drag", @"type_text", @"hotkey", @"invoke_menu",
        @"launch_app", @"set_window_frame", @"desktop_screenshot", @"zoom"
      ] containsObject:op])
    return CUExtended(ctx, r);
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
