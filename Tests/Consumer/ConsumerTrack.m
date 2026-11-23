//
//  ConsumerTrack.m
//

#import "ConsumerTrack.h"

@implementation ConsumerTrack

+ (ConsumerTrack *)withURL:(NSURL *)url {
    return [[ConsumerTrack alloc] initWithURL:url];
}

@end
