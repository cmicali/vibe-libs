//
//  VibeMaterializing.h
//  vibe-libs
//

#import <Foundation/Foundation.h>

#include <sys/resource.h>

NS_ASSUME_NONNULL_BEGIN

// Runs block with this thread's policy for dataless files set to policy:
// IOPOL_MATERIALIZE_DATALESS_FILES_OFF, so a read of a cloud placeholder
// fails with EDEADLK and nothing downloads, or _ON, so it downloads. what
// names the work in the warning a failed set logs. Measured on macOS 27.2
// against iCloud Drive and Dropbox placeholders, with it off: the open
// succeeds, every read fails, and the file stays in the cloud.
// TRAP: the policy is the thread's, and is put back after, to the default
// when the old one could not be read. A queue's thread runs other work next.
FOUNDATION_EXPORT void VibeWithMaterializationPolicy(int policy, NSString *what, NS_NOESCAPE dispatch_block_t block);

// The same with materialization off, which every background reader uses.
static inline void VibeWithoutMaterializing(NSString *what, NS_NOESCAPE dispatch_block_t block) {
    VibeWithMaterializationPolicy(IOPOL_MATERIALIZE_DATALESS_FILES_OFF, what, block);
}

NS_ASSUME_NONNULL_END
