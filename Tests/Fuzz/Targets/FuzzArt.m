// A picture's bytes, embedded or a cover beside the files, through
// core/Graphics' bounded decode at the row thumbnail's size, its pixel size
// read, and the color the player takes from it. ImageIO is not instrumented,
// so this target finds crashes there, but its coverage guides only ours.

#import <Foundation/Foundation.h>

#import "PlatformImage.h"

int LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t size) {
    @autoreleasepool {
        NSData *data = [NSData dataWithBytesNoCopy:(void *)bytes length:size freeWhenDone:NO];
        (void)VibeEncodedImagePixelSize(data);
        VibeImage *image = VibeDecodedImageWithData(data, kVibeThumbnailArtDimension);
        if (image) {
            (void)VibeDominantColorOfImage(image);
        }
    }
    return 0;
}
