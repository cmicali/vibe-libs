//
//  VibeBrowserSubfolderWalk.m
//  vibe-libs
//

#import "VibeBrowserSubfolderWalk.h"

#import "FolderWalk.h"

const NSUInteger VibeBrowserMaximumSubfolderTracks = 2000;
const NSUInteger VibeBrowserMaximumSubfolders = 500;

// How many folders list at once. A cloud source's listing is one request
// each, and four keep the network busy without crowding a slow one.
static const NSUInteger kWalkWidth = 4;

// One folder of the walk. Its subfolders are known once it is listed.
@interface VibeBrowserWalkFolder : NSObject
@property (nonatomic, strong) NSURL *url;
@property (nonatomic) BOOL listing;
@property (nonatomic) BOOL listed;
@property (nonatomic) NSUInteger songs;
@property (nonatomic, copy) NSArray<VibeBrowserWalkFolder *> *subfolders;
@end

@implementation VibeBrowserWalkFolder
@end

@implementation VibeBrowserSubfolderWalk {
    VibeBrowserWalkFolder *_root;
    VibeFolderOpenSort _sort;
    NSArray<id<VibeBrowserSource>> *_sources;
    void (^_progress)(NSUInteger, NSUInteger);
    void (^_completion)(NSArray<NSURL *> *, BOOL);
    NSUInteger _inFlight;
    NSUInteger _listed;
    NSUInteger _songs;
    BOOL _ended;
}

+ (void)walkFolder:(NSURL *)folder
          sortedBy:(VibeFolderOpenSort)sort
           sources:(NSArray<id<VibeBrowserSource>> *)sources
          progress:(void (^)(NSUInteger, NSUInteger))progress
        completion:(void (^)(NSArray<NSURL *> *, BOOL))completion {
    VibeBrowserSubfolderWalk *walk = [[self alloc] init];
    walk->_root = [[VibeBrowserWalkFolder alloc] init];
    walk->_root.url = folder;
    walk->_sort = sort;
    walk->_sources = [sources copy];
    walk->_progress = [progress copy];
    walk->_completion = [completion copy];
    // Each listing's block holds the walk until it ends.
    [walk next];
}

// Each folder in depth-first order, as far as the listings know it: a
// folder's subfolders follow it, ahead of its next sibling.
- (void)visitInOrder:(BOOL (^)(VibeBrowserWalkFolder *folder))visit {
    NSMutableArray<VibeBrowserWalkFolder *> *stack = [NSMutableArray arrayWithObject:_root];
    while (stack.count > 0) {
        VibeBrowserWalkFolder *folder = stack.lastObject;
        [stack removeLastObject];
        if (!visit(folder)) {
            return;
        }
        for (VibeBrowserWalkFolder *subfolder in folder.subfolders.reverseObjectEnumerator) {
            [stack addObject:subfolder];
        }
    }
}

// Ends the walk once the folders before the caps are all listed, and starts
// the next listings in depth-first order until four run. The result is the
// one-at-a-time walk's: its caps are counted over the folders in order, so a
// folder listed early past a cap is dropped.
- (void)next {
    if (_ended) {
        return;
    }
    __block NSUInteger visited = 0;
    __block NSUInteger tracks = 0;
    __block BOOL waiting = NO;
    __block BOOL capped = NO;
    NSMutableArray<NSURL *> *found = [NSMutableArray array];
    [self visitInOrder:^BOOL(VibeBrowserWalkFolder *folder) {
        if (tracks >= VibeBrowserMaximumSubfolderTracks || visited >= VibeBrowserMaximumSubfolders) {
            capped = YES;
            return NO;
        }
        if (!folder.listed) {
            waiting = YES;
            return NO;
        }
        visited += 1;
        tracks += folder.songs;
        if (folder.songs > 0) {
            [found addObject:folder.url];
        }
        return YES;
    }];
    if (!waiting) {
        _ended = YES;
        _completion(found, capped);
        return;
    }
    [self visitInOrder:^BOOL(VibeBrowserWalkFolder *folder) {
        if (self->_inFlight >= kWalkWidth) {
            return NO;
        }
        if (!folder.listed && !folder.listing) {
            [self list:folder];
        }
        return YES;
    }];
}

- (void)list:(VibeBrowserWalkFolder *)folder {
    folder.listing = YES;
    _inFlight += 1;
    NSURL *directory = folder.url;
    VibeFolderOpenSort sort = _sort;
    dispatch_block_t list = ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSArray<NSURL *> *subfolders = @[];
            NSArray<NSURL *> *audio = @[];
            [FolderWalk listDirectory:directory sortedBy:sort folders:&subfolders playlists:NULL audio:&audio];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self folder:folder listedSubfolders:subfolders songs:audio.count];
            });
        });
    };
    // The open that follows reads a listed folder as it is, so each is
    // listed once.
    id<VibeBrowserSource> source = [self refreshingSourceForURL:directory];
    if (source) {
        [source refreshDirectoryURL:directory completion:^(NSError *error) {
            list();
        }];
    }
    else {
        list();
    }
}

- (void)folder:(VibeBrowserWalkFolder *)folder listedSubfolders:(NSArray<NSURL *> *)urls songs:(NSUInteger)songs {
    NSMutableArray<VibeBrowserWalkFolder *> *subfolders = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *url in urls) {
        VibeBrowserWalkFolder *subfolder = [[VibeBrowserWalkFolder alloc] init];
        subfolder.url = url;
        [subfolders addObject:subfolder];
    }
    folder.subfolders = subfolders;
    folder.songs = songs;
    folder.listing = NO;
    folder.listed = YES;
    _inFlight -= 1;
    _listed += 1;
    _songs += songs;
    if (_progress && !_ended) {
        _progress(_listed, _songs);
    }
    [self next];
}

- (nullable id<VibeBrowserSource>)refreshingSourceForURL:(NSURL *)url {
    for (id<VibeBrowserSource> source in _sources) {
        if ([source respondsToSelector:@selector(refreshesDirectoryURL:)] && [source refreshesDirectoryURL:url]) {
            return source;
        }
    }
    return nil;
}

@end
