// Native, synthetic test for the usage popover. It never opens an app window
// or reads the user's accounts. Run: xcrun clang -fobjc-arc -fblocks -framework
// AppKit -framework QuartzCore scripts/test-rust-usage-menubar-macos.m -o /tmp/usage-menu-test && /tmp/usage-menu-test
#import <AppKit/AppKit.h>
#import "../crates/coincide-desktop/src/usage_menubar_macos.m"

static void Require(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static NSDictionary *NextEvent(void) {
    char *event = coincide_usage_status_next_event();
    Require(event != NULL, @"Expected a menu action");
    NSData *data = [NSData dataWithBytes:event length:strlen(event)];
    free(event);
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}
static void SetFixture(NSUInteger accountCount, NSString *appearance) {
    NSMutableArray *accounts = [NSMutableArray new];
    for (NSUInteger i = 0; i < accountCount; i++) {
        [accounts addObject:@{
            @"provider": @"codex",
            @"title": @"An account name long enough to need truncation in the menu",
            @"plan": @"Pro", @"checked": @"Checked just now",
            @"rows": @[@{@"title":@"Weekly", @"value":@"77% used", @"fill":@0.77,
                         @"detail":@"Resets in 3 days and 15 hours · Thursday 7:45 PM · Ahead of pace"}]
        }];
    }
    NSDictionary *fixture = @{
        @"mode": @"used", @"updated": @"just now", @"appearance": appearance,
        @"overviewNote": @"Local history may be incomplete",
        @"themes": @{@"dark":@{@"surface":@0x18241D, @"ink":@0xD4E2D8, @"accent":@0x6FD08C},
                     @"light":@{@"surface":@0xFBF6EC, @"ink":@0x211B12, @"accent":@0xC26A2E}},
        @"periods": @[@{@"label":@"Today", @"tokens":@"2.3M", @"cost":@"—"},
                       @{@"label":@"7 days", @"tokens":@"210M", @"cost":@"—"},
                       @{@"label":@"30 days", @"tokens":@"1.35B", @"cost":@"—"}],
        @"accounts":accounts, @"empty":@(accountCount == 0),
        @"primaryOptions":@[@{@"title":@"Auto (last active agent)", @"value":@"auto"}],
        @"primary":@"auto", @"secondaryOptions":@[@{@"title":@"None", @"value":NSNull.null}],
        @"secondary":NSNull.null, @"refresh":@"automatic"
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:fixture options:0 error:nil];
    NSString *text = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    coincide_usage_status_update(text.UTF8String);
    [usageStatus updatePanel];
    [usageStatus.panel.contentView layoutSubtreeIfNeeded];
}
static void CheckLayout(void) {
    NSView *background = usageStatus.panel.contentView;
    NSStackView *content = (NSStackView *)background.subviews.firstObject;
    Require([content isKindOfClass:NSStackView.class], @"Missing popover content");
    for (NSView *view in content.arrangedSubviews) {
        NSRect frame = [content convertRect:view.bounds fromView:view];
        Require(NSMinX(frame) >= -1 && NSMaxX(frame) <= NSWidth(content.bounds) + 1 &&
                NSMinY(frame) >= -1 && NSMaxY(frame) <= NSHeight(content.bounds) + 1,
                @"A popover control falls outside its visible bounds");
    }
    Require(NSHeight(usageStatus.scroll.frame) > 0, @"Account list has no visible area");
    Require(NSHeight(usageStatus.panel.frame) <= NSHeight(NSScreen.mainScreen.visibleFrame),
            @"Popover is taller than the screen");
}
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        coincide_usage_status_install();
        for (NSAppearanceName appearance in @[NSAppearanceNameDarkAqua, NSAppearanceNameAqua]) {
            NSApp.appearance = [NSAppearance appearanceNamed:appearance];
            SetFixture(12, @"system");
            CheckLayout();
            CoincideUsageBackground *background = (CoincideUsageBackground *)usageStatus.panel.contentView;
            __block NSColor *resolved;
            [[NSAppearance appearanceNamed:appearance] performAsCurrentDrawingAppearance:^{
                resolved = [background.fillColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            }];
            CGFloat expectedRed = [appearance isEqual:NSAppearanceNameDarkAqua] ? 0x18 / 255.0 : 0xFB / 255.0;
            Require(fabs(resolved.redComponent - expectedRed) < 0.01, @"Menu did not use the selected theme surface");
            NSView *document = usageStatus.scroll.documentView;
            NSStackView *list = (NSStackView *)document.subviews.firstObject;
            Require(list.arrangedSubviews.count == 12, @"Enabled accounts were lost");
            Require(NSHeight(document.frame) > NSHeight(usageStatus.scroll.contentView.bounds),
                    @"Long account lists must remain scrollable");
            CoincideUsageSurface *card = (CoincideUsageSurface *)list.arrangedSubviews.firstObject;
            Require(card.isAccessibilityElement && [card.accessibilityRole isEqual:NSAccessibilityButtonRole],
                    @"Account card is missing from the accessibility tree");
            Require([card.accessibilityLabel containsString:@"77% used"], @"Account card omitted its usage value");
            Require([card accessibilityPerformPress], @"Account card is not accessible as a button");
            Require([NextEvent()[@"action"] isEqual:@"usage"], @"Account card did not open Usage");
            NSSegmentedControl *mode = [NSSegmentedControl segmentedControlWithLabels:@[@"Used", @"Left"] trackingMode:NSSegmentSwitchTrackingSelectOne target:nil action:nil];
            mode.selectedSegment = 1;
            [usageStatus modeChanged:mode];
            NSDictionary *event = NextEvent();
            Require([event[@"key"] isEqual:@"usageDisplayMode"] && [event[@"value"] isEqual:@"remaining"],
                    @"Used/Left selection was not preserved");
            SetFixture(0, @"dark");
            CheckLayout();
            Require([usageStatus.panel.appearance.name isEqual:NSAppearanceNameDarkAqua],
                    @"Explicit app appearance did not override the system appearance");
        }
        coincide_usage_status_destroy();
        puts("Synthetic macOS usage menu: PASS");
    }
    return 0;
}
