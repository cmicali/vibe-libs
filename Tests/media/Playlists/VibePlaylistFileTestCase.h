//
//  VibePlaylistFileTestCase.h
//  vibe-libs
//
//  The harness the VibePlaylistFile tests share: a temp folder of empty files
//  beside a playlist, and the FILE names a sheet resolves. It runs no tests.
//  VibePlaylistFileTests and VibePlaylistFileCUETests subclass it.
//

#import <XCTest/XCTest.h>
#import "VibePlaylistFile.h"

NS_ASSUME_NONNULL_BEGIN

// The FILE names a sheet resolves, in resolution order: the FILE-line lexing,
// read through the one CUE reader.
@interface VibePlaylistFile (CueFileNames)
+ (NSArray<NSString *> *)fileNamesInCueText:(NSString *)text;
@end

@interface VibePlaylistFileTestCase : XCTestCase
- (NSURL *)makeTempDirWithFiles:(NSArray<NSString *> *)names
                   playlistName:(NSString *)playlistName
                           text:(NSString *)text;
@end

NS_ASSUME_NONNULL_END
