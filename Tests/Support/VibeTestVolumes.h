//
//  VibeTestVolumes.h
//  vibe-libs
//
//  The volume the disk key sees for every file, for a test, through
//  NSURL+Hash's seam.
//

#import <XCTest/XCTest.h>
#import "NSURL+Hash+Testing.h"

// Until the test ends, every file is on a volume of uuid, nil for none,
// mounted at mountPath.
static inline void VibeTestUseVolume(XCTestCase *_Nonnull test, NSString *_Nullable uuid, NSString *_Nullable mountPath) {
    [NSURL setVolumeLookupForTesting:^(NSString *_Nonnull path, dev_t device, NSString *_Nullable *_Nonnull found, NSString *_Nullable *_Nonnull mount) {
        *found = uuid;
        *mount = mountPath;
    }];
    [test addTeardownBlock:^{
        [NSURL setVolumeLookupForTesting:nil];
    }];
}
