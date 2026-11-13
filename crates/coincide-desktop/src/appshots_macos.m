// Appshots is independent of Computer Use authority. No call here is made by
// construction; hooks exist only between explicit configure/stop calls.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <AudioToolbox/AudioToolbox.h>
#include <unistd.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <QuartzCore/QuartzCore.h>
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
  if(GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(id),NULL,&id)!=noErr || id.signature!='Asht') return eventNotHandledErr;
  atomic_store(&pending,true);
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
  // AXIsProcessTrusted returns a byte-sized Boolean. Box both values as
  // actual JSON booleans so the Rust bridge does not read 1 as false.
  return ASJSON(@{@"screen":CGPreflightScreenCaptureAccess() ? @YES : @NO,@"accessibility":AXIsProcessTrusted() ? @YES : @NO});
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
@property(nonatomic,strong) SCShareableContent *content;
@property(nonatomic) CGImageRef image;
@property(nonatomic,strong) NSString *error;
@property(nonatomic) BOOL cancelled;
@end
@implementation ASCaptureResult
- (void)dealloc { if(_image) CGImageRelease(_image); }
@end
static NSArray *ASFrame(CGRect r) { return @[@(r.origin.x),@(r.origin.y),@(r.size.width),@(r.size.height)]; }
static CGRect ASBounds(NSDictionary *w) {
  CGRect r=CGRectZero; CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds],&r); return r;
}
// Swift's AppshotCaptureGeometry.group: an app can draw one window as several,
// such as Chrome's tab strip and toolbar in a thin window in front of the
// page's. The run of the same app's visible ordinary windows right in front
// of and behind the chosen one that touch it is drawn together, so the
// picture is sized for all of them. `windows` is front to back.
static CGRect ASGroupFrame(NSArray *windows, NSDictionary *chosen) {
  NSMutableArray *pool=[NSMutableArray array];
  for(NSDictionary *w in windows) if([w[(id)kCGWindowLayer] intValue]==0&&[w[(id)kCGWindowAlpha] doubleValue]>0) [pool addObject:w];
  NSUInteger index=[pool indexOfObjectIdenticalTo:chosen];
  // The block reads the frame as the group grows, not a copy of the first.
  __block CGRect frame=ASBounds(chosen);
  if(index==NSNotFound) return frame;
  pid_t pid=[chosen[(id)kCGWindowOwnerPID] intValue];
  BOOL (^joins)(NSDictionary *)=^BOOL(NSDictionary *other) {
    CGRect r=ASBounds(other);
    return [other[(id)kCGWindowOwnerPID] intValue]==pid&&r.size.width>0&&r.size.height>0&&CGRectIntersectsRect(CGRectInset(frame,-1,-1),r);
  };
  for(NSInteger front=(NSInteger)index-1;front>=0&&joins(pool[front]);front--) frame=CGRectUnion(frame,ASBounds(pool[front]));
  for(NSUInteger back=index+1;back<pool.count&&joins(pool[back]);back++) frame=CGRectUnion(frame,ASBounds(pool[back]));
  return frame;
}
// The scale of the display showing most of `frame`, else the nearest one's, as
// AppKit picks a window's backing scale. CoreGraphics only: this runs on the
// owned capture worker, never on the main thread.
static double ASScale(CGRect frame,double fallback) {
  CGDirectDisplayID displays[32];uint32_t count=0;CGGetActiveDisplayList(32,displays,&count);
  double best=-1,nearest=INFINITY,scale=0,nearScale=0;
  for(uint32_t i=0;i<count;i++) {
    CGRect bounds=CGDisplayBounds(displays[i]);
    CGDisplayModeRef mode=CGDisplayCopyDisplayMode(displays[i]);if(!mode)continue;
    double s=CGDisplayModeGetWidth(mode)>0?(double)CGDisplayModeGetPixelWidth(mode)/(double)CGDisplayModeGetWidth(mode):0;
    CGDisplayModeRelease(mode);if(s<=0||CGRectIsEmpty(bounds))continue;
    CGRect overlap=CGRectIntersection(bounds,frame);double area=CGRectIsNull(overlap)?0:overlap.size.width*overlap.size.height;
    if(area>0&&area>best){best=area;scale=s;}
    double dx=MAX(MAX(CGRectGetMinX(bounds)-CGRectGetMaxX(frame),CGRectGetMinX(frame)-CGRectGetMaxX(bounds)),0);
    double dy=MAX(MAX(CGRectGetMinY(bounds)-CGRectGetMaxY(frame),CGRectGetMinY(frame)-CGRectGetMaxY(bounds)),0);
    if(dx*dx+dy*dy<nearest){nearest=dx*dx+dy*dy;nearScale=s;}
  }
  if(scale>0)return MIN(4,scale);if(nearScale>0)return MIN(4,nearScale);
  return fallback>0?MIN(4,fallback):1;
}
// The whole frame in pixels within 8192 on the long edge and 16 MP, keeping
// the aspect: the parts off the display are drawn too.
static CGSize ASPixels(CGRect frame,double scale) {
  double width=MAX(1,frame.size.width*scale),height=MAX(1,frame.size.height*scale);
  double fit=MIN(MIN(1,8192/MAX(width,height)),sqrt(16000000/(width*height)));
  return CGSizeMake(MAX(1,lround(width*fit)),MAX(1,lround(height*fit)));
}
// Waits for one ScreenCaptureKit callback. Apple has no cancellation API, so a
// timeout retains the owned worker until the callback exits; never fake a join.
static BOOL ASWait(dispatch_semaphore_t semaphore,ASCaptureResult *result) {
  if(!dispatch_semaphore_wait(semaphore,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))) return YES;
  @synchronized(result){result.cancelled=YES;}
  dispatch_semaphore_wait(semaphore,DISPATCH_TIME_FOREVER);
  return NO;
}
API_AVAILABLE(macos(14.0))
static CGImageRef ASShot(SCContentFilter *filter,CGSize size,NSString **failure) {
  SCStreamConfiguration *config=[SCStreamConfiguration new];
  config.width=(size_t)size.width;config.height=(size_t)size.height;config.showsCursor=NO;
  config.preservesAspectRatio=YES;config.ignoreShadowsSingleWindow=YES;config.captureResolution=SCCaptureResolutionBest;
  dispatch_semaphore_t semaphore=dispatch_semaphore_create(0);ASCaptureResult *result=[ASCaptureResult new];
  [SCScreenshotManager captureImageWithFilter:filter configuration:config completionHandler:^(CGImageRef image,NSError *error){
    @synchronized(result){if(!result.cancelled){if(image)result.image=CGImageRetain(image);else result.error=error.localizedDescription?:@"Window capture failed";}}
    dispatch_semaphore_signal(semaphore);
  }];
  if(!ASWait(semaphore,result)){*failure=@"Window capture timed out";return NULL;}
  CGImageRef image=NULL;@synchronized(result){if(result.image)image=CGImageRetain(result.image);*failure=result.error;}
  return image;
}
// Swift's AppshotImageTrim: ScreenCaptureKit keeps the window's aspect and
// leaves the rest of a differently shaped picture transparent. The smallest
// rectangle with any visible pixel, from the top left; empty when none is.
static CGRect ASContent(CGImageRef image) {
  size_t width=CGImageGetWidth(image),height=CGImageGetHeight(image);
  if(!width||!height)return CGRectNull;
  CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
  CGContextRef context=CGBitmapContextCreate(NULL,width,height,8,width*4,space,(CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(space);if(!context)return CGRectNull;
  CGContextSetBlendMode(context,kCGBlendModeCopy);CGContextDrawImage(context,CGRectMake(0,0,width,height),image);
  const unsigned char *alpha=CGBitmapContextGetData(context);size_t stride=CGBitmapContextGetBytesPerRow(context);
  size_t top=height,bottom=0,left=width,right=0;
  for(size_t y=0;y<height;y++)for(size_t x=0;x<width;x++)if(alpha[y*stride+x*4+3]){top=MIN(top,y);bottom=MAX(bottom,y);left=MIN(left,x);right=MAX(right,x);}
  CGContextRelease(context);
  if(top==height)return CGRectNull;
  return CGRectMake(left,top,right-left+1,bottom-top+1);
}
static CGImageRef ASTrimmed(CGImageRef image,CGRect content) {
  if(CGRectIsNull(content)||(content.size.width>=CGImageGetWidth(image)&&content.size.height>=CGImageGetHeight(image)))return CGImageRetain(image);
  CGImageRef cropped=CGImageCreateWithImageInRect(image,content);
  return cropped?cropped:CGImageRetain(image);
}
// Swift's refinedFrame: a picture whose content filled only part of it means
// the group was guessed wrong (a window in front of an unrelated one of the
// same app). Capture again at the alternative whose shape the content has.
static BOOL ASRefine(CGSize content,CGSize output,CGRect used,NSArray *alternatives,CGRect *better) {
  if(!(content.width<output.width-2||content.height<output.height-2))return NO;
  double aspect=content.width/MAX(1,content.height);
  double (^mismatch)(CGRect)=^double(CGRect r){return r.size.width>0&&r.size.height>0?fabs(log((r.size.width/r.size.height)/aspect)):INFINITY;};
  BOOL found=NO;CGRect best=CGRectZero;
  for(NSValue *value in alternatives){CGRect r=value.rectValue;if(CGRectEqualToRect(r,used))continue;if(!found||mismatch(r)<mismatch(best)){best=r;found=YES;}}
  if(!found||!(mismatch(best)<mismatch(used)))return NO;
  *better=best;return YES;
}
static BOOL ASSameFrame(CGPoint p,CGSize s,CGRect frame) {
  return fabs(p.x-frame.origin.x)<2&&fabs(p.y-frame.origin.y)<2&&fabs(s.width-frame.size.width)<2&&fabs(s.height-frame.size.height)<2;
}
char *coincide_appshots_capture(bool readText, bool (*allowed)(const void *),const void *guard,unsigned char **bytes,size_t *length) {
  @autoreleasepool {
    *bytes=NULL;*length=0;
    if(!allowed(guard))return ASJSON(@{@"error":@"Capture cancelled"});
    if(!CGPreflightScreenCaptureAccess())return ASJSON(@{@"error":@"Allow Screen Recording in Settings › Appshots",@"refusal":@"screenRecording"});
    pid_t own=getpid(),front=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    NSArray *windows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements,kCGNullWindowID));
    NSDictionary *chosen=nil;
    for(NSDictionary *w in windows) {
      pid_t pid=[w[(id)kCGWindowOwnerPID] intValue];CGRect r=ASBounds(w);
      if(pid==own||(front!=own&&pid!=front)||[w[(id)kCGWindowLayer] intValue]!=0||[w[(id)kCGWindowAlpha] doubleValue]<=0||r.size.width<40||r.size.height<40)continue;
      NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
      if(front==own&&app.activationPolicy!=NSApplicationActivationPolicyRegular)continue;
      // Check intersections using CoreGraphics coordinates without dispatching to
      // the main queue while the owned worker is being cancelled on shutdown.
      CGDirectDisplayID displays[32];uint32_t count=0;CGGetActiveDisplayList(32,displays,&count);BOOL visible=NO;
      for(uint32_t i=0;i<count;i++){CGRect shown=CGRectIntersection(r,CGDisplayBounds(displays[i]));if(shown.size.width>=40&&shown.size.height>=40)visible=YES;}
      if(!visible)continue;chosen=w;break;
    }
    if(!chosen)return ASJSON(@{@"error":@"No window to capture",@"refusal":@"noWindow"});
    pid_t pid=[chosen[(id)kCGWindowOwnerPID] intValue];CGWindowID wid=[chosen[(id)kCGWindowNumber] unsignedIntValue];
    CGRect bounds=ASBounds(chosen),frame=ASGroupFrame(windows,chosen);
    NSString *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid].localizedName?:([chosen[(id)kCGWindowOwnerName] length]?chosen[(id)kCGWindowOwnerName]:@"the app");
    if([chosen[(id)kCGWindowSharingState] intValue]==kCGWindowSharingNone)return ASJSON(@{@"error":[NSString stringWithFormat:@"%@ doesn’t allow capturing this window",app],@"refusal":@"protected",@"app":app,@"frame":ASFrame(frame)});
    if(ASProtected(pid))return ASJSON(@{@"error":[NSString stringWithFormat:@"Skipped: %@ is taking a password",app],@"refusal":@"password",@"app":app,@"frame":ASFrame(frame)});
    if(!isfinite(frame.size.width)||!isfinite(frame.size.height)||frame.size.width>32768||frame.size.height>32768)return ASJSON(@{@"error":@"Window geometry exceeds capture limits",@"frame":ASFrame(frame)});
    NSString *title=chosen[(id)kCGWindowName]?:@"";
    NSMutableString *text=[NSMutableString string];
    if(readText&&AXIsProcessTrusted()) {
      AXUIElementRef ax=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(ax,0.2);
      AXUIElementRef win=(AXUIElementRef)ASCopy(ax,kAXFocusedWindowAttribute);CFRelease(ax);
      if(win) {CFTypeRef position=ASCopy(win,kAXPositionAttribute),size=ASCopy(win,kAXSizeAttribute);CGPoint p;CGSize s;
        // The text is read across the whole group, as Swift does: Chrome's
        // focused window is the page's, not the toolbar strip in front of it.
        if(position&&size&&CFGetTypeID(position)==AXValueGetTypeID()&&CFGetTypeID(size)==AXValueGetTypeID()&&AXValueGetValue(position,kAXValueCGPointType,&p)&&AXValueGetValue(size,kAXValueCGSizeType,&s)&&(ASSameFrame(p,s,frame)||ASSameFrame(p,s,bounds))){NSUInteger visited=0;ASText(win,text,&visited,0,NSProcessInfo.processInfo.systemUptime+2);}
        if(position)CFRelease(position);if(size)CFRelease(size);CFRelease(win);
      }
    }
    if(!allowed(guard)||ASProtected(pid))return ASJSON(@{@"error":@"Capture cancelled or password input started",@"frame":ASFrame(frame)});
    if(@available(macOS 14.0,*)) {
      dispatch_semaphore_t semaphore=dispatch_semaphore_create(0);ASCaptureResult *listed=[ASCaptureResult new];
      [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES completionHandler:^(SCShareableContent *content,NSError *error){
        @synchronized(listed){if(!listed.cancelled){if(content)listed.content=content;else listed.error=error.localizedDescription?:@"Window capture failed";}}
        dispatch_semaphore_signal(semaphore);
      }];
      if(!ASWait(semaphore,listed))return ASJSON(@{@"error":@"Window capture timed out",@"frame":ASFrame(frame)});
      SCShareableContent *content;NSString *failure;@synchronized(listed){content=listed.content;failure=listed.error;}
      if(!content)return ASJSON(@{@"error":failure?:@"Window capture failed",@"frame":ASFrame(frame)});
      SCWindow *window=nil;for(SCWindow *w in content.windows)if(w.windowID==wid&&w.owningApplication.processID==pid){window=w;break;}
      if(!window)return ASJSON(@{@"error":@"The window closed before Coincide could capture it.",@"frame":ASFrame(frame)});
      SCContentFilter *filter=[[SCContentFilter alloc] initWithDesktopIndependentWindow:window];
      double scale=ASScale(frame,filter.pointPixelScale);
      CGSize output=ASPixels(frame,scale);
      CGImageRef shot=ASShot(filter,output,&failure);
      if(!shot)return ASJSON(@{@"error":failure?:@"Window capture failed",@"frame":ASFrame(frame)});
      CGRect drawn=ASContent(shot);CGImageRef image=ASTrimmed(shot,drawn);CGImageRelease(shot);
      CGRect better;
      if(!CGRectIsNull(drawn)&&ASRefine(drawn.size,output,frame,@[[NSValue valueWithRect:NSRectFromCGRect(bounds)],[NSValue valueWithRect:NSRectFromCGRect(window.frame)]],&better)&&allowed(guard)) {
        CGImageRef again=ASShot(filter,ASPixels(better,scale),&failure);
        if(again){CGImageRelease(image);image=ASTrimmed(again,ASContent(again));CGImageRelease(again);}
      }
      if(!allowed(guard)||ASProtected(pid)){CGImageRelease(image);return ASJSON(@{@"error":@"Capture cancelled or password input started",@"frame":ASFrame(frame)});}
      NSBitmapImageRep *rep=[[NSBitmapImageRep alloc]initWithCGImage:image];CGImageRelease(image);
      NSData *png=[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
      if(!png||png.length>20*1024*1024)return ASJSON(@{@"error":png?@"Captured image exceeds 20 MiB":@"Window capture failed",@"frame":ASFrame(frame)});
      *bytes=malloc(png.length);if(!*bytes)return ASJSON(@{@"error":@"Capture allocation failed"});memcpy(*bytes,png.bytes,png.length);*length=png.length;
      return ASJSON(@{@"app":app,@"title":title,@"text":text,@"frame":ASFrame(frame)});
    }
    return ASJSON(@{@"error":@"Window-only Appshots requires macOS 14 or later"});
  }
}
// Swift's AppForegrounder: show Coincide when hidden (⌘H), bring its main
// window out of the Dock and forward (which moves to its Space), and ask macOS
// to activate. macOS 14 may turn down a request that didn't follow input to
// Coincide, such as both ⌘ keys reaching the app in front, so after 250 ms
// Coincide insists, as macOS still allows for an app the user summoned.
static unsigned long foregroundGeneration;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
void coincide_appshots_bring_forward(void *view) {
  if(!NSThread.isMainThread)return;
  NSWindow *window=view?((__bridge NSView *)view).window:nil;
  unsigned long generation=++foregroundGeneration;
  if(NSApp.isHidden)[NSApp unhideWithoutActivation];
  if(window){if(window.isMiniaturized)[window deminiaturize:nil];[window makeKeyAndOrderFront:nil];}
  if(NSApp.isActive)return;
  if(@available(macOS 14.0,*))[NSApp activate];else [NSApp activateIgnoringOtherApps:YES];
  __weak NSWindow *weakWindow=window;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
    if(generation!=foregroundGeneration||NSApp.isActive)return;
    [NSApp activateIgnoringOtherApps:YES];
    [weakWindow makeKeyAndOrderFront:nil];
  });
}
#pragma clang diagnostic pop
// Swift's AppshotHUD: a small dark panel in the lower part of the display
// around the captured window, like the volume HUD. It takes no clicks, never
// becomes key, fades unless Reduce Motion is on, and VoiceOver reads it.
// `frame` is in window-server points (top left of the main display), or NULL.
static NSPanel *hudPanel;
static unsigned long hudGeneration;
static NSScreen *ASScreenAround(const double *frame) {
  NSScreen *main=NSScreen.screens.firstObject;
  if(!frame||!main)return NSScreen.mainScreen;
  NSRect flipped=NSMakeRect(frame[0],NSMaxY(main.frame)-frame[1]-frame[3],frame[2],frame[3]);
  NSScreen *best=nil;double area=-1;
  for(NSScreen *screen in NSScreen.screens){NSRect overlap=NSIntersectionRect(screen.frame,flipped);double a=overlap.size.width*overlap.size.height;if(a>area){area=a;best=screen;}}
  return best?:NSScreen.mainScreen;
}
void coincide_appshots_hud(const char *message,const char *symbol,bool alert,const double *frame) {
  if(!NSThread.isMainThread||!message)return;
  NSString *text=[NSString stringWithUTF8String:message]?:@"";
  NSString *symbolName=symbol?[NSString stringWithUTF8String:symbol]:nil;
  unsigned long generation=++hudGeneration;
  if(alert)NSBeep();
  if(!hudPanel) {
    hudPanel=[[NSPanel alloc]initWithContentRect:NSMakeRect(0,0,240,48) styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:YES];
    hudPanel.opaque=NO;hudPanel.backgroundColor=NSColor.clearColor;hudPanel.hasShadow=YES;hudPanel.level=NSStatusWindowLevel;
    hudPanel.ignoresMouseEvents=YES;hudPanel.releasedWhenClosed=NO;hudPanel.hidesOnDeactivate=NO;
    hudPanel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary|NSWindowCollectionBehaviorTransient|NSWindowCollectionBehaviorIgnoresCycle;
  }
  NSVisualEffectView *background=[NSVisualEffectView new];
  background.material=NSVisualEffectMaterialHUDWindow;background.blendingMode=NSVisualEffectBlendingModeBehindWindow;background.state=NSVisualEffectStateActive;
  background.wantsLayer=YES;background.layer.cornerRadius=14;background.layer.masksToBounds=YES;
  NSImageView *icon=[NSImageView imageViewWithImage:(symbolName?[NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil]:nil)?:[NSImage new]];
  icon.symbolConfiguration=[NSImageSymbolConfiguration configurationWithPointSize:17 weight:NSFontWeightMedium];
  icon.contentTintColor=NSColor.labelColor;
  NSTextField *label=[NSTextField labelWithString:text];
  label.font=[NSFont systemFontOfSize:13 weight:NSFontWeightMedium];label.textColor=NSColor.labelColor;
  label.lineBreakMode=NSLineBreakByTruncatingTail;label.maximumNumberOfLines=2;label.preferredMaxLayoutWidth=360;
  NSStackView *stack=[NSStackView stackViewWithViews:@[icon,label]];
  stack.orientation=NSUserInterfaceLayoutOrientationHorizontal;stack.spacing=9;stack.edgeInsets=NSEdgeInsetsMake(12,16,12,18);
  stack.translatesAutoresizingMaskIntoConstraints=NO;[background addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:background.leadingAnchor],[stack.trailingAnchor constraintEqualToAnchor:background.trailingAnchor],[stack.topAnchor constraintEqualToAnchor:background.topAnchor],[stack.bottomAnchor constraintEqualToAnchor:background.bottomAnchor]]];
  hudPanel.contentView=background;
  NSSize size=background.fittingSize;if(size.width<1||size.height<1)size=NSMakeSize(240,48);
  NSScreen *screen=ASScreenAround(frame);
  NSRect visible=screen?screen.visibleFrame:NSMakeRect(0,0,1440,900);
  [hudPanel setFrame:NSMakeRect(NSMidX(visible)-size.width/2,NSMinY(visible)+visible.size.height*0.18,size.width,size.height) display:NO];
  BOOL reduceMotion=NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
  hudPanel.alphaValue=reduceMotion?1:0;
  [hudPanel orderFrontRegardless];
  if(!reduceMotion)[NSAnimationContext runAnimationGroup:^(NSAnimationContext *context){context.duration=0.12;hudPanel.animator.alphaValue=1;}];
  NSAccessibilityPostNotificationWithUserInfo(NSApp,NSAccessibilityAnnouncementRequestedNotification,@{NSAccessibilityAnnouncementKey:text,NSAccessibilityPriorityKey:@(NSAccessibilityPriorityHigh)});
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,1400*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
    if(generation!=hudGeneration)return;
    if(NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion){[hudPanel orderOut:nil];return;}
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context){context.duration=0.25;hudPanel.animator.alphaValue=0;} completionHandler:^{
      if(generation==hudGeneration&&hudPanel.alphaValue==0)[hudPanel orderOut:nil];
    }];
  });
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
