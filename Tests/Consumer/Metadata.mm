//
//  Metadata.mm
//
//  Roots a metadata cache of its own and tags a WAV with a title, an album,
//  and a PNG picture through TagLib's own writer. Loads the WAV through the
//  cache into the consumer's row, as soon as the cache exists. Reads the
//  title and the album back, groups the album, reads the picture's bytes
//  through the artwork's extractor, and waits for the row thumbnail. Then
//  reopens the cache over the same root and loads a fresh row from the disk
//  cache alone, which hits with the same title and album. Objective-C++,
//  since TagLib's writer is C++.
//

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "AlbumGroupingRules.h"
#import "AudioTrackMetadataCache.h"
#import "AudioTrackMetadataInternal.h"
#import "ConsumerTrack.h"
#import "PlatformImage.h"

#include <attachedpictureframe.h>
#include <id3v2tag.h>
#include <wavfile.h>

static BOOL Fail(const char *what) {
    fprintf(stderr, "consumer: %s\n", what);
    return NO;
}

// Runs main's loop until done says so, for at most ten seconds.
static BOOL Spin(BOOL (^done)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!done() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return done();
}

// A PNG of one opaque color, side x side.
static NSData *SolidPNG(size_t side) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, side, side, 8, 0, space,
                                                 (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGContextSetRGBFillColor(context, 0.2, 0.5, 0.8, 1);
    CGContextFillRect(context, CGRectMake(0, 0, side, side));
    CGImageRef image = CGBitmapContextCreateImage(context);
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData(
            (__bridge CFMutableDataRef)data, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    CGImageDestinationAddImage(destination, image, NULL);
    CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    return data;
}

// The cache's deliveries, on main, and the row the last one carried.
@interface ConsumerMetadataDelegate : NSObject <AudioTrackMetadataCacheDelegate>
@property (atomic) NSUInteger deliveries;
@property (atomic, strong) id<AudioTrackMetadataHolder> delivered;
@end

@implementation ConsumerMetadataDelegate
- (void)didLoadMetadata:(id<AudioTrackMetadataHolder>)track {
    self.delivered = track;
    self.deliveries++;
}
@end

FOUNDATION_EXTERN BOOL ConsumerLoadsMetadata(void);

BOOL ConsumerLoadsMetadata(void) {
    NSURL *root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                             isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil
                                                      error:NULL]) {
        return Fail("could not make the metadata test's directory");
    }
    // A second of 16-bit mono silence at 8 kHz, in a canonical WAV.
    NSMutableData *wav = [NSMutableData dataWithBytes:"RIFF" length:4];
    uint32_t chunk = 36 + 16000, fmtSize = 16, rate = 8000, byteRate = 16000, dataSize = 16000;
    uint16_t pcm = 1, channels = 1, align = 2, bits = 16;
    [wav appendBytes:&chunk length:4];
    [wav appendBytes:"WAVEfmt " length:8];
    [wav appendBytes:&fmtSize length:4];
    [wav appendBytes:&pcm length:2];
    [wav appendBytes:&channels length:2];
    [wav appendBytes:&rate length:4];
    [wav appendBytes:&byteRate length:4];
    [wav appendBytes:&align length:2];
    [wav appendBytes:&bits length:2];
    [wav appendBytes:"data" length:4];
    [wav appendBytes:&dataSize length:4];
    [wav increaseLengthBy:dataSize];
    NSURL *url = [root URLByAppendingPathComponent:@"tagged.wav"];
    NSData *picture = SolidPNG(300);
    BOOL saved = [wav writeToURL:url atomically:YES];
    if (saved) {
        TagLib::RIFF::WAV::File file(url.fileSystemRepresentation);
        file.ID3v2Tag()->setTitle(TagLib::String("Consumer", TagLib::String::UTF8));
        file.ID3v2Tag()->setAlbum(TagLib::String("Consumer Album", TagLib::String::UTF8));
        auto frame = new TagLib::ID3v2::AttachedPictureFrame();
        frame->setMimeType("image/png");
        frame->setType(TagLib::ID3v2::AttachedPictureFrame::FrontCover);
        frame->setPicture(TagLib::ByteVector((const char *)picture.bytes, (unsigned int)picture.length));
        file.ID3v2Tag()->addFrame(frame);
        saved = file.save(TagLib::RIFF::WAV::File::ID3v2);
    }

    BOOL holds = NO;
    if (!saved) {
        Fail("could not write and tag the WAV");
    }
    else {
        NSString *cachePath = [root URLByAppendingPathComponent:@"cache"].path;
        AudioTrackMetadataCache *cache = [[AudioTrackMetadataCache alloc] initWithRootPath:cachePath];
        ConsumerMetadataDelegate *delegate = [[ConsumerMetadataDelegate alloc] init];
        cache.delegate = delegate;
        // At once: the store is built off main, and the load waits for it.
        ConsumerTrack *track = [ConsumerTrack withURL:url];
        [cache loadMetadataNow:track];
        NSData *art = nil;
        __block VibeImage *thumbnail = nil;
        if (!Spin(^BOOL { return delegate.deliveries > 0; })) {
            Fail("the metadata cache delivered nothing");
        }
        else if (!track.metadata.parsedOK || ![track.metadata.title isEqualToString:@"Consumer"]) {
            Fail("the metadata cache did not read the tagged title");
        }
        else if (![track.metadata.album isEqualToString:@"Consumer Album"]
                 || !VibeAlbumGroupKey(track.metadata.musicBrainzReleaseID, track.metadata.album,
                                       track.metadata.albumArtist, track.metadata.artist, track.metadata.year,
                                       track.metadata.isCompilation)) {
            Fail("the metadata cache did not read the tagged album, or it groups under no album");
        }
        else if (VibeTagLibArtExtractor()(url.path, &art) != VibeEmbeddedArtExtractionFoundArt
                 || ![art isEqualToData:picture]) {
            Fail("the artwork's extractor did not read the picture's bytes");
        }
        else if (!Spin(^BOOL { return (thumbnail = track.metadata.cachedThumbnail) != nil; })) {
            Fail("the row thumbnail never decoded");
        }
        else if (thumbnail.size.width <= 0 || thumbnail.size.width > 128 || thumbnail.size.height > 128) {
            Fail("the row thumbnail is not at most 128 px");
        }
        else {
            // A second cache over the same root, as the app's next launch
            // makes, loads a fresh row of the file from the disk cache alone.
            // That path never parses, so a miss would deliver nothing.
            AudioTrackMetadataCache *reopened = [[AudioTrackMetadataCache alloc] initWithRootPath:cachePath];
            ConsumerMetadataDelegate *hits = [[ConsumerMetadataDelegate alloc] init];
            reopened.delegate = hits;
            ConsumerTrack *again = [ConsumerTrack withURL:url];
            [reopened loadCachedMetadata:@[again]];
            if (!Spin(^BOOL { return hits.deliveries > 0; }) || hits.delivered != again) {
                Fail("the reopened metadata cache did not hit");
            }
            else if (!again.metadata.parsedOK || ![again.metadata.title isEqualToString:@"Consumer"]
                     || ![again.metadata.album isEqualToString:@"Consumer Album"]
                     || again.metadata == track.metadata) {
                Fail("the reopened metadata cache did not read the tagged title and album back from disk");
            }
            else {
                holds = YES;
            }
            reopened.delegate = nil;
        }
        cache.delegate = nil;
    }
    [NSFileManager.defaultManager removeItemAtURL:root error:NULL];
    return holds;
}
