//
//  NSURL+Hash+Testing.h
//  vibe-libs
//
//  The disk key's seam for its tests. The body is empty outside DEBUG.
//

#import "NSURL+Hash.h"

// What a volume lookup answers for the file at path, on the device the file's
// stat named: the volume's UUID, nil for none, and where it is mounted.
typedef void (^VibeVolumeLookup)(NSString *_Nonnull path, dev_t device, NSString *_Nullable *_Nonnull uuid,
                                 NSString *_Nullable *_Nonnull mountPath);

@interface NSURL (HashTesting)

// Replaces the volume lookup, nil for the real one, and forgets every volume
// looked up. Empty outside DEBUG.
+ (void)setVolumeLookupForTesting:(nullable VibeVolumeLookup)lookup;

@end

