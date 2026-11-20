//
//  MonkeysAudioTests.mm
//
//  The vendored Monkey's Audio SDK builds and links on its own: it names its
//  version, and its decoder refuses bytes that are not a Monkey's Audio file.
//  audio/Decode's tests decode real files through it.
//

#import <XCTest/XCTest.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include "monkeys_audio/MACLib/All.h"
#include "monkeys_audio/MACLib/MACLib.h"
#include "monkeys_audio/MACLib/MemoryIO.h"
#pragma clang diagnostic pop

@interface MonkeysAudioTests : XCTestCase
@end

@implementation MonkeysAudioTests

- (void)testNamesItsVersion {
    XCTAssertEqual(APE_VERSION_MAJOR, 13);
    XCTAssertEqual(APE_FILE_VERSION_NUMBER, 3990);
}

- (void)testRefusesBytesThatAreNoMonkeysAudioFile {
    unsigned char bytes[64] = "RIFF, not a Monkey's Audio file";
    APE::CMemoryIO io(bytes, sizeof bytes);
    int error = APE_ERROR_SUCCESS;
    APE::IAPEDecompress *decompress = CreateIAPEDecompressEx(&io, &error);
    XCTAssertTrue(decompress == NULL);
    XCTAssertNotEqual(error, APE_ERROR_SUCCESS);
    delete decompress;
}

@end
