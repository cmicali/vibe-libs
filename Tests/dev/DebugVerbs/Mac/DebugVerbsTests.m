// The standard table and the input table, run through their handlers as an
// app's dispatcher runs them, with options and a controller of the test's
// own. The input verbs' events are read back from the app's own queue.

#import <XCTest/XCTest.h>
#import <AppKit/AppKit.h>

#import "DebugCommandDispatch.h"
#import "DrawnViewTestSupport.h"
#import "DebugModalUI.h"
#import "DebugProcessHealth.h"
#import "DebugScreenshot.h"
#import "DebugStandardVerbs.h"
#import "DebugSyntheticInput.h"
#import "DebugViewTree.h"
#import "DebugWindowCapture.h"
#import "DebugWireFormat.h"
#import "VibeMacros.h"

@interface DebugVerbsTests : XCTestCase
@end

// A menu item's target, which counts what it was sent.
@interface DebugVerbsMenuTarget : NSObject
@property (nonatomic) NSUInteger fired;
- (void)fire:(id)sender;
@end

@implementation DebugVerbsMenuTarget
- (void)fire:(id)sender {
    self.fired++;
}
@end

// A window that keeps each key event it is sent, and handles none.
@interface DebugVerbsKeyWindow : NSWindow
@property (nonatomic, readonly) NSMutableArray<NSEvent *> *keys;
@property (nonatomic, readonly) NSMutableArray<NSEvent *> *equivalents;
@end

@implementation DebugVerbsKeyWindow {
    NSMutableArray<NSEvent *> *_keys;
    NSMutableArray<NSEvent *> *_equivalents;
}
- (NSMutableArray<NSEvent *> *)keys {
    if (!_keys) {
        _keys = [NSMutableArray array];
    }
    return _keys;
}
- (NSMutableArray<NSEvent *> *)equivalents {
    if (!_equivalents) {
        _equivalents = [NSMutableArray array];
    }
    return _equivalents;
}
- (void)sendEvent:(NSEvent *)event {
    if (event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp) {
        [self.keys addObject:event];
        return;
    }
    [super sendEvent:event];
}
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    [self.equivalents addObject:event];
    return NO;
}
@end

// A window's controller, in its responder chain, which a menu item with no
// target reaches.
@interface DebugVerbsWindowController : NSWindowController
@property (nonatomic) NSUInteger fired;
- (void)fire:(id)sender;
@end

@implementation DebugVerbsWindowController
- (void)fire:(id)sender {
    self.fired++;
}
@end

// A flipped view that paints a red band across its top.
@interface DebugVerbsBandView : NSView
@end

@implementation DebugVerbsBandView
- (BOOL)isFlipped {
    return YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    [NSColor.whiteColor setFill];
    NSRectFill(self.bounds);
    [NSColor.redColor setFill];
    NSRectFill(NSMakeRect(0, 0, NSWidth(self.bounds), 20));
}
@end

@implementation DebugVerbsTests {
    NSMutableArray<NSWindow *> *_windows;
    NSMenu *_mainMenu;
}

static id JSONObject(NSString *json) {
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
}

// Host-less, NSApp is never active, so a test's options don't ask for a key
// window. Only the focus check's own test does.
static VibeDebugStandardOptions *TestOptions(void) {
    VibeDebugStandardOptions *options = [VibeDebugStandardOptions new];
    options.requiresKeyWindow = NO;
    return options;
}

static NSString *TempPNGPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"debug-verbs-%@.png", NSUUID.UUID.UUIDString]];
}

static BOOL SpinUntil(BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:6];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    return condition();
}

// The render of window, read back. Its rows run from the window's top.
static NSBitmapImageRep *Rendered(NSWindow *window) {
    NSString *path = TempPNGPath();
    NSBitmapImageRep *image = VibeDebugRenderWindow(window, path)
            ? [NSBitmapImageRep imageRepWithData:[NSData dataWithContentsOfFile:path]] : nil;
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    return image;
}

// The pixel at a point of window's content, from its top left, in a render or
// a capture of the whole window at scale.
static NSColor *ContentPixel(NSBitmapImageRep *image, NSWindow *window, CGFloat scale, CGFloat x, CGFloat y) {
    CGFloat top = NSHeight(window.frame) - NSHeight(window.contentView.frame);
    return VibePixel(image, YES, x * scale, (y + top) * scale);
}

static NSString *Run(NSArray<NSDictionary *> *table, NSArray<NSString *> *tokens, id controller) {
    NSDictionary *spec = VibeDebugSpecForVerb(table, tokens.firstObject);
    return spec ? ((VibeDebugCommandHandler)spec[@"handler"])(tokens, NSUUID.UUID.UUIDString, controller) : nil;
}

- (void)setUp {
    // TRAP: host-less, NSApp is nil until this runs, and every window and
    // event needs it.
    [NSApplication sharedApplication];
    _windows = [NSMutableArray array];
    _mainMenu = NSApp.mainMenu;
    // Drop anything an earlier test left queued.
    while ([NSApp nextEventMatchingMask:NSEventMaskAny untilDate:nil inMode:NSDefaultRunLoopMode dequeue:YES]) {
    }
}

- (void)tearDown {
    for (NSWindow *window in _windows) {
        [window close];
    }
    NSApp.mainMenu = _mainMenu;
}

- (NSWindow *)windowOfSize:(NSSize)size {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, size.width, size.height)
                                                   styleMask:NSWindowStyleMaskTitled
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.releasedWhenClosed = NO;
    window.title = NSUUID.UUID.UUIDString;
    [_windows addObject:window];
    return window;
}

// The events of mask in the queue now, oldest first.
static NSArray<NSEvent *> *QueuedEvents(NSEventMask mask) {
    NSMutableArray<NSEvent *> *events = [NSMutableArray array];
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:0.5];
    NSEvent *event;
    while ((event = [NSApp nextEventMatchingMask:mask untilDate:until inMode:NSDefaultRunLoopMode dequeue:YES])) {
        [events addObject:event];
        until = [NSDate dateWithTimeIntervalSinceNow:0.05];
    }
    return events;
}

#pragma mark - The table

- (void)testEveryVerbIsUniqueEveryUsageParsesAndTheWaitsAreVibes {
    VibeDebugStandardOptions *options = TestOptions();
    NSArray<NSDictionary *> *standard = VibeDebugStandardVerbs(options);
    NSArray<NSDictionary *> *input = VibeDebugInputVerbs(options);
    NSMutableArray<NSString *> *verbs = [NSMutableArray array];
    for (NSArray<NSDictionary *> *table in @[standard, input]) {
        for (NSDictionary *spec in table) {
            NSString *verb = VibeDebugVerbFromUsage(spec[@"usage"]);
            XCTAssertGreaterThan(verb.length, 0u, @"%@", spec[@"usage"]);
            XCTAssertFalse([verb containsString:@" "], @"%@", spec[@"usage"]);
            XCTAssertEqual(VibeDebugSpecForVerb(table, verb), spec, @"%@ is found by its verb", verb);
            XCTAssertNotNil(spec[@"handler"]);
            [verbs addObject:verb];
        }
    }
    XCTAssertEqualObjects(VibeDebugDuplicateVerbs(@[standard, input]), @[], @"no verb is in two places");
    XCTAssertEqualObjects([NSSet setWithArray:verbs], ([NSSet setWithArray:@[
        @"dump_build", @"quit", @"work_tally", @"dump_health", @"block_main", @"block_main_deep",
        @"dump_view_tree", @"dump_menu", @"click_menu", @"dump_screenshot", @"capture_window", @"raise_window",
        @"answer_sheet", @"answer_popover", @"answer_menu",
        @"activate", @"key", @"key_down", @"key_up", @"click", @"mouse_down", @"mouse_up", @"mouse_move", @"drag", @"scroll",
    ]]));

    NSDictionary *waits = @{@"block_main": @30, @"block_main_deep": @30, @"dump_health": @10, @"capture_window": @10, @"activate": @10};
    for (NSArray<NSDictionary *> *table in @[standard, input]) {
        for (NSDictionary *spec in table) {
            NSString *verb = VibeDebugVerbFromUsage(spec[@"usage"]);
            XCTAssertEqual([spec[@"clientTimeout"] doubleValue], [waits[verb] doubleValue], @"%@'s wait", verb);
        }
    }
}

#pragma mark - The shared verbs

- (void)testDumpBuildAnswersItsKeysAndTheExtras {
    NSObject *controller = [NSObject new];
    __block id seen = nil;
    VibeDebugStandardOptions *options = TestOptions();
    options.buildExtras = ^NSDictionary *(id given) {
        seen = given;
        return @{@"storesOpen": @YES, @"bundleId": @"not this one"};
    };
    NSDictionary *reply = JSONObject(Run(VibeDebugStandardVerbs(options), @[@"dump_build"], controller));
    XCTAssertEqual(seen, controller, @"the extras get the dispatcher's controller");
    for (NSString *key in @[@"bundleId", @"executable", @"channel", @"version", @"git", @"built", @"pid", @"path"]) {
        XCTAssertNotNil(reply[key], @"%@", key);
    }
    XCTAssertEqualObjects(reply[@"storesOpen"], @YES);
    XCTAssertEqualObjects(reply[@"bundleId"], NSBundle.mainBundle.bundleIdentifier ?: NSNull.null,
                          @"the verb's own keys win");
    XCTAssertEqualObjects(reply[@"pid"], @(NSProcessInfo.processInfo.processIdentifier));
    XCTAssertEqual(reply.count, 9u);
}

- (void)testDumpHealthAnswersTheProcessAndTheExtras {
    VibeDebugStandardOptions *options = TestOptions();
    options.healthExtras = ^NSDictionary *(id controller) {
        return @{@"app": @{@"rows": @3}, @"ok": @NO};
    };
    NSDictionary *reply = JSONObject(Run(VibeDebugStandardVerbs(options), @[@"dump_health"], NSNull.null));
    XCTAssertEqualObjects(reply[@"ok"], @YES);
    XCTAssertEqualObjects(reply[@"app"], @{@"rows": @3});
    NSDictionary *process = reply[@"process"];
    XCTAssertGreaterThan([process[@"threads"] unsignedIntegerValue], 0u);
    XCTAssertGreaterThan([process[@"fileDescriptors"] unsignedIntegerValue], 0u);
    XCTAssertGreaterThan([process[@"footprintBytes"] unsignedLongLongValue], 0u);
    XCTAssertGreaterThan([process[@"machPorts"] unsignedIntegerValue], 0u);
    XCTAssertGreaterThan([process[@"uptimeSeconds"] doubleValue], 0);

    uint64_t live = 0, reserved = 0;
    VibeDebugMallocBytes(&live, &reserved);
    XCTAssertGreaterThan(live, 0u);
    XCTAssertLessThanOrEqual(live, reserved, @"live bytes never exceed the allocator's reservations");

    CALayer *layer = [CALayer layer];
    [layer addSublayer:[CALayer layer]];
    [layer.sublayers.firstObject addSublayer:[CALayer layer]];
    XCTAssertEqual(VibeDebugLayerCount(layer), 3u);
}

- (void)testBlockMainHoldsMainAndChainsASharedVerbOrTheAppsOwn {
    VibeDebugStandardOptions *options = TestOptions();
    options.chainableVerbs = ^NSArray<NSDictionary *> *{
        return @[
            VibeDebugCmd(@"ping", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, id controller) {
                return VibeJSONString(@{@"pong": tokens.lastObject});
            }),
            VibeDebugCmd(@"later", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, id controller) {
                return nil;
            }),
        ];
    };
    NSArray<NSDictionary *> *table = VibeDebugStandardVerbs(options);
    XCTAssertTrue(NSThread.isMainThread);

    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    NSDictionary *held = JSONObject(Run(table, @[@"block_main", @"0.2"], NSNull.null));
    XCTAssertGreaterThanOrEqual(CFAbsoluteTimeGetCurrent() - start, 0.2);
    XCTAssertEqualObjects(held, (@{@"ok": @YES, @"blockedSeconds": @0.2}));

    NSDictionary *shared = JSONObject(Run(table, @[@"block_main", @"0.01", @"dump_build"], NSNull.null));
    XCTAssertEqualObjects(shared[@"then"], @"dump_build");
    XCTAssertNotNil(JSONObject(shared[@"thenReply"])[@"pid"]);

    NSDictionary *own = JSONObject(Run(table, @[@"block_main", @"0.01", @"ping", @"x"], NSNull.null));
    XCTAssertEqualObjects(JSONObject(own[@"thenReply"]), @{@"pong": @"x"});

    XCTAssertNil(Run(table, @[@"block_main", @"0.01", @"later"], NSNull.null),
                 @"a chained verb that replies later leaves the reply to it");
    XCTAssertEqualObjects(JSONObject(Run(table, @[@"block_main", @"0.01", @"block_main", @"1"], NSNull.null)),
                          @{@"error": @"block_main cannot chain itself"});
    XCTAssertTrue([JSONObject(Run(table, @[@"block_main", @"0.01", @"dump_view_tree"], NSNull.null))[@"error"]
                   hasPrefix:@"block_main can only chain"], @"a platform verb stays unchainable");
    XCTAssertTrue([JSONObject(Run(table, @[@"block_main", @"0.01", @"nope"], NSNull.null))[@"error"]
                   hasPrefix:@"block_main can only chain"]);
    XCTAssertNotNil(JSONObject(Run(table, @[@"block_main", @"6"], NSNull.null))[@"error"], @"5 s at most");

    NSDictionary *deep = JSONObject(Run(table, @[@"block_main_deep", @"0.01", @"40", @"alternating"], NSNull.null));
    XCTAssertEqualObjects(deep, (@{@"ok": @YES, @"blockedSeconds": @0.01, @"depth": @40, @"alternating": @YES}));
}

- (void)testWorkTallyOpensAndClosesAWindow {
    NSArray<NSDictionary *> *table = VibeDebugStandardVerbs(TestOptions());
    XCTAssertEqualObjects(JSONObject(Run(table, @[@"work_tally", @"begin"], NSNull.null)), @{@"ok": @YES});
    VibeSignpostCount(debug_verbs_test);
    NSDictionary *window = JSONObject(Run(table, @[@"work_tally", @"end"], NSNull.null));
    XCTAssertEqualObjects(window[@"active"], @YES);
    XCTAssertEqualObjects(window[@"label"], @"debug");
    XCTAssertEqualObjects(window[@"work"][@"debug_verbs_test"][@"count"], @1);
    XCTAssertEqualObjects(JSONObject(Run(table, @[@"work_tally", @"end"], NSNull.null))[@"active"], @NO,
                          @"the window closed");
    XCTAssertNotNil(JSONObject(Run(table, @[@"work_tally"], NSNull.null))[@"error"]);
}

#pragma mark - The mac verbs

- (void)testTheViewTreeNamesEachView {
    NSWindow *window = [self windowOfSize:NSMakeSize(200, 100)];
    NSView *named = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    named.identifier = @"named";
    NSView *hidden = [[NSView alloc] initWithFrame:NSMakeRect(10, 0, 10, 10)];
    hidden.hidden = YES;
    NSView *faded = [[NSView alloc] initWithFrame:NSMakeRect(20, 0, 10, 10)];
    faded.alphaValue = 0.5;
    for (NSView *view in @[named, hidden, faded]) {
        [window.contentView addSubview:view];
    }
    NSArray *windows = JSONObject(VibeViewTreeDump())[@"windows"];
    NSDictionary *node = [windows filteredArrayUsingPredicate:
            [NSPredicate predicateWithFormat:@"title == %@", window.title]].firstObject;
    XCTAssertEqualObjects(node[@"class"], @"NSWindow");
    NSArray *subviews = node[@"contentView"][@"subviews"];
    XCTAssertEqual(subviews.count, 3u);
    XCTAssertEqualObjects(subviews[0][@"class"], @"NSView");
    XCTAssertEqualObjects(subviews[0][@"id"], @"named");
    XCTAssertNil(subviews[0][@"hidden"]);
    XCTAssertEqualObjects(subviews[1][@"hidden"], @YES);
    XCTAssertEqualObjects(subviews[2][@"alpha"], @0.5);
    XCTAssertNil(subviews[2][@"hidden"]);
}

// A main menu of one submenu: an item with a key equivalent, a separator, a
// hidden item, a checked item, a disabled item, and a nested submenu.
- (NSMenu *)menuWithTarget:(DebugVerbsMenuTarget *)target {
    NSMenu *main = [[NSMenu alloc] initWithTitle:@"Main"];
    NSMenu *file = [[NSMenu alloc] initWithTitle:@"File"];
    file.autoenablesItems = NO;
    NSMenuItem *keyed = [file addItemWithTitle:@"Keyed" action:@selector(fire:) keyEquivalent:@"k"];
    keyed.identifier = @"keyed";
    keyed.target = target;
    keyed.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [file addItem:NSMenuItem.separatorItem];
    NSMenuItem *hidden = [file addItemWithTitle:@"Hidden" action:@selector(fire:) keyEquivalent:@""];
    hidden.target = target;
    hidden.hidden = YES;
    NSMenuItem *checked = [file addItemWithTitle:@"Checked" action:@selector(fire:) keyEquivalent:@""];
    checked.target = target;
    checked.state = NSControlStateValueOn;
    NSMenuItem *disabled = [file addItemWithTitle:@"Disabled" action:@selector(fire:) keyEquivalent:@""];
    disabled.target = target;
    disabled.enabled = NO;
    NSMenuItem *nested = [file addItemWithTitle:@"Nested" action:NULL keyEquivalent:@""];
    nested.submenu = [[NSMenu alloc] initWithTitle:@"Nested"];
    [nested.submenu addItemWithTitle:@"Inner" action:@selector(fire:) keyEquivalent:@""].target = target;
    NSMenuItem *top = [main addItemWithTitle:@"File" action:NULL keyEquivalent:@""];
    top.submenu = file;
    return main;
}

- (void)testTheMenuDumpListsEachKindOfItem {
    DebugVerbsMenuTarget *target = [DebugVerbsMenuTarget new];
    NSApp.mainMenu = [self menuWithTarget:target];
    NSDictionary *reply = JSONObject(Run(VibeDebugStandardVerbs(TestOptions()), @[@"dump_menu"],
                                         NSNull.null));
    NSArray *items = [reply[@"menu"] firstObject][@"items"];
    XCTAssertEqual(items.count, 6u);
    XCTAssertEqualObjects(items[0][@"title"], @"Keyed");
    XCTAssertEqualObjects(items[0][@"id"], @"keyed");
    XCTAssertEqualObjects(items[0][@"key"], @"k");
    XCTAssertEqualObjects(items[0][@"mods"], ([NSString stringWithFormat:@"0x%lx",
            (unsigned long)(NSEventModifierFlagCommand | NSEventModifierFlagShift)]));
    XCTAssertEqualObjects(items[0][@"action"], @"fire:");
    XCTAssertEqualObjects(items[0][@"enabled"], @YES);
    XCTAssertEqualObjects(items[1], @{@"separator": @YES});
    XCTAssertEqualObjects(items[2][@"hidden"], @YES);
    XCTAssertEqualObjects(items[3][@"state"], @(NSControlStateValueOn));
    XCTAssertNil(items[0][@"state"], @"an item that is off says nothing");
    XCTAssertEqualObjects(items[4][@"enabled"], @NO);
    XCTAssertEqualObjects([items[5][@"items"] firstObject][@"title"], @"Inner");
}

- (void)testClickMenuCallsTheAppsDispatchWithTheItemItFound {
    DebugVerbsMenuTarget *target = [DebugVerbsMenuTarget new];
    NSApp.mainMenu = [self menuWithTarget:target];
    NSObject *controller = [NSObject new];
    __block NSMenuItem *performed = nil;
    __block id seen = nil;
    VibeDebugStandardOptions *options = TestOptions();
    options.performMenuItem = ^BOOL(id given, NSMenuItem *item) {
        seen = given;
        performed = item;
        return item.isEnabled && !item.hasSubmenu;
    };
    NSArray<NSDictionary *> *table = VibeDebugStandardVerbs(options);

    NSDictionary *reply = JSONObject(Run(table, @[@"click_menu", @"keyed"], controller));
    XCTAssertEqualObjects(reply, (@{@"ok": @YES, @"clicked": @"Keyed", @"action": @"fire:", @"behind": @(NSApp.keyWindow == nil)}));
    XCTAssertEqualObjects(performed.identifier, @"keyed");
    XCTAssertEqual(seen, controller);
    XCTAssertEqual(target.fired, 0u, @"the app's dispatch ran, not NSApp's");

    XCTAssertEqualObjects(JSONObject(Run(table, @[@"click_menu", @"Inner"], controller))[@"clicked"], @"Inner",
                          @"the search reaches a nested submenu, by title");
    XCTAssertEqualObjects(JSONObject(Run(table, @[@"click_menu", @"Disabled"], controller)),
                          @{@"error": @"menu item 'Disabled' is disabled"});
    XCTAssertEqualObjects(JSONObject(Run(table, @[@"click_menu", @"Nested"], controller)),
                          @{@"error": @"menu item 'Nested' opens a submenu; click one of its items"});
    XCTAssertTrue([JSONObject(Run(table, @[@"click_menu", @"Absent"], controller))[@"error"]
                   hasPrefix:@"no menu item with identifier or title 'Absent'"]);
}

- (void)testClickMenuSendsTheActionWhenTheAppPassesNoDispatch {
    DebugVerbsMenuTarget *target = [DebugVerbsMenuTarget new];
    NSApp.mainMenu = [self menuWithTarget:target];
    NSArray<NSDictionary *> *table = VibeDebugStandardVerbs(TestOptions());
    XCTAssertEqualObjects(JSONObject(Run(table, @[@"click_menu", @"Keyed"], NSNull.null))[@"ok"], @YES);
    XCTAssertEqual(target.fired, 1u);
    XCTAssertEqualObjects(JSONObject(Run(table, @[@"click_menu", @"Hidden"], NSNull.null)),
                          @{@"error": @"menu item 'Hidden' is hidden"});
    XCTAssertEqualObjects(JSONObject(Run(table, @[@"click_menu", @"Nested"], NSNull.null)),
                          @{@"error": @"menu item 'Nested' opens a submenu; click one of its items"});
    XCTAssertEqual(target.fired, 1u);
}

- (void)testTheScreenshotIsTheWindowAtItsBackingScale {
    NSWindow *window = [self windowOfSize:NSMakeSize(120, 80)];
    window.contentView.wantsLayer = YES;
    [window orderFront:nil];
    NSString *path = TempPNGPath();
    XCTAssertTrue(VibeDumpWindowSnapshot(path));
    NSData *png = [NSData dataWithContentsOfFile:path];
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    const uint8_t signature[] = {0x89, 'P', 'N', 'G'};
    XCTAssertEqual(memcmp(png.bytes, signature, sizeof(signature)), 0);
    NSBitmapImageRep *image = [NSBitmapImageRep imageRepWithData:png];
    CGFloat scale = window.backingScaleFactor;
    XCTAssertEqual(image.pixelsWide, (NSInteger)llround(NSWidth(window.frame) * scale), @"the frame, title bar and all");
    XCTAssertEqual(image.pixelsHigh, (NSInteger)llround(NSHeight(window.frame) * scale));
}

- (void)testTheScreenshotVerbRendersTheTargetWindowOrItsSheet {
    NSWindow *window = [self windowOfSize:NSMakeSize(90, 60)];
    [window orderFront:nil];
    VibeDebugStandardOptions *options = TestOptions();
    options.targetWindow = ^NSWindow *(id controller) {
        return window;
    };
    NSArray<NSDictionary *> *table = VibeDebugStandardVerbs(options);
    NSDictionary *reply = JSONObject(Run(table, @[@"dump_screenshot", @"-"], NSNull.null));
    [NSFileManager.defaultManager removeItemAtPath:reply[@"path"] error:nil];
    XCTAssertEqualObjects(reply[@"ok"], @YES);
    XCTAssertNotNil(reply[@"path"], @"the key a client reads stays");
    XCTAssertEqualObjects(reply[@"render"], VibeDebugRenderNote, @"it says it is no capture");
    CGFloat scale = window.backingScaleFactor;
    XCTAssertEqualObjects(reply[@"width"], @(llround(NSWidth(window.frame) * scale)));
    XCTAssertEqualObjects(reply[@"height"], @(llround(NSHeight(window.frame) * scale)));
    XCTAssertEqualWithAccuracy([reply[@"scale"] doubleValue], scale, 0.001);
    XCTAssertEqualObjects(JSONObject(Run(table, @[@"dump_screenshot", @"sheet"], NSNull.null))[@"error"],
                          @"the window shows no sheet");
    NSWindow *sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 70, 40) styleMask:NSWindowStyleMaskTitled
                                                    backing:NSBackingStoreBuffered defer:NO];
    [window beginSheet:sheet completionHandler:nil];
    XCTAssertTrue(SpinUntil(^BOOL { return window.attachedSheet != nil; }));
    reply = JSONObject(Run(table, @[@"dump_screenshot", @"sheet", @"-"], NSNull.null));
    [NSFileManager.defaultManager removeItemAtPath:reply[@"path"] error:nil];
    XCTAssertEqualObjects(reply[@"width"], @(llround(NSWidth(sheet.frame) * scale)), @"the sheet alone");
    [window endSheet:sheet];
}

// A glass view's layer renders white, so the render hides it, and draws its
// content view on top in its place.
- (void)testAGlassViewsContentRendersInItsPlace {
    if (@available(macOS 26.0, *)) {
        NSWindow *window = [self windowOfSize:NSMakeSize(100, 60)];
        window.contentView.wantsLayer = YES;
        NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:NSMakeRect(0, 0, 50, 60)];
        NSView *content = [[NSView alloc] initWithFrame:glass.bounds];
        content.wantsLayer = YES;
        content.layer.backgroundColor = NSColor.redColor.CGColor;
        glass.contentView = content;
        [window.contentView addSubview:glass];
        [window orderFront:nil];
        [window displayIfNeeded];
        NSBitmapImageRep *image = Rendered(window);
        CGFloat scale = window.backingScaleFactor;
        NSColor *inside = ContentPixel(image, window, scale, 25, 30);
        NSColor *outside = ContentPixel(image, window, scale, 75, 30);
        XCTAssertGreaterThan(inside.redComponent, 0.8, @"the content renders: %@", inside);
        XCTAssertLessThan(inside.greenComponent, 0.3, @"not the glass's white: %@", inside);
        XCTAssertEqualWithAccuracy(outside.redComponent, outside.greenComponent, 0.05,
                                   @"beside the glass, the gray fill: %@", outside);
    }
    else {
        XCTSkip(@"NSGlassEffectView needs macOS 26");
    }
}

static BOOL IsRed(NSColor *color) {
    return color.redComponent > 0.8 && color.greenComponent < 0.3;
}

// X5: a scroll view under a window's toolbar insets its clip view, and its
// pocket's material covers what scrolls up under the toolbar on screen. The
// render puts a fill in the material's place, so the rows there stay hidden.
- (void)testWhatScrollsUnderTheToolbarStaysCovered {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 100, 300)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskFullSizeContentView
              backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    [_windows addObject:window];
    window.toolbar = [[NSToolbar alloc] initWithIdentifier:NSUUID.UUID.UUIDString];
    window.contentView.wantsLayer = YES;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:window.contentView.bounds];
    scroll.documentView = [[DebugVerbsBandView alloc] initWithFrame:NSMakeRect(0, 0, 100, 600)];
    [window.contentView addSubview:scroll];
    [window orderFront:nil];
    [window displayIfNeeded];
    CGFloat inset = scroll.contentInsets.top;
    XCTAssertGreaterThan(inset, 20, @"the scroll view sits under the toolbar");
    CGFloat scale = window.backingScaleFactor;
    // At the top, the band sits just below the inset.
    XCTAssertTrue(IsRed(ContentPixel(Rendered(window), window, scale, 50, inset + 10)), @"the band sits below the inset");
    // Scrolled 10 points, most of the band is under the inset, where the
    // pocket covers it.
    [scroll.documentView scrollPoint:NSMakePoint(0, 10 - inset)];
    [window displayIfNeeded];
    NSBitmapImageRep *scrolled = Rendered(window);
    for (CGFloat y = 2; y < inset; y += 4) {
        XCTAssertFalse(IsRed(ContentPixel(scrolled, window, scale, 50, y)), @"no band under the inset at %.0f", y);
    }
    XCTAssertTrue(IsRed(ContentPixel(scrolled, window, scale, 50, inset + 2)), @"the band's rest shows below it");
}

#pragma mark - The real capture

static BOOL Parse(NSArray<NSString *> *tokens, VibeDebugCaptureRequest *request, NSString **error) {
    return VibeDebugParseCaptureRequest([@[@"capture_window"] arrayByAddingObjectsFromArray:tokens], request, error);
}

- (void)testTheCapturesArgumentsParse {
    NSString *error = nil;
    VibeDebugCaptureRequest request;
    XCTAssertTrue(Parse(@[@"-"], &request, &error), @"the client's - is the client's");
    XCTAssertFalse(request.key);
    XCTAssertEqual(request.focus, VibeDebugCaptureFocusWindow);
    XCTAssertTrue(NSIsEmptyRect(request.crop));
    XCTAssertTrue(Parse(@[@"key", @"menu", @"crop", @"10", @"20", @"30.5", @"40", @"-"], &request, &error));
    XCTAssertTrue(request.key);
    XCTAssertEqual(request.focus, VibeDebugCaptureFocusMenu);
    XCTAssertTrue(NSEqualRects(request.crop, NSMakeRect(10, 20, 30.5, 40)));
    XCTAssertTrue(Parse(@[@"popover"], &request, &error));
    XCTAssertEqual(request.focus, VibeDebugCaptureFocusPopover);
    XCTAssertFalse(Parse(@[@"menu", @"popover"], &request, &error));
    XCTAssertEqualObjects(JSONObject(error)[@"error"], @"capture_window takes one of menu and popover, not both");
    for (NSArray<NSString *> *bad in @[@[@"crop", @"1", @"2", @"3"], @[@"crop", @"1", @"2", @"0", @"4"],
                                        @[@"crop", @"a", @"2", @"3", @"4"], @[@"window"]]) {
        error = nil;
        XCTAssertFalse(Parse(bad, &request, &error), @"%@", bad);
        XCTAssertNotNil(JSONObject(error)[@"error"], @"%@", bad);
    }
}

- (void)testTheCapturesRegionTakesInWhatSticksOutAndCrops {
    NSRect window = NSMakeRect(100, 100, 400, 300);
    NSArray<NSValue *> *none = @[];
    XCTAssertTrue(NSEqualRects(VibeDebugCaptureRegion(window, none, VibeDebugCaptureFocusWindow, NSZeroRect), window));
    // A menu below the window's bottom edge grows the region down.
    NSArray<NSValue *> *menu = @[[NSValue valueWithRect:NSMakeRect(150, 50, 100, 120)]];
    XCTAssertTrue(NSEqualRects(VibeDebugCaptureRegion(window, menu, VibeDebugCaptureFocusWindow, NSZeroRect),
                               NSMakeRect(100, 50, 400, 350)));
    // The menu alone, with a margin.
    XCTAssertTrue(NSEqualRects(VibeDebugCaptureRegion(window, menu, VibeDebugCaptureFocusMenu, NSZeroRect),
                               NSMakeRect(138, 38, 124, 144)));
    XCTAssertTrue(NSIsEmptyRect(VibeDebugCaptureRegion(window, none, VibeDebugCaptureFocusPopover, NSZeroRect)));
    // A crop runs from the region's top left, as a click's points do.
    XCTAssertTrue(NSEqualRects(VibeDebugCaptureRegion(window, none, VibeDebugCaptureFocusWindow,
                                                      NSMakeRect(10, 20, 50, 60)),
                               NSMakeRect(110, 320, 50, 60)));
    // Cut to the region, and empty off it.
    XCTAssertTrue(NSEqualRects(VibeDebugCaptureRegion(window, none, VibeDebugCaptureFocusWindow,
                                                      NSMakeRect(380, 0, 50, 10)),
                               NSMakeRect(480, 390, 20, 10)));
    XCTAssertTrue(NSIsEmptyRect(VibeDebugCaptureRegion(window, none, VibeDebugCaptureFocusWindow,
                                                       NSMakeRect(500, 0, 50, 10))));
    // The flip is its own inverse.
    NSRect rect = NSMakeRect(10, 20, 30, 40);
    XCTAssertTrue(NSEqualRects(VibeDebugFlipScreenRect(VibeDebugFlipScreenRect(rect)), rect));
}

// A hidden window has nothing for the window server to composite, and the
// verb says so, with its blocker, naming the in-process render.
- (void)testTheCaptureOfAHiddenWindowFailsPlainly {
    NSWindow *window = [self windowOfSize:NSMakeSize(80, 60)];
    NSString *kind = nil;
    NSString *blocker = VibeDebugCaptureBlocker(window, &kind);
    if ([kind isEqualToString:@"locked"] || [kind isEqualToString:@"asleep"]) {
        XCTSkip(@"%@", blocker);
    }
    XCTAssertEqualObjects(kind, @"hidden");
    XCTAssertTrue([blocker containsString:@"dump_screenshot"], @"%@", blocker);
    __block NSString *reply = nil;
    VibeDebugCaptureWindow(window, (VibeDebugCaptureRequest){0}, @"/nonexistent.png", ^(NSString *json) {
        reply = json;
    });
    XCTAssertEqualObjects(JSONObject(reply)[@"blocker"], @"hidden", @"%@", reply);
}

// The capture of window, its reply, and its image, or a skip where the window
// server draws nothing. The window server lists a window a moment after it
// orders in, so the capture tries again while it lists none.
- (NSDictionary *)captureOrSkip:(NSWindow *)window image:(NSBitmapImageRep **)image {
    NSString *blocker = VibeDebugCaptureBlocker(window, NULL);
    if (blocker) {
        XCTSkip(@"%@", blocker);
    }
    NSString *path = TempPNGPath();
    __block NSDictionary *answer = nil;
    for (NSUInteger tries = 0; tries < 10 && ![answer[@"ok"] boolValue]; tries++) {
        __block NSString *reply = nil;
        VibeDebugCaptureWindow(window, (VibeDebugCaptureRequest){0}, path, ^(NSString *json) {
            reply = json;
        });
        SpinUntil(^BOOL { return reply != nil; });
        answer = JSONObject(reply);
    }
    *image = [NSBitmapImageRep imageRepWithData:[NSData dataWithContentsOfFile:path]];
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    XCTAssertEqualObjects(answer[@"ok"], @YES, @"%@", answer);
    return answer;
}

// The real capture of a window the test shows: its points times its scale,
// and red where its content is red, with no permission.
- (void)testTheCaptureIsTheWindowAsTheWindowServerDrawsIt {
    NSWindow *window = [self windowOfSize:NSMakeSize(120, 80)];
    window.contentView.wantsLayer = YES;
    window.contentView.layer.backgroundColor = NSColor.redColor.CGColor;
    [window orderFront:nil];
    NSBitmapImageRep *image = nil;
    NSDictionary *answer = [self captureOrSkip:window image:&image];
    XCTAssertEqualObjects(answer[@"method"], @"ScreenCaptureKit");
    CGFloat scale = [answer[@"scale"] doubleValue];
    XCTAssertEqual(image.pixelsWide, (NSInteger)llround(NSWidth(window.frame) * scale), @"the frame, title bar and all");
    XCTAssertEqual(image.pixelsHigh, (NSInteger)llround(NSHeight(window.frame) * scale));
    XCTAssertTrue(IsRed(ContentPixel(image, window, scale, 60, 60)), @"%@", ContentPixel(image, window, scale, 60, 60));
    XCTAssertEqualObjects([answer[@"windows"] valueForKey:@"kind"], @[@"window"]);
}

// A window in front, which another app's would be, is left out: the target's
// own pixels show where it covers them.
- (void)testTheCaptureLeavesOutAWindowInFront {
    NSWindow *window = [self windowOfSize:NSMakeSize(120, 80)];
    window.contentView.wantsLayer = YES;
    window.contentView.layer.backgroundColor = NSColor.redColor.CGColor;
    [window orderFront:nil];
    NSWindow *cover = [self windowOfSize:NSMakeSize(200, 160)];
    [cover setFrameOrigin:NSMakePoint(NSMinX(window.frame) - 40, NSMinY(window.frame) - 40)];
    cover.contentView.wantsLayer = YES;
    cover.contentView.layer.backgroundColor = NSColor.blueColor.CGColor;
    [cover orderFront:nil];
    NSBitmapImageRep *image = nil;
    NSDictionary *answer = [self captureOrSkip:window image:&image];
    XCTAssertEqualObjects(answer[@"occluded"], @YES, @"the reply says a window covers it");
    NSColor *middle = ContentPixel(image, window, [answer[@"scale"] doubleValue], 60, 60);
    XCTAssertTrue(IsRed(middle), @"the target's red, not the cover's blue: %@", middle);
}

#pragma mark - The input table

// The key events a key verb sent, oldest first: from the queue while the app
// has a key window, and from window once the run loop delivers them when not.
static NSArray<NSEvent *> *SentKeys(DebugVerbsKeyWindow *window, NSString *json) {
    if ([JSONObject(json)[@"queued"] boolValue]) {
        return QueuedEvents(NSEventMaskKeyDown | NSEventMaskKeyUp);
    }
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    NSArray<NSEvent *> *keys = [window.keys copy];
    [window.keys removeAllObjects];
    return keys;
}

- (DebugVerbsKeyWindow *)keyWindowOfSize:(NSSize)size {
    DebugVerbsKeyWindow *window = [[DebugVerbsKeyWindow alloc] initWithContentRect:NSMakeRect(100, 100, size.width, size.height)
                                                                         styleMask:NSWindowStyleMaskTitled
                                                                           backing:NSBackingStoreBuffered
                                                                             defer:NO];
    window.releasedWhenClosed = NO;
    [_windows addObject:window];
    return window;
}

- (void)testTheKeyVerbsSendWhatARealKeyCarries {
    DebugVerbsKeyWindow *window = [self keyWindowOfSize:NSMakeSize(100, 100)];
    VibeDebugStandardOptions *options = TestOptions();
    options.targetWindow = ^NSWindow *(id controller) {
        return window;
    };
    NSArray<NSDictionary *> *table = VibeDebugInputVerbs(options);

    NSString *json = Run(table, @[@"key", @"a", @"shift"], NSNull.null);
    XCTAssertEqualObjects(JSONObject(json), (@{@"ok": @YES, @"posted": @"key", @"key": @"a", @"repeat": @NO,
                                               @"queued": @(NSApp.keyWindow != nil)}));
    NSArray<NSEvent *> *events = SentKeys(window, json);
    XCTAssertEqual(events.count, 2u);
    XCTAssertEqual(events[0].type, NSEventTypeKeyDown);
    XCTAssertEqual(events[1].type, NSEventTypeKeyUp);
    XCTAssertEqual(events[0].keyCode, 0);
    XCTAssertEqualObjects(events[0].characters, @"A");
    XCTAssertEqualObjects(events[0].charactersIgnoringModifiers, @"A",
                          @"hardware carries the shifted character in both fields");
    XCTAssertTrue(events[0].modifierFlags & NSEventModifierFlagShift);

    json = Run(table, @[@"key", @"1", @"shift"], NSNull.null);
    XCTAssertEqualObjects(SentKeys(window, json).firstObject.characters, @"!");

    json = Run(table, @[@"key_down", @"left", @"repeat"], NSNull.null);
    events = SentKeys(window, json);
    XCTAssertEqual(events.count, 1u, @"key_down sends one edge");
    XCTAssertEqual(events[0].keyCode, 123);
    XCTAssertTrue(events[0].isARepeat);
    XCTAssertTrue(events[0].modifierFlags & NSEventModifierFlagFunction);
    XCTAssertTrue(events[0].modifierFlags & NSEventModifierFlagNumericPad);
    XCTAssertEqual([events[0].characters characterAtIndex:0], (unichar)NSLeftArrowFunctionKey);

    json = Run(table, @[@"key_up", @"space", @"cmd"], NSNull.null);
    events = SentKeys(window, json);
    XCTAssertEqual(events.count, 1u);
    XCTAssertEqual(events[0].type, NSEventTypeKeyUp);
    XCTAssertTrue(events[0].modifierFlags & NSEventModifierFlagCommand);
    XCTAssertFalse(events[0].modifierFlags & NSEventModifierFlagFunction);

    XCTAssertNotNil(JSONObject(Run(table, @[@"key", @"nope"], NSNull.null))[@"error"]);
    XCTAssertNotNil(JSONObject(Run(table, @[@"key", @"a", @"hyper"], NSNull.null))[@"error"]);
}

- (void)testWithNoKeyWindowAKeyReachesTheTargetWindowAsAKeyWindowGetsIt {
    if (NSApp.keyWindow) {
        XCTSkip(@"an earlier test left a key window");
    }
    DebugVerbsKeyWindow *window = [self keyWindowOfSize:NSMakeSize(100, 100)];
    VibeDebugStandardOptions *options = TestOptions();
    options.targetWindow = ^NSWindow *(id controller) {
        return window;
    };
    NSArray<NSDictionary *> *table = VibeDebugInputVerbs(options);

    NSString *json = Run(table, @[@"key", @"k", @"cmd"], NSNull.null);
    XCTAssertEqualObjects(JSONObject(json)[@"queued"], @NO);
    XCTAssertEqual(window.keys.count, 0u, @"nothing arrives before the reply");
    NSArray<NSEvent *> *events = SentKeys(window, json);
    XCTAssertEqual(window.equivalents.count, 1u, @"Command asks the window's views first");
    XCTAssertEqual(window.equivalents.firstObject.type, NSEventTypeKeyDown);
    XCTAssertEqual(events.count, 2u, @"then the window gets the down, and the up");
    XCTAssertEqual(QueuedEvents(NSEventMaskKeyDown | NSEventMaskKeyUp).count, 0u, @"nothing went to the queue");

    [window.equivalents removeAllObjects];
    json = Run(table, @[@"key", @"space"], NSNull.null);
    XCTAssertEqual(SentKeys(window, json).count, 2u);
    XCTAssertEqual(window.equivalents.count, 0u, @"a key with no Command goes to the window alone");
}

- (void)testWithNoKeyWindowAShortcutFindsAMenuItemsTargetInTheWindowsChain {
    if (NSApp.keyWindow) {
        XCTSkip(@"an earlier test left a key window");
    }
    NSWindow *window = [self windowOfSize:NSMakeSize(100, 100)];
    DebugVerbsWindowController *controller = [[DebugVerbsWindowController alloc] initWithWindow:window];
    NSMenu *bar = [NSMenu new];
    NSMenuItem *top = [NSMenuItem new];
    [bar addItem:top];
    top.submenu = [[NSMenu alloc] initWithTitle:@"File"];
    [top.submenu addItemWithTitle:@"Fire" action:@selector(fire:) keyEquivalent:@"k"];
    NSApp.mainMenu = bar;
    XCTAssertNil([NSApp targetForAction:@selector(fire:)], @"with no key window, NSApp finds no target");

    VibeDebugStandardOptions *options = TestOptions();
    options.targetWindow = ^NSWindow *(id unused) {
        return window;
    };
    Run(VibeDebugInputVerbs(options), @[@"key", @"k", @"cmd"], NSNull.null);
    XCTAssertEqual(controller.fired, 0u, @"it fires after the reply");
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    XCTAssertEqual(controller.fired, 1u, @"the window's own chain reached its controller");
}

- (void)testWithNoKeyWindowClickMenuFindsAnItemsTargetInTheTargetWindowsChain {
    if (NSApp.keyWindow) {
        XCTSkip(@"an earlier test left a key window");
    }
    NSWindow *window = [self windowOfSize:NSMakeSize(100, 100)];
    DebugVerbsWindowController *controller = [[DebugVerbsWindowController alloc] initWithWindow:window];
    NSMenu *bar = [NSMenu new];
    NSMenuItem *top = [NSMenuItem new];
    [bar addItem:top];
    top.submenu = [[NSMenu alloc] initWithTitle:@"File"];
    [top.submenu addItemWithTitle:@"Fire" action:@selector(fire:) keyEquivalent:@"k"];
    NSApp.mainMenu = bar;
    VibeDebugStandardOptions *options = TestOptions();
    NSArray<NSDictionary *> *table = VibeDebugStandardVerbs(options);

    XCTAssertTrue([JSONObject(Run(table, @[@"click_menu", @"Fire"], NSNull.null))[@"error"]
                          hasPrefix:@"menu item 'Fire' is disabled while the app is behind"],
                  @"with no target window, the item finds no target");
    options.targetWindow = ^NSWindow *(id unused) {
        return window;
    };
    NSDictionary *items = JSONObject(Run(table, @[@"dump_menu"], NSNull.null));
    XCTAssertEqualObjects(items[@"menu"][0][@"items"][0][@"enabled"], @YES, @"the dump validates as a click would");
    XCTAssertEqualObjects(JSONObject(Run(table, @[@"click_menu", @"Fire"], NSNull.null)),
                          (@{@"ok": @YES, @"clicked": @"Fire", @"action": @"fire:", @"behind": @YES}));
    XCTAssertEqual(controller.fired, 1u);
    XCTAssertNil([NSApp targetForAction:@selector(fire:)], @"outside a verb, AppKit's lookup is its own");
}

// A window that isn't key swallows a first click, so behind, each mouse verb
// fails with nothing posted, and says to run activate.
- (void)testBehindEachMouseVerbFailsAndPostsNothing {
    if (NSApp.isActive) {
        XCTSkip(@"the test process is the active app");
    }
    NSWindow *window = [self windowOfSize:NSMakeSize(100, 100)];
    [window orderFront:nil];
    // The default, which the other tests turn off.
    VibeDebugStandardOptions *options = [VibeDebugStandardOptions new];
    XCTAssertTrue(options.requiresKeyWindow);
    options.targetWindow = ^NSWindow *(id controller) {
        return window;
    };
    NSArray<NSDictionary *> *input = VibeDebugInputVerbs(options);
    NSArray<NSArray<NSString *> *> *commands = @[
        @[@"click", @"10", @"10"], @[@"mouse_down", @"10", @"10"], @[@"mouse_up", @"10", @"10"],
        @[@"mouse_move", @"10", @"10"], @[@"drag", @"10", @"10", @"50", @"50"],
    ];
    for (NSArray<NSString *> *command in commands) {
        NSString *error = JSONObject(Run(input, command, NSNull.null))[@"error"];
        XCTAssertTrue([error hasPrefix:[command.firstObject stringByAppendingString:@" would be swallowed"]], @"%@", error);
        XCTAssertTrue([error containsString:@"Run `activate` first"], @"%@", error);
    }
    XCTAssertEqual(QueuedEvents(NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged
                                | NSEventMaskMouseMoved).count, 0u, @"nothing went to the queue");
    XCTAssertNil(Run(input, @[@"activate"], NSNull.null), @"activate replies later");
    __block BOOL answered = NO;
    VibeDebugActivateWindow(window, ^(NSString *error) {
        answered = YES;
    });
    XCTAssertTrue(SpinUntil(^BOOL { return answered; }), @"it answers within its 5 s, either way");
}

// Behind, click_menu still sends through the stand-in, and its reply says so.
// An item with no target that reads disabled then says the app being behind
// may be why (testWithNoKeyWindowClickMenuFinds…).
- (void)testBehindClickMenuSaysSo {
    if (NSApp.keyWindow) {
        XCTSkip(@"an earlier test left a key window");
    }
    DebugVerbsMenuTarget *target = [DebugVerbsMenuTarget new];
    NSApp.mainMenu = [self menuWithTarget:target];
    NSArray<NSDictionary *> *table = VibeDebugStandardVerbs(TestOptions());
    NSDictionary *reply = JSONObject(Run(table, @[@"click_menu", @"Keyed"], NSNull.null));
    XCTAssertEqualObjects(reply[@"behind"], @YES, @"%@", reply);
    XCTAssertEqual(target.fired, 1u);
    XCTAssertEqualObjects(JSONObject(Run(table, @[@"click_menu", @"Disabled"], NSNull.null))[@"error"],
                          @"menu item 'Disabled' is disabled", @"an item with its own target isn't the stand-in's");
    XCTAssertEqualObjects(JSONObject(Run(table, @[@"dump_menu"], NSNull.null))[@"appActive"], @(NSApp.isActive));
}

- (void)testClickPostsADownAndAnUpPerCountWithTheCountAscending {
    NSWindow *window = [self windowOfSize:NSMakeSize(100, 100)];
    // Key, as a run makes it with activate, as the verbs did themselves
    // before. On CI, a window that isn't key read its events' points as the
    // screen's.
    VibeMakeWindowKeyForInjection(window);
    VibeDebugStandardOptions *options = TestOptions();
    options.targetWindow = ^NSWindow *(id controller) {
        return window;
    };
    // Never asserts key status: activation may not take on CI.
    NSDictionary *reply = JSONObject(Run(VibeDebugInputVerbs(options), @[@"click", @"10", @"20", @"left", @"2"],
                                         NSNull.null));
    XCTAssertEqualObjects(reply[@"ok"], @YES);
    XCTAssertEqualObjects(reply[@"posted"], @"click");
    NSArray<NSEvent *> *events = QueuedEvents(NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp);
    XCTAssertEqual(events.count, 4u);
    NSArray *types = @[@(NSEventTypeLeftMouseDown), @(NSEventTypeLeftMouseUp),
                       @(NSEventTypeLeftMouseDown), @(NSEventTypeLeftMouseUp)];
    for (NSUInteger i = 0; i < events.count && i < 4; i++) {
        XCTAssertEqual(events[i].type, [types[i] unsignedIntegerValue]);
        XCTAssertEqual(events[i].clickCount, (NSInteger)(i / 2 + 1));
        XCTAssertEqual(events[i].windowNumber, window.windowNumber);
        NSPoint point = VibeContentPointForWindowPoint(window, events[i].locationInWindow);
        XCTAssertEqualWithAccuracy(point.x, 10, 0.001);
        XCTAssertEqualWithAccuracy(point.y, 20, 0.001, @"content points have a top-left origin");
    }
}

- (void)testDragPostsItsStepsBetweenOneDownAndOneUp {
    NSWindow *window = [self windowOfSize:NSMakeSize(100, 100)];
    // Key, as a run makes it with activate, as the verbs did themselves
    // before. On CI, a window that isn't key read its events' points as the
    // screen's.
    VibeMakeWindowKeyForInjection(window);
    VibeDebugStandardOptions *options = TestOptions();
    options.targetWindow = ^NSWindow *(id controller) {
        return window;
    };
    Run(VibeDebugInputVerbs(options), @[@"drag", @"0", @"10", @"40", @"10", @"4"], NSNull.null);
    NSArray<NSEvent *> *events = QueuedEvents(NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp
                                              | NSEventMaskLeftMouseDragged);
    XCTAssertEqual(events.count, 6u);
    XCTAssertEqual(events.firstObject.type, NSEventTypeLeftMouseDown);
    XCTAssertEqual(events.lastObject.type, NSEventTypeLeftMouseUp);
    for (NSUInteger i = 1; i + 1 < events.count; i++) {
        XCTAssertEqual(events[i].type, NSEventTypeLeftMouseDragged);
        XCTAssertEqualWithAccuracy(VibeContentPointForWindowPoint(window, events[i].locationInWindow).x,
                                   10.0 * i, 0.001);
    }
}

- (void)testTheModifierParserAndTheKeyCodes {
    NSEventModifierFlags flags = 0;
    BOOL repeat = NO;
    NSString *error = nil;
    XCTAssertTrue(VibeParseModifiers(@[@"key", @"a", @"CMD", @"opt", @"ctrl", @"repeat"], 2, &flags, &repeat, &error));
    XCTAssertEqual(flags, NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl);
    XCTAssertTrue(repeat);
    XCTAssertFalse(VibeParseModifiers(@[@"key", @"a", @"meta"], 2, &flags, &repeat, &error));
    XCTAssertNotNil(JSONObject(error)[@"error"]);
    XCTAssertEqualObjects(VibeKeyCodeForName(@"return"), @36);
    XCTAssertNil(VibeKeyCodeForName(@"Return"), @"names are lowercase");
}

#pragma mark - The windows that ask

// Runs the block on the main queue's next turn, as the channel runs a verb,
// so it lands inside whatever loop main then spins.
static void OnMainsNextTurn(dispatch_block_t block) {
    dispatch_async(dispatch_get_main_queue(), block);
}

static NSAlert *AlertOfTwoButtons(void) {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Asks";
    alert.informativeText = @"Why it asks";
    [alert addButtonWithTitle:@"First"];
    [alert addButtonWithTitle:@"Second"];
    return alert;
}

- (void)testAnAppModalAlertIsReadAndItsPressEndsTheSessionWithThatButton {
    NSAlert *alert = AlertOfTwoButtons();
    __block NSDictionary *read = nil;
    __block NSDictionary *pressed = nil;
    OnMainsNextTurn(^{
        read = JSONObject(VibeDebugAnswerModal(@[], nil));
        pressed = JSONObject(VibeDebugAnswerModal(@[], @"Second"));
    });
    // A guard, so a press that never ends the session fails, not hangs.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (NSApp.modalWindow == alert.window) {
            [NSApp abortModal];
        }
    });
    NSModalResponse response = [alert runModal];
    XCTAssertEqual(response, NSAlertSecondButtonReturn, @"the press ends the session with its button");
    XCTAssertEqualObjects(read[@"modal"], @YES);
    XCTAssertEqualObjects(read[@"sheet"], @NO);
    XCTAssertEqualObjects(read[@"panel"], @NO);
    XCTAssertEqualObjects(read[@"texts"], (@[@"Asks", @"Why it asks"]));
    XCTAssertEqualObjects([NSSet setWithArray:read[@"buttons"]], ([NSSet setWithArray:@[@"First", @"Second"]]),
                          @"in the view tree's order");
    XCTAssertEqualObjects(pressed[@"pressed"], @"Second");
    XCTAssertEqualObjects(JSONObject(VibeDebugAnswerModal(@[], nil)), (@{@"ok": @YES, @"sheet": @NO, @"modal": @NO}),
                          @"none asks once it ends");
}

- (void)testASheetIsReadAndPressedAndAnUnknownButtonIsRefused {
    NSWindow *window = [self windowOfSize:NSMakeSize(400, 300)];
    [window orderFront:nil];
    NSAlert *alert = AlertOfTwoButtons();
    __block NSModalResponse response = 0;
    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse returned) {
        response = returned;
    }];
    XCTAssertTrue(SpinUntil(^BOOL { return window.attachedSheet != nil; }));
    NSWindow *other = [self windowOfSize:NSMakeSize(100, 100)];
    NSDictionary *read = JSONObject(VibeDebugAnswerModal(@[other, window], nil));
    XCTAssertEqualObjects(read[@"sheet"], @YES, @"the first owner with a sheet");
    for (NSString *key in @[@"sheet", @"modal", @"panel"]) {
        XCTAssertEqual(CFGetTypeID((__bridge CFTypeRef)read[key]), CFBooleanGetTypeID(), @"%@ is true or false", key);
    }
    XCTAssertEqualObjects(read[@"modal"], @NO);
    XCTAssertEqualObjects([NSSet setWithArray:read[@"buttons"]], ([NSSet setWithArray:@[@"First", @"Second"]]));
    XCTAssertNotNil(JSONObject(VibeDebugAnswerModal(@[window], @"Third"))[@"error"]);
    // The verb looks past a target window with no sheet, to any window's.
    VibeDebugStandardOptions *options = TestOptions();
    options.targetWindow = ^NSWindow *(id controller) {
        return other;
    };
    NSArray<NSDictionary *> *table = VibeDebugStandardVerbs(options);
    XCTAssertEqualObjects(JSONObject(Run(table, @[@"answer_sheet"], NSNull.null))[@"sheet"], @YES);
    XCTAssertEqualObjects(JSONObject(Run(table, @[@"answer_sheet", @"First"], NSNull.null))[@"pressed"], @"First");
    XCTAssertTrue(SpinUntil(^BOOL { return response != 0; }));
    XCTAssertEqual(response, NSAlertFirstButtonReturn);
}

- (void)testAPanelSheetSaysSoAndItsCancelEndsIt {
    NSWindow *window = [self windowOfSize:NSMakeSize(600, 400)];
    [window orderFront:nil];
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.message = @"Where it goes";
    [panel beginSheetModalForWindow:window completionHandler:^(NSModalResponse returned) {
    }];
    XCTAssertTrue(SpinUntil(^BOOL { return window.attachedSheet != nil; }));
    NSDictionary *read = JSONObject(VibeDebugAnswerModal(@[window], nil));
    XCTAssertEqualObjects(read[@"panel"], @YES);
    XCTAssertEqualObjects(read[@"texts"], @[@"Where it goes"]);
    XCTAssertEqualObjects(read[@"buttons"], @[@"Cancel"], @"a panel's one button");
    XCTAssertNotNil(JSONObject(VibeDebugAnswerModal(@[window], @"Save"))[@"error"]);
    XCTAssertEqualObjects(JSONObject(VibeDebugAnswerModal(@[window], @"Cancel"))[@"pressed"], @"Cancel");
    // TRAP: host-less, NSApp never runs, and a panel's completion never
    // comes, even after endSheet:. So the sheet's end is the check here, and
    // the app's live check sees the completion.
    XCTAssertTrue(SpinUntil(^BOOL { return window.attachedSheet == nil; }), @"its own cancel: ends it");
}

- (void)testAShownPopoverIsListedPressedAndClosed {
    NSWindow *window = [self windowOfSize:NSMakeSize(300, 200)];
    [window orderFront:nil];
    DebugVerbsMenuTarget *target = [DebugVerbsMenuTarget new];
    NSViewController *content = [[NSViewController alloc] init];
    content.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 80)];
    NSTextField *label = [NSTextField labelWithString:@"What it says"];
    label.frame = NSMakeRect(10, 50, 180, 20);
    NSButton *button = [NSButton buttonWithTitle:@"Do It" target:target action:@selector(fire:)];
    button.frame = NSMakeRect(10, 10, 100, 30);
    NSButton *hidden = [NSButton buttonWithTitle:@"Hidden" target:target action:@selector(fire:)];
    hidden.hidden = YES;
    [content.view addSubview:label];
    [content.view addSubview:button];
    [content.view addSubview:hidden];
    NSPopover *popover = [[NSPopover alloc] init];
    popover.contentViewController = content;
    [popover showRelativeToRect:NSMakeRect(10, 10, 20, 20) ofView:(NSView *)window.contentView
                  preferredEdge:NSRectEdgeMaxY];
    XCTAssertEqual(VibeDebugShownPopovers().count, 1u, @"from its show on, before its animation ends");

    NSArray<NSDictionary *> *table = VibeDebugStandardVerbs(TestOptions());
    NSDictionary *read = JSONObject(Run(table, @[@"answer_popover"], NSNull.null));
    XCTAssertEqualObjects(read[@"popovers"], (@[@{@"index": @0, @"content": @"NSViewController",
                                                  @"texts": @[@"What it says"], @"buttons": @[@"Do It"]}]));
    XCTAssertNotNil(JSONObject(Run(table, @[@"answer_popover", @"1", @"close"], NSNull.null))[@"error"]);
    XCTAssertNotNil(JSONObject(Run(table, @[@"answer_popover", @"0", @"Hidden"], NSNull.null))[@"error"],
                    @"a hidden button is not pressed");
    XCTAssertEqualObjects(JSONObject(Run(table, @[@"answer_popover", @"0", @"Do", @"It"], NSNull.null))[@"pressed"],
                          @"Do It", @"the title is the rest of the tokens");
    XCTAssertEqual(target.fired, 1u);
    XCTAssertEqualObjects(JSONObject(Run(table, @[@"answer_popover", @"0", @"close"], NSNull.null))[@"closed"], @YES);
    XCTAssertTrue(SpinUntil(^BOOL { return !popover.shown; }));
    XCTAssertEqualObjects(JSONObject(Run(table, @[@"answer_popover"], NSNull.null))[@"popovers"], @[]);
}

- (void)testAPoppedUpMenuIsListedAndItsTrackingCancelledFromMain {
    NSWindow *window = [self windowOfSize:NSMakeSize(300, 200)];
    [window makeKeyAndOrderFront:nil];
    DebugVerbsMenuTarget *target = [DebugVerbsMenuTarget new];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Pops"];
    [menu addItemWithTitle:@"One" action:@selector(fire:) keyEquivalent:@""].target = target;
    [menu addItemWithTitle:@"Two" action:@selector(fire:) keyEquivalent:@""].target = target;
    NSArray<NSDictionary *> *table = VibeDebugStandardVerbs(TestOptions());
    __block NSDictionary *read = nil;
    __block NSDictionary *cancelled = nil;
    OnMainsNextTurn(^{
        read = JSONObject(Run(table, @[@"answer_menu"], NSNull.null));
        cancelled = JSONObject(Run(table, @[@"answer_menu", @"cancel"], NSNull.null));
    });
    // A guard, so a cancel that never lands fails, not hangs.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [menu cancelTracking];
    });
    // It returns once its tracking ends.
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(20, 20) inView:window.contentView];
    XCTAssertNotNil(read, @"main's queue runs while the menu tracks");
    NSArray *menus = read[@"menus"];
    XCTAssertEqual(menus.count, 1u);
    XCTAssertEqualObjects(menus.firstObject[@"title"], @"Pops");
    XCTAssertEqualObjects([menus.firstObject[@"items"] valueForKey:@"title"], (@[@"One", @"Two"]));
    XCTAssertEqualObjects(cancelled[@"cancelled"], @1);
    XCTAssertEqual(target.fired, 0u, @"a cancel sends no item");
    XCTAssertTrue(SpinUntil(^BOOL { return VibeDebugTrackingMenus().count == 0; }));
    XCTAssertNotNil(JSONObject(Run(table, @[@"answer_menu", @"pick"], NSNull.null))[@"error"]);
}

@end
