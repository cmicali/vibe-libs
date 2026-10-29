//
//  VibeMetadataRead.m
//  vibe-libs
//

#import "VibeMetadataRead.h"
#import "AudioTrackMetadata.h"

@implementation VibeMetadataReadResult

- (instancetype)initWithURL:(NSURL *)url
                    outcome:(VibeMetadataReadOutcome)outcome
                   cacheKey:(NSString *)cacheKey
                   metadata:(AudioTrackMetadata *)metadata
                  fromCache:(BOOL)fromCache
                      error:(NSError *)error {
    self = [super init];
    if (self) {
        _url = [url copy];
        _outcome = outcome;
        _cacheKey = [cacheKey copy];
        _metadata = metadata;
        _fromCache = fromCache;
        _error = error;
    }
    return self;
}

@end
