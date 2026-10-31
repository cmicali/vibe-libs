// The standard table and the input table, run through their handlers as an
// app's dispatcher runs them, with options and a controller of the test's
// own. The input verbs' events are read back from the app's own queue.

#import <XCTest/XCTest.h>
#import <AppKit/AppKit.h>

#import "DebugCommandDispatch.h"
#import "DebugProcessHealth.h"
#import "DebugScreenshot.h"
#import "DebugStandardVerbs.h"
#import "DebugSyntheticInput.h"
#import "DebugViewTree.h"
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

@implementation DebugVerbsTests {
    NSMutableArray<NSWindow *> *_windows;
    NSMenu *_mainMenu;
}

static id JSONObject(NSString *json) {
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
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
    VibeDebugStandardOptions *options = [VibeDebugStandardOptions new];
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
    XCTAssertEqual([NSSet setWithArray:verbs].count, verbs.count, @"no verb is in two places: %@", verbs);
    XCTAssertEqualObjects([NSSet setWithArray:verbs], ([NSSet setWithArray:@[
        @"dump_build", @"quit", @"work_tally", @"dump_health", @"block_main", @"block_main_deep",
        @"dump_view_tree", @"dump_menu", @"click_menu", @"dump_screenshot", @"raise_window",
        @"key", @"key_down", @"key_up", @"click", @"mouse_down", @"mouse_up", @"mouse_move", @"drag", @"scroll",
    ]]));

    NSDictionary *waits = @{@"block_main": @30, @"block_main_deep": @30, @"dump_health": @10};
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
    VibeDebugStandardOptions *options = [VibeDebugStandardOptions new];
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
    VibeDebugStandardOptions *options = [VibeDebugStandardOptions new];
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
    VibeDebugStandardOptions *options = [VibeDebugStandardOptions new];
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
    NSArray<NSDictionary *> *table = VibeDebugStandardVerbs([VibeDebugStandardOptions new]);
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
    NSDictionary *reply = JSONObject(Run(VibeDebugStandardVerbs([VibeDebugStandardOptions new]), @[@"dump_menu"],
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
    VibeDebugStandardOptions *options = [VibeDebugStandardOptions new];
    options.performMenuItem = ^BOOL(id given, NSMenuItem *item) {
        seen = given;
        performed = item;
        return item.isEnabled && !item.hasSubmenu;
    };
    NSArray<NSDictionary *> *table = VibeDebugStandardVerbs(options);

    NSDictionary *reply = JSONObject(Run(table, @[@"click_menu", @"keyed"], controller));
    XCTAssertEqualObjects(reply, (@{@"ok": @YES, @"clicked": @"Keyed", @"action": @"fire:"}));
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
    NSArray<NSDictionary *> *table = VibeDebugStandardVerbs([VibeDebugStandardOptions new]);
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
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"debug-verbs-%@.png", NSUUID.UUID.UUIDString]];
    XCTAssertTrue(VibeDumpWindowSnapshot(path));
    NSData *png = [NSData dataWithContentsOfFile:path];
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    const uint8_t signature[] = {0x89, 'P', 'N', 'G'};
    XCTAssertEqual(memcmp(png.bytes, signature, sizeof(signature)), 0);
    NSBitmapImageRep *image = [NSBitmapImageRep imageRepWithData:png];
    CGFloat scale = window.backingScaleFactor;
    XCTAssertEqual(image.pixelsWide, (NSInteger)llround(120 * scale));
    XCTAssertEqual(image.pixelsHigh, (NSInteger)llround(80 * scale));
}

- (void)testTheScreenshotVerbAnswersItsFileSizeAndScale {
    NSWindow *window = [self windowOfSize:NSMakeSize(90, 60)];
    [window orderFront:nil];
    NSDictionary *reply = JSONObject(Run(VibeDebugStandardVerbs([VibeDebugStandardOptions new]),
                                         @[@"dump_screenshot"], NSNull.null));
    [NSFileManager.defaultManager removeItemAtPath:reply[@"path"] error:nil];
    XCTAssertEqualObjects(reply[@"ok"], @YES);
    XCTAssertNotNil(reply[@"path"], @"the key a client reads stays");
    CGFloat scale = window.backingScaleFactor;
    XCTAssertEqualObjects(reply[@"width"], @(llround(90 * scale)));
    XCTAssertEqualObjects(reply[@"height"], @(llround(60 * scale)));
    XCTAssertEqualWithAccuracy([reply[@"scale"] doubleValue], scale, 0.001);
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
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"debug-verbs-%@.png", NSUUID.UUID.UUIDString]];
        XCTAssertTrue(VibeDumpWindowSnapshot(path));
        NSBitmapImageRep *image = [NSBitmapImageRep imageRepWithData:[NSData dataWithContentsOfFile:path]];
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        CGFloat scale = window.backingScaleFactor;
        NSColor *inside = [[image colorAtX:(NSInteger)(25 * scale) y:(NSInteger)(30 * scale)]
                colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        NSColor *outside = [[image colorAtX:(NSInteger)(75 * scale) y:(NSInteger)(30 * scale)]
                colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        XCTAssertGreaterThan(inside.redComponent, 0.8, @"the content renders: %@", inside);
        XCTAssertLessThan(inside.greenComponent, 0.3, @"not the glass's white: %@", inside);
        XCTAssertEqualWithAccuracy(outside.redComponent, outside.greenComponent, 0.05,
                                   @"beside the glass, the gray fill: %@", outside);
    }
    else {
        XCTSkip(@"NSGlassEffectView needs macOS 26");
    }
}

#pragma mark - The input table

- (void)testTheKeyVerbsPostWhatARealKeyCarries {
    NSWindow *window = [self windowOfSize:NSMakeSize(100, 100)];
    VibeDebugStandardOptions *options = [VibeDebugStandardOptions new];
    options.targetWindow = ^NSWindow *(id controller) {
        return window;
    };
    NSArray<NSDictionary *> *table = VibeDebugInputVerbs(options);

    XCTAssertEqualObjects(JSONObject(Run(table, @[@"key", @"a", @"shift"], NSNull.null)),
                          (@{@"ok": @YES, @"posted": @"key", @"key": @"a", @"repeat": @NO}));
    NSArray<NSEvent *> *events = QueuedEvents(NSEventMaskKeyDown | NSEventMaskKeyUp);
    XCTAssertEqual(events.count, 2u);
    XCTAssertEqual(events[0].type, NSEventTypeKeyDown);
    XCTAssertEqual(events[1].type, NSEventTypeKeyUp);
    XCTAssertEqual(events[0].keyCode, 0);
    XCTAssertEqualObjects(events[0].characters, @"A");
    XCTAssertEqualObjects(events[0].charactersIgnoringModifiers, @"A",
                          @"hardware carries the shifted character in both fields");
    XCTAssertTrue(events[0].modifierFlags & NSEventModifierFlagShift);

    Run(table, @[@"key", @"1", @"shift"], NSNull.null);
    XCTAssertEqualObjects(QueuedEvents(NSEventMaskKeyDown | NSEventMaskKeyUp).firstObject.characters, @"!");

    Run(table, @[@"key_down", @"left", @"repeat"], NSNull.null);
    events = QueuedEvents(NSEventMaskKeyDown | NSEventMaskKeyUp);
    XCTAssertEqual(events.count, 1u, @"key_down posts one edge");
    XCTAssertEqual(events[0].keyCode, 123);
    XCTAssertTrue(events[0].isARepeat);
    XCTAssertTrue(events[0].modifierFlags & NSEventModifierFlagFunction);
    XCTAssertTrue(events[0].modifierFlags & NSEventModifierFlagNumericPad);
    XCTAssertEqual([events[0].characters characterAtIndex:0], (unichar)NSLeftArrowFunctionKey);

    Run(table, @[@"key_up", @"space", @"cmd"], NSNull.null);
    events = QueuedEvents(NSEventMaskKeyDown | NSEventMaskKeyUp);
    XCTAssertEqual(events.count, 1u);
    XCTAssertEqual(events[0].type, NSEventTypeKeyUp);
    XCTAssertTrue(events[0].modifierFlags & NSEventModifierFlagCommand);
    XCTAssertFalse(events[0].modifierFlags & NSEventModifierFlagFunction);

    XCTAssertNotNil(JSONObject(Run(table, @[@"key", @"nope"], NSNull.null))[@"error"]);
    XCTAssertNotNil(JSONObject(Run(table, @[@"key", @"a", @"hyper"], NSNull.null))[@"error"]);
}

- (void)testClickPostsADownAndAnUpPerCountWithTheCountAscending {
    NSWindow *window = [self windowOfSize:NSMakeSize(100, 100)];
    VibeDebugStandardOptions *options = [VibeDebugStandardOptions new];
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
    VibeDebugStandardOptions *options = [VibeDebugStandardOptions new];
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

@end
