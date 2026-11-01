//
//  AudioPlayerCodedTestCase.h
//
//  The harness the whole-player tests on the frame-driven pump share. Every
//  sample of every fixture names its file and its frame, so a capture shows
//  exactly what played. A gain that is a power of two scales a sample
//  exactly, so a sample divided by its gain still names where it came from.
//  It runs no tests. AudioPlayerReparkTests and AudioPlayerFileGainTests
//  subclass it.
//

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#import "AudioPlayer+Debug.h"
#import "AudioPlayerInternal.h"
#import "AudioReferenceFixtures.h"
#import "AudioVoiceBusInternal.h"
#import "VibeTestTrack.h"

NS_ASSUME_NONNULL_BEGIN

static const double kCodedRate = 48000;
static const NSUInteger kCodedFrames = 48000; // each of the four files, 1 s: the ring holds more
static const NSUInteger kCodedDeclickFrames = 480; // a play's 10 ms fade in

// A sample's code: its file in the bits above 17, its frame below. Exact in
// float32, and negated on the right channel.
static inline float VibeCodedSample(uint32_t file, uint32_t frame) {
    return (float)((file << 17) | frame) / (float)(1 << 20);
}

static inline uint32_t VibeCodedCodeOf(uint32_t file, uint32_t frame) {
    return (file << 17) | frame;
}

// The code a captured stereo frame names at `gain`, or 0 for one that names
// none: silence, a faded sample, another gain, or two channels that disagree.
static inline uint32_t VibeCodedCode(const float *frame, float gain) {
    double scaled = (double)frame[0] / gain * (1 << 20);
    uint32_t code = (uint32_t)scaled;
    return gain > 0 && scaled > 0 && (double)code == scaled && frame[1] == -frame[0] ? code : 0;
}

static inline uint32_t VibeCodedFile(uint32_t code) {
    return code >> 17;
}

static inline uint32_t VibeCodedFrame(uint32_t code) {
    return code & ((1 << 17) - 1);
}

@interface AudioPlayerCodedTestCase : XCTestCase <AudioPlayerDelegate> {
@protected
    NSURL *_temporary;
    AudioPlayer *_player;
    NSMutableArray<NSDictionary *> *_events;
    NSMutableData *_capture;
    NSError *_error;
    NSURL *_files[5]; // 1 to 4, kCodedFrames each
}

- (NSURL *)writeFile:(uint32_t)file frames:(NSUInteger)frames;
- (void)settleUntil:(BOOL (^)(void))condition;
- (NSUInteger)count:(NSString *)event;
// The current voice's snapshot, and a private value, read on the player queue.
- (VibeVoiceSnapshot)voiceSnapshot;
- (nullable id)onQueue:(NSString *)key;
// A new player on the frame-driven pump, initialized, with an empty capture.
- (void)makePlayer;
// Plays `track` from 0 with the declick, and waits for its start.
- (void)playTrack:(VibeTestTrack *)track;
// Parks `track` and waits until it is queued on the current voice.
- (void)queueTrack:(VibeTestTrack *)track;
- (void)render:(NSUInteger)frames block:(NSUInteger)block;
- (void)render:(NSUInteger)frames;
// Renders until the current voice has consumed exactly `frames`.
- (void)renderVoiceTo:(uint64_t)frames;
- (NSUInteger)capturedFrames;
- (const float *)frame:(NSUInteger)index;
// The capture index of `file`'s `frame` at `gain`, or NSNotFound.
- (NSUInteger)indexOfFile:(uint32_t)file frame:(uint32_t)frame gain:(float)gain;
// Every frame from capture index `start` is `file`'s at `gain`, from `first`,
// for `count` frames; NO, with a failure, at the first that is not.
- (BOOL)assertFile:(uint32_t)file gain:(float)gain from:(uint32_t)first count:(NSUInteger)count
           atIndex:(NSUInteger)start in:(NSString *)when;
@end

NS_ASSUME_NONNULL_END
