//
// A codec's format name.
//

#import <XCTest/XCTest.h>

#import "AudioFileFormat.h"

@interface AudioFileFormatTests : XCTestCase
@end

@implementation AudioFileFormatTests

- (void)testEachNamedCodecHasItsName {
    XCTAssertEqualObjects(VibeAudioFileFormatForCodec(kAudioFormatMPEGLayer3), VibeAudioFileFormatMP3);
    XCTAssertEqualObjects(VibeAudioFileFormatForCodec(kAudioFormatMPEGLayer2), VibeAudioFileFormatMP2);
    XCTAssertEqualObjects(VibeAudioFileFormatForCodec(kAudioFormatMPEG4AAC), VibeAudioFileFormatAAC);
    XCTAssertEqualObjects(VibeAudioFileFormatForCodec(kAudioFormatFLAC), VibeAudioFileFormatFLAC);
    XCTAssertEqualObjects(VibeAudioFileFormatForCodec(kAudioFormatAppleLossless), VibeAudioFileFormatALAC);
    XCTAssertEqualObjects(VibeAudioFileFormatForCodec(kAudioFormatOpus), VibeAudioFileFormatOpus);
    XCTAssertEqualObjects(VibeAudioFileFormatForCodec('vorb'), VibeAudioFileFormatVorbis);
}

// A name is archived in a metadata cache, so its spelling never changes.
- (void)testDSDIsSpelledDSD {
    XCTAssertEqualObjects(VibeAudioFileFormatDSD, @"DSD");
}

// PCM's name is its container's.
- (void)testPCMHasNoNameOfItsOwn {
    XCTAssertNil(VibeAudioFileFormatForCodec(kAudioFormatLinearPCM));
}

@end
