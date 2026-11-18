#import <XCTest/XCTest.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "PlatformImage.h"

@interface PlatformImageTests : XCTestCase
@end

@implementation PlatformImageTests

// A PNG `width` pixels wide and one high.
static NSData *VibeStripPNG(size_t width) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, width, 1, 8, 0, space, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGContextSetRGBFillColor(context, 1, 0, 0, 1);
    CGContextFillRect(context, CGRectMake(0, 0, width, 1));
    CGImageRef image = CGBitmapContextCreateImage(context);
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,
                                                                         (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    CGImageDestinationAddImage(destination, image, NULL);
    CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    return data;
}

- (void)testArtAtTheLargestSideDecodes {
    XCTAssertNotNil(VibeDecodedImageWithData(VibeStripPNG((size_t)kVibeLargestArtDimension), kVibeThumbnailArtDimension));
}

- (void)testArtPastTheLargestSideIsRefused {
    XCTAssertNil(VibeDecodedImageWithData(VibeStripPNG((size_t)kVibeLargestArtDimension + 1), kVibeThumbnailArtDimension));
}

// It took 5 s a decode before the refusal (PlatformImage.m).
- (void)testAWideHEICIsRefusedUndecoded {
    NSString *path = [[@(__FILE__) stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:@"../../Fuzz/Regressions/art/wide-heic.heic"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    XCTAssertNotNil(data, @"%@", path);
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    XCTAssertNil(VibeDecodedImageWithData(data, kVibeDisplayArtDimension));
    XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - start, 1.0);
}

@end
