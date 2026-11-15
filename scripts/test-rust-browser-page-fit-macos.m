// A private, windowless WKWebView fixture. No user profiles or websites.
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

@interface FitProbe : NSObject <WKScriptMessageHandler>
@property(nonatomic, strong) WKWebView *view;
@property(nonatomic, strong) NSString *baseURL;
@property(nonatomic, strong) NSString *expectedLanguage;
@property(nonatomic, strong) NSString *activeDocument;
@property(nonatomic, assign) NSInteger index;
@property(nonatomic, assign) BOOL busy;
@end

@implementation FitProbe
- (void)fail:(NSString *)reason {
  fprintf(stderr, "FAIL: %s\n", reason.UTF8String);
  fflush(stderr);
  exit(2);
}
- (void)loadFixture {
  self.busy = NO;
  NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/?fixture=%ld", self.baseURL, (long)self.index]];
  [self.view loadRequest:[NSURLRequest requestWithURL:url]];
}
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
  if (self.busy || ![message.body isKindOfClass:[NSString class]]) return;
  NSData *data = [(NSString *)message.body dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *sample = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![sample[@"kind"] isEqual:@"coincide-page-width-v1"]) return;
  NSString *document = sample[@"document"];
  double viewport = [sample[@"viewport"] doubleValue], content = [sample[@"content"] doubleValue];
  if (fabs(viewport - 550 / self.view.pageZoom) > 10 || ![sample[@"held"] boolValue]) return;
  self.busy = YES;
  if (![self.activeDocument isEqual:document] && fabs(self.view.pageZoom - 1.0) > 0.001) {
    self.view.pageZoom = 1.0;
    NSString *script = [NSString stringWithFormat:@"window.__coincidePageFitV1.measure('%@')", document];
    [self.view evaluateJavaScript:script completionHandler:^(id value, NSError *error) {
      if (error) [self fail:@"remeasuring the hidden page failed"];
      self.busy = NO;
    }];
    return;
  }
  self.activeDocument = document;
  self.view.pageZoom = MIN(1.0, MAX(0.1, 550.0 / content));
  NSString *script = [NSString stringWithFormat:@"window.__coincidePageFitV1.reveal('%@', %.8f)", document, 550.0 / self.view.pageZoom];
  [self.view evaluateJavaScript:script completionHandler:^(id value, NSError *error) {
    if (error) [self fail:@"revealing the fitted page failed"];
    [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:NO block:^(NSTimer *timer) {
      NSString *inspect = @"JSON.stringify({first:window.firstVisibility,now:getComputedStyle(document.documentElement).visibility,inner:window.innerWidth,content:document.documentElement.scrollWidth,language:navigator.language,header:window.headerLanguage})";
      [self.view evaluateJavaScript:inspect completionHandler:^(id result, NSError *err) {
        if (err) [self fail:@"inspecting the page failed"];
        NSDictionary *out = [NSJSONSerialization JSONObjectWithData:[(NSString *)result dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (![out[@"first"] isEqual:@"hidden"] || ![out[@"now"] isEqual:@"visible"])
          [self fail:[NSString stringWithFormat:@"unexpected visibility on fixture %ld: %@", (long)self.index, out]];
        if ([out[@"content"] doubleValue] > [out[@"inner"] doubleValue] + 4)
          [self fail:[NSString stringWithFormat:@"fixture %ld remains wider than its viewport", (long)self.index]];
        if (![out[@"language"] isEqual:self.expectedLanguage] ||
            ![out[@"header"] hasPrefix:self.expectedLanguage])
          [self fail:[NSString stringWithFormat:@"WebKit did not follow the preferred language: %@", out]];
        printf("fixture %ld: hidden first, fitted and visible; language %s\n", (long)self.index, [out[@"language"] UTF8String]);
        fflush(stdout);
        ++self.index;
        if (self.index == 3) {
          self.busy = NO;
          [self.view goBack];
        } else if (self.index == 4) {
          exit(0);
        } else {
          [self loadFixture];
        }
      }];
    }];
  }];
}
@end

int main(int argc, const char *argv[]) {
  if (argc < 4) return 3;
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSString *source = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[1]] encoding:NSUTF8StringEncoding error:nil];
    if (!source) return 3;
    FitProbe *probe = [FitProbe new];
    probe.baseURL = [NSString stringWithUTF8String:argv[2]];
    probe.expectedLanguage = [NSString stringWithUTF8String:argv[3]];
    WKWebViewConfiguration *config = [WKWebViewConfiguration new];
    config.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    [config.userContentController addScriptMessageHandler:probe name:@"fit"];
    WKUserScript *shim = [[WKUserScript alloc] initWithSource:@"window.ipc={postMessage:(s)=>window.webkit.messageHandlers.fit.postMessage(s)};" injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES];
    WKUserScript *fit = [[WKUserScript alloc] initWithSource:source injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES];
    [config.userContentController addUserScript:shim];
    [config.userContentController addUserScript:fit];
    probe.view = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 550, 600) configuration:config];
    [probe loadFixture];
    [NSTimer scheduledTimerWithTimeInterval:25 repeats:NO block:^(NSTimer *timer) { [probe fail:@"timed out"]; }];
    [NSApp run];
  }
  return 0;
}
