#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// All calls and callbacks run on the AppKit main thread. The controller never
// owns the Rust engine or credentials: it sees only the presentation snapshot.
@interface CoincideUsagePanel : NSPanel
@property(nonatomic, copy) void (^cancelBlock)(void);
@end

@interface CoincideUsageBar : NSView
@property(nonatomic) double fill;
@property(nonatomic, strong) NSColor *tint;
@end
@implementation CoincideUsageBar
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect track = NSInsetRect(self.bounds, 0, 2);
    [[NSColor.separatorColor colorWithAlphaComponent:0.45] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:track xRadius:3 yRadius:3] fill];
    if (self.fill > 0) {
        track.size.width = MIN(track.size.width, MAX(6, track.size.width * MIN(1, self.fill)));
        [self.tint setFill];
        [[NSBezierPath bezierPathWithRoundedRect:track xRadius:3 yRadius:3] fill];
    }
}
@end

@interface CoincideUsageFlippedView : NSView
@end
@implementation CoincideUsageFlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface CoincideUsageBackground : NSView
@property(nonatomic, strong) NSColor *fillColor;
@end
@implementation CoincideUsageBackground
- (void)drawRect:(NSRect)dirtyRect { (void)dirtyRect; [self.fillColor setFill]; NSRectFill(self.bounds); }
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; self.needsDisplay = YES; }
@end

// Draw with semantic colors so the same surfaces follow the system's light
// and dark appearances, including when the appearance changes while open.
@interface CoincideUsageSurface : NSStackView
@property(nonatomic) BOOL interactive;
@property(nonatomic) BOOL hovered;
@property(nonatomic, weak) id pressTarget;
@property(nonatomic) SEL pressAction;
@property(nonatomic, strong) NSTrackingArea *usageTrackingArea;
@end
@implementation CoincideUsageSurface
- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    CGFloat opacity = self.hovered && self.interactive ? 0.09 : 0.045;
    [[NSColor.labelColor colorWithAlphaComponent:opacity] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:9 yRadius:9] fill];
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.usageTrackingArea) [self removeTrackingArea:self.usageTrackingArea];
    self.usageTrackingArea = nil;
    if (self.interactive) {
        self.usageTrackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
            options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect)
            owner:self userInfo:nil];
        [self addTrackingArea:self.usageTrackingArea];
    }
}
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; self.needsDisplay = YES; }
- (void)mouseEntered:(NSEvent *)event { (void)event; self.hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)event { (void)event; self.hovered = NO; self.needsDisplay = YES; }
- (void)resetCursorRects {
    [super resetCursorRects];
    if (self.interactive) [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor];
}
- (BOOL)accessibilityPerformPress {
    return self.interactive && self.pressTarget && self.pressAction
        ? [NSApp sendAction:self.pressAction to:self.pressTarget from:self] : NO;
}
@end

static NSColor *UsageProviderColor(NSString *provider) {
    NSDictionary *light = @{@"claude":@0xC2603D,@"codex":@0x0E8A6A,@"cursor":@0x5A5FD6,@"grok":@0x6B7077,@"opencode":@0xB7700C,@"antigravity":@0x2F6BDB};
    NSDictionary *dark = @{@"claude":@0xE08A6B,@"codex":@0x3CC79A,@"cursor":@0x9A9EFF,@"grok":@0xA9AEB4,@"opencode":@0xE9B04E,@"antigravity":@0x6FA3FF};
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
        BOOL isDark = [[appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]] isEqual:NSAppearanceNameDarkAqua];
        uint32_t hex = [((isDark ? dark : light)[provider] ?: @0x6B7077) unsignedIntValue];
        return [NSColor colorWithSRGBRed:((hex>>16)&255)/255. green:((hex>>8)&255)/255. blue:(hex&255)/255. alpha:1];
    }];
}
static NSImage *UsageLogo(NSString *provider, NSImage *logo, CGFloat size) {
    if (!logo) return nil;
    BOOL originalColor = [provider isEqual:@"claude"] || [provider isEqual:@"antigravity"];
    return [NSImage imageWithSize:NSMakeSize(size,size) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [logo drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
        if (!originalColor) {
            // The original monochrome assets are templates. Adapt their ink to
            // the current appearance while preserving their transparent shape.
            [NSColor.labelColor setFill];
            NSRectFillUsingOperation(rect, NSCompositingOperationSourceAtop);
        }
        return YES;
    }];
}
@implementation CoincideUsagePanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
- (void)cancelOperation:(id)sender { if (self.cancelBlock) self.cancelBlock(); }
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 53 && self.cancelBlock) self.cancelBlock(); else [super keyDown:event];
}
@end

@interface CoincideUsageStatus : NSObject <NSWindowDelegate>
@property(nonatomic, strong) NSStatusItem *item;
@property(nonatomic, strong) CoincideUsagePanel *panel;
@property(nonatomic, strong) NSDictionary *snapshot;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSImage *> *logos;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *events;
@property(nonatomic, strong) id globalClick;
@property(nonatomic, strong) id localClick;
@property(nonatomic, strong) NSScrollView *scroll;
@property(nonatomic) BOOL menuTracking;
@property(nonatomic) BOOL redrawPending;
@end

static NSString *UsageString(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
int coincide_usage_default_browser_is_chrome(void) {
    NSURL *site = [NSURL URLWithString:@"https://opencode.ai/"];
    NSURL *application = [[NSWorkspace sharedWorkspace] URLForApplicationToOpenURL:site];
    NSString *identifier = application ? [[NSBundle bundleWithURL:application] bundleIdentifier] : nil;
    return [identifier isEqualToString:@"com.google.Chrome"] ? 1 : 0;
}
static NSArray *UsageArray(id value) { return [value isKindOfClass:NSArray.class] ? value : @[]; }
static NSDictionary *UsageDict(id value) { return [value isKindOfClass:NSDictionary.class] ? value : @{}; }
static NSColor *UsageThemeColor(NSDictionary *snapshot, NSString *key, NSColor *fallback, CGFloat alpha) {
    NSDictionary *themes = UsageDict(snapshot[@"themes"]);
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
        BOOL dark = [[appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] isEqual:NSAppearanceNameDarkAqua];
        id value = UsageDict(themes[dark ? @"dark" : @"light"])[key];
        if (![value isKindOfClass:NSNumber.class]) return [fallback colorWithAlphaComponent:alpha];
        uint32_t hex = [value unsignedIntValue];
        return [NSColor colorWithSRGBRed:((hex>>16)&255)/255. green:((hex>>8)&255)/255. blue:(hex&255)/255. alpha:alpha];
    }];
}
static NSTextField *UsageLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *label = [NSTextField labelWithString:text ?: @""];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.maximumNumberOfLines = 1;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}
static NSStackView *UsageStack(NSUserInterfaceLayoutOrientation orientation, CGFloat spacing) {
    NSStackView *stack = [NSStackView new];
    stack.orientation = orientation;
    stack.alignment = orientation == NSUserInterfaceLayoutOrientationVertical ? NSLayoutAttributeLeading : NSLayoutAttributeCenterY;
    stack.distribution = NSStackViewDistributionFill;
    stack.spacing = spacing;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    return stack;
}
static CoincideUsageSurface *UsageSurface(CGFloat spacing) {
    CoincideUsageSurface *stack = [CoincideUsageSurface new];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.distribution = NSStackViewDistributionFill;
    stack.spacing = spacing;
    stack.edgeInsets = NSEdgeInsetsMake(9,10,9,10);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    return stack;
}
static NSBox *UsageSeparator(CGFloat width) {
    NSBox *line = [NSBox new];
    line.boxType = NSBoxSeparator;
    line.translatesAutoresizingMaskIntoConstraints = NO;
    [line.widthAnchor constraintEqualToConstant:width].active = YES;
    return line;
}

@implementation CoincideUsageStatus
- (instancetype)init {
    if ((self = [super init])) {
        _logos = [NSMutableDictionary new];
        _events = [NSMutableArray new];
        _snapshot = @{};
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(menuStarted:) name:NSMenuDidBeginTrackingNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(menuEnded:) name:NSMenuDidEndTrackingNotification object:nil];
    }
    return self;
}
- (void)enqueue:(NSDictionary *)event {
    if (self.events.count < 32) [self.events addObject:event];
}
- (void)setVisible:(BOOL)visible {
    if (!visible) {
        [self closePanel];
        if (self.item) [[NSStatusBar systemStatusBar] removeStatusItem:self.item];
        self.item = nil;
        return;
    }
    if (!self.item) {
        self.item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
        self.item.button.target = self;
        self.item.button.action = @selector(toggle:);
        [self.item.button setAccessibilityRole:NSAccessibilityMenuButtonRole];
        [self updateButton];
    }
}
- (NSImage *)gauge {
    NSImage *image = [NSImage imageWithSystemSymbolName:@"gauge.with.dots.needle.50percent" accessibilityDescription:nil];
    return [image imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightRegular]];
}
- (NSImage *)statusImage {
    NSArray *readings = UsageArray(self.snapshot[@"readings"]);
    if (readings.count == 0) readings = @[@{}];
    NSFont *font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize - 1 weight:NSFontWeightMedium];
    NSDictionary *attributes = @{NSFontAttributeName:font, NSForegroundColorAttributeName:NSColor.labelColor};
    CGFloat icon = 15, height = 18, gap = 3, spacing = 7, width = 0;
    NSMutableArray *segments = [NSMutableArray new];
    for (id raw in readings) {
        NSDictionary *reading = UsageDict(raw);
        NSString *provider = UsageString(reading[@"provider"]);
        NSImage *logo = self.logos[provider];
        NSImage *image = logo ? UsageLogo(provider, logo, icon) : [self gauge];
        NSString *text = UsageString(reading[@"text"]);
        NSAttributedString *label = [[NSAttributedString alloc] initWithString:text attributes:attributes];
        CGFloat segmentWidth = icon + (text.length ? gap + ceil(label.size.width) : 0);
        [segments addObject:@{ @"image": image ?: NSNull.null, @"text": label, @"width": @(segmentWidth), @"fallback": @(!logo) }];
        width += segmentWidth;
    }
    width += spacing * MAX(0, (NSInteger)segments.count - 1);
    NSImage *result = [NSImage imageWithSize:NSMakeSize(MAX(width, icon), height) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        (void)rect;
        CGFloat x = 0;
        for (NSDictionary *segment in segments) {
            NSRect iconRect = NSMakeRect(x, (height - icon) / 2, icon, icon);
            NSImage *image = segment[@"image"] == NSNull.null ? nil : segment[@"image"];
            [image drawInRect:iconRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
            if ([segment[@"fallback"] boolValue]) {
                [NSColor.labelColor setFill];
                NSRectFillUsingOperation(iconRect, NSCompositingOperationSourceAtop);
            }
            NSAttributedString *label = segment[@"text"];
            if (label.length) [label drawAtPoint:NSMakePoint(NSMaxX(iconRect) + gap, (height - label.size.height) / 2)];
            x += [segment[@"width"] doubleValue] + spacing;
        }
        return YES;
    }];
    result.template = NO;
    return result;
}
- (void)updateButton {
    if (!self.item.button) return;
    self.item.button.image = [self statusImage];
    self.item.button.imagePosition = NSImageOnly;
    self.item.button.title = @"";
    NSString *summary = UsageString(self.snapshot[@"tooltip"]);
    if (!summary.length) summary = @"Coincide usage";
    self.item.button.toolTip = summary;
    [self.item.button setAccessibilityLabel:summary];
}
- (void)setSnapshotJSON:(const char *)json {
    if (!json) return;
    NSData *data = [[NSString stringWithUTF8String:json] dataUsingEncoding:NSUTF8StringEncoding];
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![value isKindOfClass:NSDictionary.class]) return;
    if ([self.snapshot isEqual:value]) return;
    self.snapshot = value;
    [self updateButton];
    // Do not replace a picker while AppKit is tracking its menu.
    if (self.panel.isVisible) {
        if (self.menuTracking) self.redrawPending = YES;
        else [self updatePanel];
    }
}
- (void)menuStarted:(NSNotification *)notification { (void)notification; self.menuTracking = YES; }
- (void)menuEnded:(NSNotification *)notification {
    (void)notification; self.menuTracking = NO;
    if (self.redrawPending && self.panel.isVisible) { self.redrawPending = NO; [self updatePanel]; }
}
- (void)closePanel {
    [self.panel orderOut:nil];
    if (self.globalClick) [NSEvent removeMonitor:self.globalClick];
    if (self.localClick) [NSEvent removeMonitor:self.localClick];
    self.globalClick = nil; self.localClick = nil;
}
- (void)windowDidResignKey:(NSNotification *)notification { [self closePanel]; }
- (void)toggle:(id)sender {
    if (self.panel.isVisible) { [self closePanel]; return; }
    [self enqueue:@{@"action":@"opened"}];
    [self updatePanel];
    NSStatusBarButton *button = self.item.button;
    if (!button.window) return;
    NSRect anchor = [button.window convertRectToScreen:[button convertRect:button.bounds toView:nil]];
    NSScreen *screen = button.window.screen ?: NSScreen.mainScreen;
    NSPoint mouse = NSEvent.mouseLocation;
    NSEventType type = NSApp.currentEvent.type;
    if (type == NSEventTypeLeftMouseDown || type == NSEventTypeLeftMouseUp || type == NSEventTypeRightMouseDown || type == NSEventTypeRightMouseUp) {
        for (NSScreen *candidate in NSScreen.screens) {
            if (NSPointInRect(mouse, candidate.frame)) {
                CGFloat bar = NSMaxY(candidate.frame) - NSMaxY(candidate.visibleFrame);
                if (bar <= 0) bar = [NSStatusBar systemStatusBar].thickness;
                if (mouse.y >= NSMaxY(candidate.frame) - bar - 2 && !NSPointInRect(mouse, NSInsetRect(anchor,-8,-8))) {
                    screen = candidate;
                    anchor = NSMakeRect(mouse.x-anchor.size.width/2, NSMaxY(candidate.frame)-bar, anchor.size.width, bar);
                }
                break;
            }
        }
    }
    NSRect frame = self.panel.frame;
    NSRect bounds = screen.frame;
    frame.origin.x = MIN(MAX(NSMinX(anchor), NSMinX(bounds)+4), NSMaxX(bounds)-frame.size.width-4);
    frame.origin.y = MAX(NSMinY(anchor)-frame.size.height-4, NSMinY(screen.visibleFrame));
    [self.panel setFrameOrigin:frame.origin];
    [self.panel makeKeyAndOrderFront:nil];
    __weak CoincideUsageStatus *weakSelf = self;
    self.globalClick = [NSEvent addGlobalMonitorForEventsMatchingMask:(NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown) handler:^(NSEvent *event) { (void)event; [weakSelf closePanel]; }];
    self.localClick = [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown) handler:^NSEvent *(NSEvent *event) {
        CoincideUsageStatus *strongSelf = weakSelf;
        if (strongSelf.panel.isVisible && event.window != strongSelf.panel && event.window != strongSelf.item.button.window) [strongSelf closePanel];
        return event;
    }];
}
- (void)refresh:(id)sender { [self enqueue:@{@"action":@"refresh"}]; }
- (void)openApp:(id)sender { [self closePanel]; [self enqueue:@{@"action":@"open"}]; }
- (void)openUsage:(id)sender { [self closePanel]; [self enqueue:@{@"action":@"usage"}]; }
- (void)modeChanged:(NSSegmentedControl *)sender {
    [self enqueue:@{@"action":@"setting",@"key":@"usageDisplayMode",@"value":sender.selectedSegment == 1 ? @"remaining" : @"used"}];
}
- (void)choiceChanged:(NSPopUpButton *)sender {
    NSString *key = sender.identifier;
    id value = sender.selectedItem.representedObject ?: NSNull.null;
    if (key.length) [self enqueue:@{@"action":@"setting",@"key":key,@"value":value}];
}
- (NSPopUpButton *)popup:(NSArray *)options selected:(id)selected key:(NSString *)key {
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    popup.bezelStyle = NSBezelStyleRounded;
    popup.controlSize = NSControlSizeSmall;
    popup.identifier = key; popup.target = self; popup.action = @selector(choiceChanged:);
    for (id value in options) {
        NSDictionary *option = UsageDict(value);
        NSString *title = UsageString(option[@"title"]);
        if (!title.length) continue;
        [popup addItemWithTitle:title];
        NSMenuItem *item = popup.lastItem;
        item.representedObject = option[@"value"] ?: NSNull.null;
        if ([item.representedObject isEqual:selected ?: NSNull.null]) [popup selectItem:item];
    }
    return popup;
}
- (NSStackView *)settingRow:(NSString *)label popup:(NSPopUpButton *)popup muted:(NSColor *)muted {
    NSStackView *row = UsageStack(NSUserInterfaceLayoutOrientationHorizontal, 8);
    NSTextField *name = UsageLabel(label, 11, NSFontWeightRegular, muted);
    [name.widthAnchor constraintEqualToConstant:102].active = YES;
    [row addArrangedSubview:name]; [row addArrangedSubview:popup];
    [popup.widthAnchor constraintEqualToConstant:218].active = YES;
    return row;
}
- (void)updatePanel {
    const CGFloat panelWidth = 356, contentWidth = 328, innerWidth = 308;
    CGFloat previousScroll = self.panel.isVisible ? self.scroll.contentView.bounds.origin.y : 0;
    if (!self.panel) {
        self.panel = [[CoincideUsagePanel alloc] initWithContentRect:NSMakeRect(0,0,panelWidth,500)
            styleMask:(NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel)
            backing:NSBackingStoreBuffered defer:NO];
        self.panel.floatingPanel = YES;
        self.panel.level = NSPopUpMenuWindowLevel;
        self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorIgnoresCycle;
        self.panel.hidesOnDeactivate = NO; self.panel.becomesKeyOnlyIfNeeded = NO;
        self.panel.excludedFromWindowsMenu = YES; self.panel.opaque = NO;
        self.panel.backgroundColor = NSColor.clearColor; self.panel.hasShadow = YES;
        self.panel.releasedWhenClosed = NO; self.panel.delegate = self;
        __weak CoincideUsageStatus *weakSelf = self;
        self.panel.cancelBlock = ^{ [weakSelf closePanel]; };
    }
    NSString *appearance = UsageString(self.snapshot[@"appearance"]);
    self.panel.appearance = [appearance isEqual:@"dark"] ? [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]
        : ([appearance isEqual:@"light"] ? [NSAppearance appearanceNamed:NSAppearanceNameAqua] : nil);
    NSColor *ink = UsageThemeColor(self.snapshot, @"ink", NSColor.labelColor, 1);
    NSColor *muted = UsageThemeColor(self.snapshot, @"ink", NSColor.secondaryLabelColor, 0.64);
    CoincideUsageBackground *background = [CoincideUsageBackground new];
    background.fillColor = UsageThemeColor(self.snapshot, @"surface", NSColor.windowBackgroundColor, 1);
    background.wantsLayer = YES; background.layer.cornerRadius = 12; background.layer.masksToBounds = YES;
    NSStackView *content = UsageStack(NSUserInterfaceLayoutOrientationVertical, 9);
    content.edgeInsets = NSEdgeInsetsMake(14,14,14,14);
    content.alignment = NSLayoutAttributeLeading;
    [background addSubview:content];
    [NSLayoutConstraint activateConstraints:@[[content.leadingAnchor constraintEqualToAnchor:background.leadingAnchor], [content.trailingAnchor constraintEqualToAnchor:background.trailingAnchor], [content.topAnchor constraintEqualToAnchor:background.topAnchor], [content.bottomAnchor constraintEqualToAnchor:background.bottomAnchor]]];
    NSStackView *header = UsageStack(NSUserInterfaceLayoutOrientationHorizontal, 8);
    NSStackView *heading = UsageStack(NSUserInterfaceLayoutOrientationVertical, 2);
    [heading addArrangedSubview:UsageLabel(@"Usage", 15, NSFontWeightSemibold, ink)];
    NSString *updated = UsageString(self.snapshot[@"updated"]);
    if (updated.length) [heading addArrangedSubview:UsageLabel([@"Updated " stringByAppendingString:updated], 10, NSFontWeightRegular, muted)];
    [header addArrangedSubview:heading];
    NSView *spacer = [NSView new]; [header addArrangedSubview:spacer];
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSSegmentedControl *mode = [NSSegmentedControl segmentedControlWithLabels:@[@"Used",@"Left"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(modeChanged:)];
    mode.controlSize = NSControlSizeSmall; mode.selectedSegmentBezelColor = UsageThemeColor(self.snapshot, @"accent", UsageProviderColor(@"codex"), 1);
    mode.selectedSegment = [UsageString(self.snapshot[@"mode"]) isEqual:@"remaining"] ? 1 : 0;
    [header addArrangedSubview:mode]; [content addArrangedSubview:header];
    [header.widthAnchor constraintEqualToConstant:contentWidth].active = YES;
    CoincideUsageSurface *overview = UsageSurface(7);
    [overview addArrangedSubview:UsageLabel(@"OVERVIEW", 10, NSFontWeightSemibold, muted)];
    NSStackView *overall = UsageStack(NSUserInterfaceLayoutOrientationHorizontal, 12);
    overall.distribution = NSStackViewDistributionFillEqually;
    for (id raw in UsageArray(self.snapshot[@"periods"])) {
        NSDictionary *p = UsageDict(raw); NSStackView *column = UsageStack(NSUserInterfaceLayoutOrientationVertical, 2);
        [column addArrangedSubview:UsageLabel(UsageString(p[@"label"]), 10, NSFontWeightRegular, muted)];
        [column addArrangedSubview:UsageLabel(UsageString(p[@"tokens"]), 14, NSFontWeightSemibold, ink)];
        [column addArrangedSubview:UsageLabel(UsageString(p[@"cost"]), 10, NSFontWeightRegular, muted)];
        [overall addArrangedSubview:column];
    }
    [overview addArrangedSubview:overall];
    [overall.widthAnchor constraintEqualToConstant:innerWidth].active = YES;
    [content addArrangedSubview:overview];
    [overview.widthAnchor constraintEqualToConstant:contentWidth].active = YES;
    [content addArrangedSubview:UsageLabel(@"ACCOUNTS", 10, NSFontWeightSemibold, muted)];
    NSScrollView *scroll = [NSScrollView new]; scroll.hasVerticalScroller = YES; scroll.drawsBackground = NO;
    scroll.borderType = NSNoBorder; scroll.translatesAutoresizingMaskIntoConstraints = NO;
    NSStackView *accountList = UsageStack(NSUserInterfaceLayoutOrientationVertical, 6);
    accountList.edgeInsets = NSEdgeInsetsMake(2,0,4,0);
    for (id raw in UsageArray(self.snapshot[@"accounts"])) {
        NSDictionary *account = UsageDict(raw); CoincideUsageSurface *card = UsageSurface(4);
        card.interactive = YES; card.pressTarget = self; card.pressAction = @selector(openUsage:);
        NSStackView *name = UsageStack(NSUserInterfaceLayoutOrientationHorizontal, 6);
        NSString *provider = UsageString(account[@"provider"]);
        NSImage *logo = UsageLogo(provider, self.logos[provider], 15);
        if (logo) { NSImageView *image = [[NSImageView alloc] initWithFrame:NSMakeRect(0,0,15,15)]; image.image = logo; [image.widthAnchor constraintEqualToConstant:15].active=YES; [image.heightAnchor constraintEqualToConstant:15].active=YES; [name addArrangedSubview:image]; }
        NSTextField *accountTitle = UsageLabel(UsageString(account[@"title"]), 12, NSFontWeightSemibold, ink);
        [accountTitle setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
        [name addArrangedSubview:accountTitle];
        NSString *plan = UsageString(account[@"plan"]);
        if (plan.length) [name addArrangedSubview:UsageLabel(plan.capitalizedString, 10, NSFontWeightRegular, muted)];
        NSString *checked = UsageString(account[@"checked"]);
        if (checked.length) {
            NSView *space = [NSView new];
            [space setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
            [name addArrangedSubview:space];
            NSTextField *checkedLabel = UsageLabel(checked, 10, NSFontWeightRegular, muted);
            [checkedLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
            [name addArrangedSubview:checkedLabel];
        }
        [name.widthAnchor constraintEqualToConstant:innerWidth].active = YES;
        [card addArrangedSubview:name];
        NSArray *rows = UsageArray(account[@"rows"]);
        for (id rawRow in rows) {
            NSDictionary *r = UsageDict(rawRow); NSStackView *row = UsageStack(NSUserInterfaceLayoutOrientationHorizontal, 6);
            NSTextField *title = UsageLabel(UsageString(r[@"title"]), 11, NSFontWeightRegular, muted);
            NSTextField *value = UsageLabel(UsageString(r[@"value"]), 11, NSFontWeightMedium, ink);
            NSView *space = [NSView new]; [row addArrangedSubview:title]; [row addArrangedSubview:space]; [row addArrangedSubview:value];
            [card addArrangedSubview:row]; [row.widthAnchor constraintEqualToConstant:innerWidth].active=YES;
            if ([r[@"fill"] isKindOfClass:NSNumber.class]) {
                CoincideUsageBar *bar = [CoincideUsageBar new];
                bar.fill = MAX(0, MIN(1, [r[@"fill"] doubleValue]));
                NSString *level = UsageString(r[@"level"]);
                bar.tint = [level isEqual:@"critical"] ? NSColor.systemRedColor : ([level isEqual:@"near"] ? NSColor.systemOrangeColor : UsageProviderColor(UsageString(account[@"provider"])));
                [bar setAccessibilityRole:NSAccessibilityProgressIndicatorRole];
                [bar setAccessibilityLabel:UsageString(r[@"title"])];
                [bar setAccessibilityValue:@(bar.fill * 100)];
                [card addArrangedSubview:bar]; [bar.widthAnchor constraintEqualToConstant:innerWidth].active=YES;
                [bar.heightAnchor constraintEqualToConstant:10].active=YES;
            }
            NSString *detail=UsageString(r[@"detail"]);
            if (detail.length) {
                NSTextField *detailLabel = UsageLabel(detail,10,NSFontWeightRegular,muted);
                detailLabel.maximumNumberOfLines = 2; detailLabel.lineBreakMode = NSLineBreakByWordWrapping;
                detailLabel.preferredMaxLayoutWidth = innerWidth;
                [detailLabel.widthAnchor constraintEqualToConstant:innerWidth].active = YES;
                [card addArrangedSubview:detailLabel];
            }
        }
        NSString *placeholder = UsageString(account[@"placeholder"]);
        if (rows.count == 0 && placeholder.length) {
            NSTextField *message = UsageLabel(placeholder, 10, NSFontWeightRegular, muted);
            message.maximumNumberOfLines = 2;
            message.lineBreakMode = NSLineBreakByWordWrapping;
            message.preferredMaxLayoutWidth = innerWidth;
            [message.widthAnchor constraintEqualToConstant:innerWidth].active = YES;
            [card addArrangedSubview:message];
        }
        NSString *tracked = UsageString(account[@"tracked"]);
        if (tracked.length) [card addArrangedSubview:UsageLabel(tracked,10,NSFontWeightRegular,muted)];
        NSClickGestureRecognizer *openCard = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(openUsage:)];
        [card addGestureRecognizer:openCard];
        [card setAccessibilityElement:YES];
        [card setAccessibilityRole:NSAccessibilityButtonRole];
        NSMutableArray<NSString *> *summary = [NSMutableArray arrayWithObject:UsageString(account[@"title"])];
        if (plan.length) [summary addObject:plan];
        for (id rawRow in rows) {
            NSDictionary *row = UsageDict(rawRow);
            NSString *title = UsageString(row[@"title"]), *value = UsageString(row[@"value"]);
            if (title.length || value.length) [summary addObject:[NSString stringWithFormat:@"%@ %@", title, value]];
        }
        if (rows.count == 0 && placeholder.length) [summary addObject:placeholder];
        if (tracked.length) [summary addObject:tracked];
        [card setAccessibilityLabel:[summary componentsJoinedByString:@", "]];
        [accountList addArrangedSubview:card];
        [card.widthAnchor constraintEqualToConstant:contentWidth].active = YES;
    }
    if ([self.snapshot[@"empty"] boolValue]) [accountList addArrangedSubview:UsageLabel(@"No provider is turned on.",11,NSFontWeightRegular,muted)];
    NSView *document = [CoincideUsageFlippedView new]; document.translatesAutoresizingMaskIntoConstraints = NO;
    [document addSubview:accountList];
    [NSLayoutConstraint activateConstraints:@[[accountList.leadingAnchor constraintEqualToAnchor:document.leadingAnchor], [accountList.trailingAnchor constraintEqualToAnchor:document.trailingAnchor], [accountList.topAnchor constraintEqualToAnchor:document.topAnchor], [accountList.bottomAnchor constraintEqualToAnchor:document.bottomAnchor], [document.widthAnchor constraintEqualToConstant:contentWidth]]];
    scroll.documentView = document; self.scroll = scroll; [content addArrangedSubview:scroll];
    [scroll.widthAnchor constraintEqualToConstant:contentWidth].active=YES;
    CGFloat availableHeight = NSHeight((self.item.button.window.screen ?: NSScreen.mainScreen).visibleFrame) - 8;
    CGFloat desired = MIN(MAX(44, availableHeight - 340), MIN(280, MAX(44, accountList.fittingSize.height)));
    [scroll.heightAnchor constraintEqualToConstant:desired].active=YES;
    [content addArrangedSubview:UsageSeparator(contentWidth)];
    NSPopUpButton *primary = [self popup:UsageArray(self.snapshot[@"primaryOptions"]) selected:self.snapshot[@"primary"] key:@"menuBarUsage"];
    NSPopUpButton *secondary = [self popup:UsageArray(self.snapshot[@"secondaryOptions"]) selected:self.snapshot[@"secondary"] key:@"menuBarSecondaryUsage"];
    [content addArrangedSubview:[self settingRow:@"Menu bar shows" popup:primary muted:muted]];
    [content addArrangedSubview:[self settingRow:@"Also show" popup:secondary muted:muted]];
    NSArray *refreshOptions = @[@{@"title":@"Automatically",@"value":@"automatic"},@{@"title":@"Every minute",@"value":@"everyMinute"},@{@"title":@"Every 5 minutes",@"value":@"every5Minutes"},@{@"title":@"Every 15 minutes",@"value":@"every15Minutes"},@{@"title":@"Every 30 minutes",@"value":@"every30Minutes"},@{@"title":@"Every hour",@"value":@"everyHour"},@{@"title":@"Only when opened",@"value":@"manual"}];
    [content addArrangedSubview:[self settingRow:@"Refresh" popup:[self popup:refreshOptions selected:self.snapshot[@"refresh"] key:@"usageRefresh"] muted:muted]];
    NSStackView *actions = UsageStack(NSUserInterfaceLayoutOrientationHorizontal, 7);
    NSButton *refresh = [NSButton buttonWithTitle:@"Refresh" target:self action:@selector(refresh:)]; refresh.controlSize=NSControlSizeSmall;
    NSButton *usage = [NSButton buttonWithTitle:@"Usage Settings" target:self action:@selector(openUsage:)]; usage.controlSize=NSControlSizeSmall;
    NSButton *open = [NSButton buttonWithTitle:@"Open Coincide" target:self action:@selector(openApp:)]; open.controlSize=NSControlSizeSmall;
    [actions addArrangedSubview:refresh]; [actions addArrangedSubview:usage]; [actions addArrangedSubview:open];
    [content addArrangedSubview:actions];
    NSSize fitting = content.fittingSize; CGFloat height=MAX(280,MIN(availableHeight,ceil(fitting.height)));
    [self.panel setContentSize:NSMakeSize(panelWidth,height)]; self.panel.contentView=background;
    [background layoutSubtreeIfNeeded];
    CGFloat maxScroll = MAX(0, NSHeight(document.frame) - NSHeight(scroll.contentView.bounds));
    [scroll.contentView scrollToPoint:NSMakePoint(0, MIN(previousScroll, maxScroll))];
    [scroll reflectScrolledClipView:scroll.contentView];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end

static CoincideUsageStatus *usageStatus;
void coincide_usage_status_install(void) { NSCAssert(NSThread.isMainThread, @"usage status requires main thread"); if (!usageStatus) usageStatus=[CoincideUsageStatus new]; }
void coincide_usage_status_logo(const char *provider, const uint8_t *bytes, size_t length) {
    if (!usageStatus || !provider || !bytes || !length || length > 2*1024*1024) return;
    NSString *key=[NSString stringWithUTF8String:provider]; NSData *data=[NSData dataWithBytes:bytes length:length]; NSImage *image=[[NSImage alloc] initWithData:data];
    if (key && image) usageStatus.logos[key]=image;
}
void coincide_usage_status_visible(int visible) { [usageStatus setVisible:visible != 0]; }
void coincide_usage_status_update(const char *json) { [usageStatus setSnapshotJSON:json]; }
char *coincide_usage_status_next_event(void) {
    if (!usageStatus.events.count) return NULL;
    NSDictionary *event=usageStatus.events.firstObject; [usageStatus.events removeObjectAtIndex:0];
    NSData *data=[NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
    if (!data || data.length > 65536) return NULL;
    char *result=calloc(data.length+1,1); if (result) memcpy(result,data.bytes,data.length); return result;
}
void coincide_usage_status_destroy(void) { [usageStatus setVisible:NO]; usageStatus=nil; }
#if defined(COINCIDE_MENUBAR_TEST)
void coincide_usage_status_test_show(void) {
    [usageStatus toggle:nil];
    fprintf(stderr, "fixture buttonWindow=%d panelVisible=%d frame=%.0fx%.0f\n", usageStatus.item.button.window != nil, usageStatus.panel.isVisible, usageStatus.panel.frame.size.width, usageStatus.panel.frame.size.height);
}
void coincide_usage_status_test_capture(const char *path) {
    NSView *view = usageStatus.panel.contentView;
    [view layoutSubtreeIfNeeded];
    NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [png writeToFile:[NSString stringWithUTF8String:path] atomically:YES];
}
#endif
