//
//  VibeTestTrack.m
//

#import "VibeTestTrack.h"

#import "NSURL+Hash.h"

@implementation VibeTestTrack {
    NSString *_sourceKey;
}

@synthesize url = _url, cueStart = _cueStart, cueEnd = _cueEnd, fileGain = _fileGain;

+ (VibeTestTrack *)withURL:(NSURL *)url {
    return [[VibeTestTrack alloc] initWithURL:url cueStart:0 cueEnd:0];
}

+ (VibeTestTrack *)withURL:(NSURL *)url fileGain:(float)fileGain {
    return [[VibeTestTrack alloc] initWithURL:url cueStart:0 cueEnd:0 fileGain:fileGain];
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
        _sourceKey = VibeKeyByAppendingCueWindow(url.path, cueStart, cueEnd) ?: @"";
    }
    return self;
}

- (NSString *)sourceKey {
    return _sourceKey;
}

- (NSString *)cacheKey {
    return self.url.cacheKey;
}

@end
