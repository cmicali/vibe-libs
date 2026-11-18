// A picture's bytes, embedded or a cover beside the files, through
// core/Graphics' bounded decode at each size an app asks for: the row
// thumbnail, the display art, and the archived rendition. Then the encode a
// scan stores, the pixel size, and the color the player takes. ImageIO is not
// instrumented, so only this repo's code guides the search.

#import <Foundation/Foundation.h>

#import "PlatformImage.h"

int LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t size) {
    @autoreleasepool {
        NSData *data = [NSData dataWithBytesNoCopy:(void *)bytes length:size freeWhenDone:NO];
        (void)VibeEncodedImagePixelSize(data);
        (void)VibeDecodedImageWithData(data, kVibeThumbnailArtDimension);
        (void)VibeDecodedImageWithData(data, kVibeArchivedDisplayArtDimension);
        VibeImage *image = VibeDecodedImageWithData(data, kVibeDisplayArtDimension);
        if (image) {
            (void)VibeEncodedImageData(image);
            (void)VibeDominantColorOfImage(image);
        }
    }
    return 0;
}
