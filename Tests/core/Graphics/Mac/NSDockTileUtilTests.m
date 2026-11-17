//
//  The picture on the system's icon grid: its canvas, its margin, its rounded
//  corners, and its fit. The tile itself needs a running app, so an app's own
//  checks cover it.
//

#import <XCTest/XCTest.h>
#import <AppKit/AppKit.h>
#import "NSDockTile+Util.h"
#import "NSImage+Util.h"

@interface NSDockTileUtilTests : XCTestCase
@end

@implementation NSDockTileUtilTests

- (NSColor *)magenta {
    return [NSColor colorWithSRGBRed:1 green:0 blue:1 alpha:1];
}

- (NSImage *)imageOfColor:(NSColor *)color size:(NSSize)size {
    return [NSImage imageWithSize:size drawnBy:^{
        [color setFill];
        NSRectFill(NSMakeRect(0, 0, size.width, size.height));
    }];
}

// x and y from the top-left, as the bitmap counts them.
- (NSColor *)colorAtX:(NSInteger)x y:(NSInteger)y in:(NSImage *)image {
    NSBitmapImageRep *rep = (NSBitmapImageRep *)image.representations.firstObject;
    XCTAssertTrue([rep isKindOfClass:NSBitmapImageRep.class]);
    return [[rep colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
}

- (void)testTheIconFillsTheGridsContentSquare {
    NSImage *icon = VibeMacStyleIconFromImage([self imageOfColor:self.magenta size:NSMakeSize(200, 200)],
                                              1024);
    XCTAssertEqualWithAccuracy(icon.size.width, 1024, 0.5);
    XCTAssertEqualWithAccuracy(icon.size.height, 1024, 0.5);
    // The content square is 824 points, so its margin is 100.
    for (NSValue *point in @[@(NSMakePoint(512, 512)), @(NSMakePoint(512, 120)), @(NSMakePoint(512, 904)),
                             @(NSMakePoint(120, 512)), @(NSMakePoint(904, 512))]) {
        NSColor *color = [self colorAtX:(NSInteger)point.pointValue.x y:(NSInteger)point.pointValue.y in:icon];
        XCTAssertEqualWithAccuracy(color.alphaComponent, 1, 0.01, @"%@", point);
        // Loose, as the bitmap's color space is not the fill's.
        XCTAssertGreaterThan(color.redComponent, 0.5, @"%@", point);
        XCTAssertLessThan(color.greenComponent, 0.5, @"%@", point);
        XCTAssertGreaterThan(color.blueComponent, 0.5, @"%@", point);
    }
}

- (void)testTheMarginAndTheRoundedCornersStayClear {
    NSImage *icon = VibeMacStyleIconFromImage([self imageOfColor:self.magenta size:NSMakeSize(200, 200)],
                                              1024);
    // The canvas's corners and edges, then just inside each corner of the
    // content square, which the 185-point radius cuts away.
    for (NSValue *point in @[@(NSMakePoint(2, 2)), @(NSMakePoint(1021, 1021)), @(NSMakePoint(512, 40)),
                             @(NSMakePoint(40, 512)), @(NSMakePoint(984, 512)),
                             @(NSMakePoint(110, 110)), @(NSMakePoint(914, 110)),
                             @(NSMakePoint(110, 914)), @(NSMakePoint(914, 914))]) {
        NSColor *color = [self colorAtX:(NSInteger)point.pointValue.x y:(NSInteger)point.pointValue.y in:icon];
        XCTAssertLessThan(color.redComponent * color.alphaComponent, 0.05, @"%@", point);
    }
}

// The rim light brightens the edge band, most along the top.
- (void)testTheEdgeCarriesARimLight {
    NSImage *icon = VibeMacStyleIconFromImage([self imageOfColor:[NSColor colorWithSRGBRed:0 green:0 blue:0 alpha:1] size:NSMakeSize(200, 200)],
                                              1024);
    NSColor *top = [self colorAtX:512 y:104 in:icon];
    NSColor *bottom = [self colorAtX:512 y:919 in:icon];
    NSColor *center = [self colorAtX:512 y:512 in:icon];
    XCTAssertLessThan(center.redComponent, 0.02);
    XCTAssertGreaterThan(bottom.redComponent, 0.15);
    XCTAssertGreaterThan(top.redComponent, bottom.redComponent);
}

// A picture that is not square fits whole, centered, and leaves the rest of
// the content square clear.
- (void)testAWidePictureFitsWhole {
    NSImage *icon = VibeMacStyleIconFromImage([self imageOfColor:self.magenta size:NSMakeSize(400, 200)],
                                              1024);
    XCTAssertGreaterThan([self colorAtX:512 y:512 in:icon].redComponent, 0.9);
    XCTAssertGreaterThan([self colorAtX:140 y:512 in:icon].redComponent, 0.9);
    // Above and below the picture's band, inside the content square.
    XCTAssertLessThan([self colorAtX:512 y:200 in:icon].alphaComponent, 0.05);
    XCTAssertLessThan([self colorAtX:512 y:824 in:icon].alphaComponent, 0.05);
}

- (void)testTheCanvasScales {
    NSImage *icon = VibeMacStyleIconFromImage([self imageOfColor:self.magenta size:NSMakeSize(64, 64)],
                                              kVibeDockIconCanvasSize);
    XCTAssertEqualWithAccuracy(icon.size.width, kVibeDockIconCanvasSize, 0.5);
    XCTAssertGreaterThan([self colorAtX:256 y:256 in:icon].redComponent, 0.9);
    XCTAssertLessThan([self colorAtX:20 y:256 in:icon].alphaComponent, 0.05);
}

@end
