//
//  VibeTestTrack.m
//

#import "VibeTestTrack.h"

#import "NSURL+Hash.h"

@implementation VibeTestTrack {
    NSString *_sourceKey;
    BOOL _hasDSDFileGain;
}

@synthesize url = _url, cueStart = _cueStart, cueEnd = _cueEnd, fileGain = _fileGain, dsdFileGain = _dsdFileGain;

+ (VibeTestTrack *)withURL:(NSURL *)url {
    return [[VibeTestTrack alloc] initWithURL:url cueStart:0 cueEnd:0];
}

+ (VibeTestTrack *)withURL:(NSURL *)url fileGain:(float)fileGain {
    return [[VibeTestTrack alloc] initWithURL:url cueStart:0 cueEnd:0 fileGain:fileGain];
}

+ (VibeTestTrack *)withURL:(NSURL *)url fileGain:(float)fileGain dsdFileGain:(float)dsdFileGain {
    VibeTestTrack *track = [[VibeTestTrack alloc] initWithURL:url cueStart:0 cueEnd:0 fileGain:fileGain];
    track->_dsdFileGain = dsdFileGain;
    track->_hasDSDFileGain = YES;
    return track;
}

- (instancetype)initWithURL:(NSURL *)url cueStart:(NSUInteger)cueStart cueEnd:(NSUInteger)cueEnd {
    return [self initWithURL:url cueStart:cueStart cueEnd:cueEnd fileGain:1];
}

- (instancetype)initWithURL:(NSURL *)url cueStart:(NSUInteger)cueStart cueEnd:(NSUInteger)cueEnd
                   fileGain:(float)fileGain {
    if ((self = [super init])) {
        _url = [url copy];
        _cueStart = cueStart;
        _cueEnd = cueEnd;
        _fileGain = fileGain;
        _dsdFileGain = NAN;
        _sourceKey = VibeKeyByAppendingCueWindow(url.path, cueStart, cueEnd) ?: @"";
    }
    return self;
}

// Only a track made with a DSD gain has one, as an app's item without the
// optional property.
- (BOOL)respondsToSelector:(SEL)selector {
    if (selector == @selector(dsdFileGain)) {
        return _hasDSDFileGain;
    }
    return [super respondsToSelector:selector];
}

- (NSString *)sourceKey {
    return _sourceKey;
}

- (NSString *)cacheKey {
    return self.url.cacheKey;
}

@end
