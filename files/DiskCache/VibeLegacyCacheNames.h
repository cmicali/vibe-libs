//
//  VibeLegacyCacheNames.h
//  vibe-libs
//
//  The names a PINCache store of the releases before VibeCacheStore kept its
//  entries under, which each cache's import reads its old store by: a folder
//  "<prefix>.<name>" under the root, and one file for each key, named by
//  PINDiskCache's key encoder. PINCache itself is gone.
//
//  TRAP: they are defined in PINCache+VibeAudioCache.m, which an app's test
//  target lists by path. Don't move them to a file of their own.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The prefix of every PINCache store's folder, and the dot after it.
FOUNDATION_EXPORT NSString *const VibeLegacyCacheFolderPrefix;

// The folder of the PINCache store named name under root.
FOUNDATION_EXPORT NSString *VibeLegacyCacheFolder(NSString *root, NSString *name);

// The file that store kept key in. Nil for an empty key.
FOUNDATION_EXPORT NSString *_Nullable VibeLegacyCacheFileName(NSString *key);

NS_ASSUME_NONNULL_END
