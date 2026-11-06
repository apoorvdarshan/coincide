// Appshots is independent of Computer Use authority. No call here is made by
// construction; hooks exist only between explicit configure/stop calls.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <AudioToolbox/AudioToolbox.h>
#include <unistd.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

static id globalMonitor, localMonitor;
static EventHotKeyRef hotkey;
static EventHandlerRef handler;
static atomic_bool pending;
static BOOL fired, blocked;
static NSTimeInterval firstModifier;
static char *ASJSON(NSDictionary *value) {
  NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
  if(!data) return strdup("{\"error\":\"Invalid native result\"}");
  char *out=malloc(data.length+1); if(!out) return NULL;
  memcpy(out,data.bytes,data.length); out[data.length]=0; return out;
}
static OSStatus ASHotKey(EventHandlerCallRef next, EventRef event, void *context) {
  (void)next;(void)context; EventHotKeyID id={0};
  if(GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(id),NULL,&id)==noErr && id.signature=='Asht') atomic_store(&pending,true);
  return noErr;
}
static void ASFlags(NSEvent *event) {
  if(event.type==NSEventTypeKeyDown) { blocked=YES; return; }
  // NX_DEVICELCMDKEYMASK/NX_DEVICERCMDKEYMASK: public device flags in IOLLEvent.h.
  BOOL left=(event.modifierFlags & 0x00000008)!=0;
  BOOL right=(event.modifierFlags & 0x00000010)!=0;
  if(!left&&!right) { fired=NO;blocked=NO;firstModifier=0;return; }
  if(!firstModifier) firstModifier=event.timestamp;
  NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
  double since=CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState,kCGEventKeyDown);
  if(isfinite(since)&&now-since>=firstModifier) blocked=YES;
  NSUInteger other=event.modifierFlags & (NSEventModifierFlagControl|NSEventModifierFlagOption|NSEventModifierFlagShift);
  if(left&&right&&!fired&&!blocked&&!other) { fired=YES;atomic_store(&pending,true); }
}
void coincide_appshots_stop(void) {
  if(globalMonitor) [NSEvent removeMonitor:globalMonitor];
  if(localMonitor) [NSEvent removeMonitor:localMonitor];
  globalMonitor=nil;localMonitor=nil;
  if(hotkey) UnregisterEventHotKey(hotkey);hotkey=NULL;
  if(handler) RemoveEventHandler(handler);handler=NULL;
  fired=NO;blocked=NO;firstModifier=0;atomic_store(&pending,false);
}
char *coincide_appshots_configure(const char *shortcut) {
  coincide_appshots_stop();
  if(!NSThread.isMainThread) return ASJSON(@{@"error":@"Appshots hooks require the main thread"});
  if(!shortcut) {
    if(!AXIsProcessTrusted()) return ASJSON(@{@"error":@"Waiting for Accessibility access"});
    globalMonitor=[NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged handler:^(NSEvent *e){ASFlags(e);}];
    localMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged|NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e){ASFlags(e);return e;}];
    if(!globalMonitor||!localMonitor) {coincide_appshots_stop();return ASJSON(@{@"error":@"Modifier monitor could not be installed"});}
  } else {
    NSString *text=[NSString stringWithUTF8String:shortcut];
    NSArray *parts=[text componentsSeparatedByString:@"+"]; NSString *key=parts.lastObject;
    // Physical codes corresponding to the Swift recorder's supported keys.
    NSDictionary *codes=@{@"a":@0,@"s":@1,@"d":@2,@"f":@3,@"h":@4,@"g":@5,@"z":@6,@"x":@7,@"c":@8,@"v":@9,@"b":@11,@"q":@12,@"w":@13,@"e":@14,@"r":@15,@"y":@16,@"t":@17,@"1":@18,@"2":@19,@"3":@20,@"4":@21,@"6":@22,@"5":@23,@"9":@25,@"7":@26,@"8":@28,@"0":@29,@"o":@31,@"u":@32,@"i":@34,@"p":@35,@"l":@37,@"j":@38,@"k":@40,@"n":@45,@"m":@46};
    NSNumber *code=codes[key]; if(!code)return ASJSON(@{@"error":@"Record a supported shortcut"});
    UInt32 mods=0; if([parts containsObject:@"mod"])mods|=cmdKey;
    if([parts containsObject:@"ctrl"])mods|=controlKey;
    if([parts containsObject:@"alt"])mods|=optionKey;
    if([parts containsObject:@"shift"])mods|=shiftKey;
    EventTypeSpec type={kEventClassKeyboard,kEventHotKeyPressed};
    if(InstallEventHandler(GetApplicationEventTarget(),ASHotKey,1,&type,NULL,&handler)!=noErr || RegisterEventHotKey(code.unsignedIntValue,mods,(EventHotKeyID){'Asht',1},GetApplicationEventTarget(),0,&hotkey)!=noErr) {
      coincide_appshots_stop();return ASJSON(@{@"error":@"Shortcut is in use by another app"});
    }
  }
  return ASJSON(@{@"ready":@YES});
}
bool coincide_appshots_triggered(void) {return atomic_exchange(&pending,false);}
char *coincide_appshots_permissions(int action) {
  if(action==1) CGRequestScreenCaptureAccess();
  if(action==2) AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{@"AXTrustedCheckOptionPrompt":@YES});
  return ASJSON(@{@"screen":@(CGPreflightScreenCaptureAccess()),@"accessibility":@(AXIsProcessTrusted())});
}
static CFTypeRef ASCopy(AXUIElementRef element,CFStringRef key) {
  CFTypeRef out=NULL; if(AXUIElementCopyAttributeValue(element,key,&out)!=kAXErrorSuccess) {if(out)CFRelease(out);return NULL;}return out;
}
static BOOL ASProtected(pid_t pid) {
  if(IsSecureEventInputEnabled())return YES;
  if(!AXIsProcessTrusted())return NO;
  AXUIElementRef app=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(app,0.3);
  AXUIElementRef focus=(AXUIElementRef)ASCopy(app,kAXFocusedUIElementAttribute);CFRelease(app);
  if(!focus)return NO;
  CFTypeRef subrole=ASCopy(focus,kAXSubroleAttribute);CFRelease(focus);
  BOOL secure=subrole&&CFGetTypeID(subrole)==CFStringGetTypeID()&&CFEqual(subrole,kAXSecureTextFieldSubrole);
  if(subrole)CFRelease(subrole);return secure;
}
static void ASText(AXUIElementRef element,NSMutableString *text,NSUInteger *visited,int depth,NSTimeInterval deadline) {
  if(depth>16||++*visited>2000||text.length>=8000||NSProcessInfo.processInfo.systemUptime>=deadline)return;
  CFTypeRef role=ASCopy(element,kAXSubroleAttribute);
  BOOL secure=role&&CFGetTypeID(role)==CFStringGetTypeID()&&CFEqual(role,kAXSecureTextFieldSubrole);if(role)CFRelease(role);
  if(secure)return;
  for(id attribute in @[(id)kAXTitleAttribute,(id)kAXValueAttribute,(id)kAXDescriptionAttribute]) {
    CFTypeRef value=ASCopy(element,(__bridge CFStringRef)attribute);
    if(value&&CFGetTypeID(value)==CFStringGetTypeID()) {
      NSString *s=(__bridge NSString *)value;
      if(s.length) [text appendFormat:@"%@\n",[s substringToIndex:MIN(s.length,8000-text.length)]];
    }
    if(value)CFRelease(value);if(text.length>=8000)return;
  }
  CFTypeRef children=ASCopy(element,kAXChildrenAttribute);
  if(children&&CFGetTypeID(children)==CFArrayGetTypeID())for(id child in (__bridge NSArray *)children) ASText((__bridge AXUIElementRef)child,text,visited,depth+1,deadline);
  if(children)CFRelease(children);
}
@interface ASCaptureResult : NSObject
@property(nonatomic,strong) NSData *png;
@property(nonatomic,strong) NSString *error;
@property(nonatomic) BOOL cancelled;
@end
@implementation ASCaptureResult
@end
char *coincide_appshots_capture(bool readText, bool (*allowed)(const void *),const void *guard,unsigned char **bytes,size_t *length) {
  @autoreleasepool {
    *bytes=NULL;*length=0;
    if(!allowed(guard))return ASJSON(@{@"error":@"Capture cancelled"});
    if(!CGPreflightScreenCaptureAccess())return ASJSON(@{@"error":@"Waiting for Screen Recording access"});
    pid_t own=getpid(),front=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    NSArray *windows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements,kCGNullWindowID));
    NSDictionary *chosen=nil;
    for(NSDictionary *w in windows) {
      pid_t pid=[w[(id)kCGWindowOwnerPID] intValue];CGRect r=CGRectZero;
      CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds],&r);
      if(pid==own||(front!=own&&pid!=front)||[w[(id)kCGWindowLayer] intValue]!=0||[w[(id)kCGWindowAlpha] doubleValue]<=0||r.size.width<40||r.size.height<40)continue;
      NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
      if(front==own&&app.activationPolicy!=NSApplicationActivationPolicyRegular)continue;
      // Check intersections using CoreGraphics coordinates without dispatching to
      // the main queue while the owned worker is being cancelled on shutdown.
      CGDirectDisplayID displays[32];uint32_t count=0;CGGetActiveDisplayList(32,displays,&count);BOOL visible=NO;
      for(uint32_t i=0;i<count;i++){CGRect shown=CGRectIntersection(r,CGDisplayBounds(displays[i]));if(shown.size.width>=40&&shown.size.height>=40)visible=YES;}
      if(!visible)continue;chosen=w;break;
    }
    if(!chosen)return ASJSON(@{@"error":@"No window to capture"});
    pid_t pid=[chosen[(id)kCGWindowOwnerPID] intValue];CGWindowID wid=[chosen[(id)kCGWindowNumber] unsignedIntValue];
    if([chosen[(id)kCGWindowSharingState] intValue]==kCGWindowSharingNone)return ASJSON(@{@"error":@"The frontmost window does not allow capture"});
    if(ASProtected(pid))return ASJSON(@{@"error":@"Skipped: the frontmost app is taking a password"});
    CGRect frame=CGRectZero;CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)chosen[(id)kCGWindowBounds],&frame);
    if(!isfinite(frame.size.width)||!isfinite(frame.size.height)||frame.size.width>32768||frame.size.height>32768)return ASJSON(@{@"error":@"Window geometry exceeds capture limits"});
    NSString *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid].localizedName?:@"the app";
    NSString *title=chosen[(id)kCGWindowName]?:@"";
    NSMutableString *text=[NSMutableString string];
    if(readText&&AXIsProcessTrusted()) {
      AXUIElementRef ax=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(ax,0.2);
      AXUIElementRef win=(AXUIElementRef)ASCopy(ax,kAXFocusedWindowAttribute);CFRelease(ax);
      if(win) {CFTypeRef position=ASCopy(win,kAXPositionAttribute),size=ASCopy(win,kAXSizeAttribute);CGPoint p;CGSize s;
        if(position&&size&&CFGetTypeID(position)==AXValueGetTypeID()&&CFGetTypeID(size)==AXValueGetTypeID()&&AXValueGetValue(position,kAXValueCGPointType,&p)&&AXValueGetValue(size,kAXValueCGSizeType,&s)&&fabs(p.x-frame.origin.x)<2&&fabs(p.y-frame.origin.y)<2&&fabs(s.width-frame.size.width)<2&&fabs(s.height-frame.size.height)<2){NSUInteger visited=0;ASText(win,text,&visited,0,NSProcessInfo.processInfo.systemUptime+2);}
        if(position)CFRelease(position);if(size)CFRelease(size);CFRelease(win);
      }
    }
    if(!allowed(guard)||ASProtected(pid))return ASJSON(@{@"error":@"Capture cancelled or password input started"});
    if(@available(macOS 14.0,*)) {
      dispatch_semaphore_t semaphore=dispatch_semaphore_create(0);ASCaptureResult *result=[ASCaptureResult new];
      [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES completionHandler:^(SCShareableContent *content,NSError *error){
        if(error){@synchronized(result){result.error=error.localizedDescription;}dispatch_semaphore_signal(semaphore);return;}
        @synchronized(result){if(result.cancelled){dispatch_semaphore_signal(semaphore);return;}}
        SCWindow *window=nil;for(SCWindow *w in content.windows)if(w.windowID==wid&&w.owningApplication.processID==pid){window=w;break;}
        if(!window){@synchronized(result){result.error=@"The selected window closed";}dispatch_semaphore_signal(semaphore);return;}
        SCContentFilter *filter=[[SCContentFilter alloc] initWithDesktopIndependentWindow:window];
        SCStreamConfiguration *config=[SCStreamConfiguration new];
        double scale=MAX(1,MIN(4,filter.pointPixelScale));double width=MAX(1,filter.contentRect.size.width*scale),height=MAX(1,filter.contentRect.size.height*scale);double fit=MIN(MIN(1,8192/MAX(width,height)),sqrt(16000000/(width*height)));
        config.width=MAX(1,lround(width*fit));config.height=MAX(1,lround(height*fit));config.showsCursor=NO;
        [SCScreenshotManager captureImageWithFilter:filter configuration:config completionHandler:^(CGImageRef image,NSError *captureError){
          @synchronized(result){if(image){NSBitmapImageRep *rep=[[NSBitmapImageRep alloc]initWithCGImage:image];result.png=[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];}else result.error=captureError.localizedDescription?:@"Window capture failed";}
          dispatch_semaphore_signal(semaphore);
        }];
      }];
      if(dispatch_semaphore_wait(semaphore,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))) {
        @synchronized(result){result.cancelled=YES;}
        // Apple has no cancellation API for a one-shot screenshot. Retain the
        // owned worker until its completion callback exits; never fake a join.
        dispatch_semaphore_wait(semaphore,DISPATCH_TIME_FOREVER);
        return ASJSON(@{@"error":@"Window capture timed out"});
      }
      if(!allowed(guard)||ASProtected(pid))return ASJSON(@{@"error":@"Capture cancelled or password input started"});
      NSData *png;NSString *failure;@synchronized(result){png=result.png;failure=result.error;}
      if(!png||png.length>20*1024*1024)return ASJSON(@{@"error":failure?:@"Captured image exceeds 20 MiB"});
      *bytes=malloc(png.length);if(!*bytes)return ASJSON(@{@"error":@"Capture allocation failed"});memcpy(*bytes,png.bytes,png.length);*length=png.length;
      return ASJSON(@{@"app":app,@"title":title,@"text":text});
    }
    return ASJSON(@{@"error":@"Window-only Appshots requires macOS 14 or later"});
  }
}
void coincide_appshots_sound(void) {
  static SystemSoundID sound=0;
  if(!sound)for(NSString *name in @[@"Screen Capture.aif",@"Grab.aif",@"Shutter.aif"]) {
    NSString *path=[@"/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/" stringByAppendingString:name];
    if([[NSFileManager defaultManager]fileExistsAtPath:path]&&AudioServicesCreateSystemSoundID((__bridge CFURLRef)[NSURL fileURLWithPath:path],&sound)==noErr)break;
  }
  if(sound)AudioServicesPlaySystemSound(sound);
}
void coincide_appshots_free(void *pointer) {free(pointer);}
