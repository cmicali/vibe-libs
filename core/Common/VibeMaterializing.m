//
//  VibeMaterializing.m
//  vibe-libs
//

#import "VibeMaterializing.h"

#import "VibeMacros.h"

#include <errno.h>
#include <string.h>

void VibeWithMaterializationPolicy(int policy, NSString *what, NS_NOESCAPE dispatch_block_t block) {
    int previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD);
    BOOL set = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, policy) == 0;
    if (!set) {
        LogWarn(@"Could not set materialization for %@: %s", what, strerror(errno));
    }
    block();
    if (set) {
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                       previous >= 0 ? previous : IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT);
    }
}
