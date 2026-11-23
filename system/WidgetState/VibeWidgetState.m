//
//  VibeWidgetState.m
//  vibe-libs
//

#import "VibeWidgetState.h"

#import <notify.h>

static NSString *sAppGroup;
static NSString *sReadNotification;

static NSString *const kStateFileName = @"state.plist";
// The image files carry their track's key, so the container can hold two
// tracks' sets at once and a plist always names its own.
static NSString *const kArtworkFormat  = @"artwork-%@.jpg";
static NSString *const kPlayedFormat   = @"waveform-%@-played.png";
static NSString *const kUnplayedFormat = @"waveform-%@-unplayed.png";

// Spelled once: a typo across the process boundary reads as an absent field.
static NSString *const kKeyVersion      = @"version";
static NSString *const kKeyTitle        = @"title";
static NSString *const kKeyArtist       = @"artist";
static NSString *const kKeyTrackKey     = @"trackKey";
static NSString *const kKeyHasTrack     = @"hasTrack";
static NSString *const kKeyPlaying      = @"playing";
static NSString *const kKeyDuration     = @"duration";
static NSString *const kKeyPosition     = @"position";
static NSString *const kKeyPositionDate = @"positionDate";
static NSString *const kKeyPlayheadLine = @"playheadLine";

// Bumped when a field's meaning changes; an unknown version draws the empty
// state until the next publish.
static const NSInteger kStateVersion = 3;

@implementation VibeWidgetState

+ (void)useAppGroup:(NSString *)appGroup readNotification:(NSString *)readNotification {
    NSAssert(!sAppGroup || ([sAppGroup isEqualToString:appGroup] && [sReadNotification isEqualToString:readNotification]),
             @"The widget's app group is set once per process");
    sAppGroup = [appGroup copy];
    sReadNotification = [readNotification copy];
}

+ (NSString *)readNotification {
    return sReadNotification;
}

+ (NSURL *)containerURL {
    // Once: the container manager answers over XPC. Not before the group is
    // set, so an early read cannot strand the process without one.
    if (!sAppGroup) {
        return nil;
    }
    static NSURL *container;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        container = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:sAppGroup];
    });
    return container;
}

+ (nullable NSURL *)fileNamed:(NSString *)name {
    NSURL *container = self.containerURL;
    return container ? [container URLByAppendingPathComponent:name] : nil;
}

+ (nullable NSURL *)fileNamed:(NSString *)format trackKey:(nullable NSString *)trackKey {
    return trackKey.length ? [self fileNamed:[NSString stringWithFormat:format, trackKey]] : nil;
}

- (NSURL *)artworkURL          { return [self.class fileNamed:kArtworkFormat trackKey:self.trackKey]; }
- (NSURL *)waveformPlayedURL   { return [self.class fileNamed:kPlayedFormat trackKey:self.trackKey]; }
- (NSURL *)waveformUnplayedURL { return [self.class fileNamed:kUnplayedFormat trackKey:self.trackKey]; }

+ (NSArray<NSURL *> *)imageURLsNotForTrackKeys:(NSArray<NSString *> *)trackKeys {
    NSURL *container = self.containerURL;
    if (!container) {
        return @[];
    }
    NSMutableSet<NSString *> *keep = [NSMutableSet set];
    for (NSString *key in trackKeys) {
        if (key.length) {
            [keep addObject:[NSString stringWithFormat:kArtworkFormat, key]];
            [keep addObject:[NSString stringWithFormat:kPlayedFormat, key]];
            [keep addObject:[NSString stringWithFormat:kUnplayedFormat, key]];
        }
    }
    NSMutableArray<NSURL *> *stale = [NSMutableArray array];
    NSArray<NSURL *> *contents = [NSFileManager.defaultManager
            contentsOfDirectoryAtURL:container includingPropertiesForKeys:nil
                             options:NSDirectoryEnumerationSkipsHiddenFiles error:NULL];
    for (NSURL *url in contents) {
        NSString *name = url.lastPathComponent;
        BOOL image = [name hasPrefix:@"artwork-"] || [name hasPrefix:@"waveform-"];
        if (image && ![keep containsObject:name]) {
            [stale addObject:url];
        }
    }
    return stale;
}

+ (VibeWidgetState *)loadState {
    // Before the read: an empty container is still a widget asking.
    if (sReadNotification) {
        notify_post(sReadNotification.UTF8String);
    }
    NSURL *url = [self fileNamed:kStateFileName];
    if (!url) {
        return nil;
    }
    return [self stateFromPlist:[NSDictionary dictionaryWithContentsOfURL:url error:NULL]];
}

// Each field's class, so a file another build wrote reads as empty, not as a
// crash in positionAtDate:.
static BOOL VibeWidgetPlistHasClasses(NSDictionary *plist) {
    NSDictionary<NSString *, Class> *classes = @{
        kKeyVersion: NSNumber.class, kKeyTitle: NSString.class, kKeyArtist: NSString.class,
        kKeyTrackKey: NSString.class, kKeyHasTrack: NSNumber.class, kKeyPlaying: NSNumber.class,
        kKeyDuration: NSNumber.class, kKeyPosition: NSNumber.class, kKeyPositionDate: NSDate.class,
        kKeyPlayheadLine: NSNumber.class,
    };
    for (NSString *key in classes) {
        id value = plist[key];
        if (value && ![value isKindOfClass:classes[key]]) {
            return NO;
        }
    }
    return YES;
}

+ (nullable VibeWidgetState *)stateFromPlist:(nullable id)plist {
    if (![plist isKindOfClass:NSDictionary.class] || !VibeWidgetPlistHasClasses(plist)
            || [plist[kKeyVersion] integerValue] != kStateVersion) {
        return nil;
    }
    VibeWidgetState *state = [[VibeWidgetState alloc] init];
    state.title        = plist[kKeyTitle];
    state.artist       = plist[kKeyArtist];
    state.trackKey     = plist[kKeyTrackKey];
    state.hasTrack     = [plist[kKeyHasTrack] boolValue];
    state.playing      = [plist[kKeyPlaying] boolValue];
    state.duration     = [plist[kKeyDuration] doubleValue];
    state.position     = [plist[kKeyPosition] doubleValue];
    state.positionDate = plist[kKeyPositionDate];
    state.playheadLine = [plist[kKeyPlayheadLine] boolValue];
    return state;
}

- (BOOL)save {
    NSURL *url = [VibeWidgetState fileNamed:kStateFileName];
    if (!url) {
        return NO;
    }
    NSMutableDictionary *plist = [NSMutableDictionary dictionary];
    plist[kKeyVersion]      = @(kStateVersion);
    plist[kKeyTitle]        = self.title;
    plist[kKeyArtist]       = self.artist;
    plist[kKeyTrackKey]     = self.trackKey;
    plist[kKeyHasTrack]     = @(self.hasTrack);
    plist[kKeyPlaying]      = @(self.playing);
    plist[kKeyDuration]     = @(self.duration);
    plist[kKeyPosition]     = @(self.position);
    plist[kKeyPositionDate] = self.positionDate;
    plist[kKeyPlayheadLine] = @(self.playheadLine);
    return [plist writeToURL:url error:NULL];
}

- (id)copyWithZone:(NSZone *)zone {
    VibeWidgetState *copy = [[VibeWidgetState allocWithZone:zone] init];
    copy.title        = self.title;
    copy.artist       = self.artist;
    copy.trackKey     = self.trackKey;
    copy.hasTrack     = self.hasTrack;
    copy.playing      = self.playing;
    copy.duration     = self.duration;
    copy.position     = self.position;
    copy.positionDate = self.positionDate;
    copy.playheadLine = self.playheadLine;
    return copy;
}

- (NSTimeInterval)positionAtDate:(NSDate *)date {
    NSTimeInterval elapsed = 0;
    if (self.playing && self.positionDate) {
        elapsed = MAX(0, [date timeIntervalSinceDate:self.positionDate]);
    }
    NSTimeInterval position = self.position + elapsed;
    if (self.duration > 0) {
        position = MIN(position, self.duration);
    }
    return MAX(0, position);
}

- (double)progressAtDate:(NSDate *)date {
    if (self.duration <= 0) {
        return 0;
    }
    return [self positionAtDate:date] / self.duration;
}

@end
