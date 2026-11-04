//
//  FolderArtResolverInternal.h
//  vibe-libs
//
//  Deterministic I/O seams and diagnostics for focused resolver tests.
//

#import "FolderArtResolver.h"

NS_ASSUME_NONNULL_BEGIN

typedef NSArray<NSString *> * _Nullable (^FolderArtDirectoryLister)(NSString *directory);
typedef BOOL (^FolderArtFileInfoProvider)(NSString *path,
                                          unsigned long long * _Nullable size);
typedef NSData * _Nullable (^FolderArtDataReader)(NSString *path);
typedef VibeImage * _Nullable (^FolderArtDecoder)(NSData *data, CGFloat maxPixelSize);

@interface FolderArtResolver (Internal)

- (instancetype)initWithEnabledProvider:(FolderArtEnabledProvider)enabledProvider
                         accessProvider:(FolderArtAccessProvider)accessProvider
                                 lister:(FolderArtDirectoryLister)lister
                               fileInfo:(FolderArtFileInfoProvider)fileInfo
                             dataReader:(FolderArtDataReader)dataReader
                                decoder:(FolderArtDecoder)decoder;

- (instancetype)initWithEnabledProvider:(FolderArtEnabledProvider)enabledProvider
                         accessProvider:(FolderArtAccessProvider)accessProvider;

@property (nonatomic, readonly) NSUInteger recordedDirectoryCount;
// Whether a cover is a cloud placeholder. PlaceholderFiles' dataless test
// unless a test sets its own, before the first read.
@property (nonatomic, copy) BOOL (^placeholderTest)(NSString *path);

- (nullable NSString *)settledArtPathForDirectory:(nullable NSString *)directory;
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
