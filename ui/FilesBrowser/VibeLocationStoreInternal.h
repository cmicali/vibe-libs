//
//  VibeLocationStoreInternal.h
//  vibe-libs
//
//  What the store's tests reach that an app does not.
//

#import "VibeLocationStore.h"

NS_ASSUME_NONNULL_BEGIN

@interface VibeLocationStore (Internal)

// A store of its own over the same defaults, as a relaunch reads them. The
// app has one, VibeLocationStore.shared.
- (instancetype)initPrivate;

@end

NS_ASSUME_NONNULL_END
