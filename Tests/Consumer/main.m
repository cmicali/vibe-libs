//
//  main.m
//
//  Plays a ramp through the varispeed at zero pitch and checks it comes back
//  exactly, then renders off zero. Plays a tone through the FX chain with
//  nothing engaged and checks it comes back exactly, then reads the meter's
//  levels of it. Round-trips a color through its hex form.
//  Draws each mac control into a bitmap with no window, and steps the pitch
//  fader once as VoiceOver would. Builds a settings window of three panes
//  without showing it, finds a color-pair row, a switch, and a slider in two
//  of them, and picks the second pane in the sidebar. In
//  the third, the Shortcuts pane over two commands of its own, it records a
//  shortcut from a key event sent through NSApp. Keys a temporary file by its
//  size, time and path, and keys it anew once it changes. Turns a CUE window
//  into a file's frames. Opens a temporary file through the file loader, with
//  a handle of its own. Cancels a placeholder's open over the fake cloud while
//  it downloads, and checks that the claim and the transfer let go
//  (FileLoading.m). Roots a disk cache in a temporary directory and reads
//  its usage back. Lists the output devices through the device manager and
//  prints the default one's name, changing nothing. It skips that, and says
//  so, only when the HAL cannot read its device list. Writes a WAV of a ramp,
//  opens it through the audio file handle, and reads its frames back exactly.
//  Finds the tempo of a click track at 128 BPM, fed in blocks as a decode
//  would. Tags a WAV through TagLib, and reads its title and its picture back
//  through the tag wrapper, the picture by range (Tags.mm). Roots a metadata
//  cache of its own, loads a tagged WAV through it into the consumer's row
//  (ConsumerTrack.h), and reads its title, its picture's bytes, and its row
//  thumbnail back. A second cache over the same root then hits for a fresh
//  row (Metadata.mm). Queues plain URLs,
//  two of them for one file, and walks what follows each track's end under
//  repeat and shuffle. Writes an M3U, reads it back, and reads a small CUE
//  sheet. Walks a folder of two tracks and an M3U in each folder order, and
//  opens the M3U in its own order. Scans the same folder with a token, and
//  reads back a complete verdict and both tracks in batches. Summarizes a tone and draws it, and loads
//  a WAV of it through the waveform loader. Roots a waveform cache of its
//  own, and loads the tone through it twice. The second load is a hit. A
//  CUE window of the tone loads twice, and its second load is a hit too
//  (Waveform.mm). Draws the tone in
//  every waveform style and reads back that each drew (WaveformStyles.mm).
//  Lays the mac waveform view out with the tone's summary and reads back that
//  both sides drew (WaveformView.mm). Draws the equalizer bars from a level
//  source of its own, and checks the bars ask it for levels once and let go
//  when they leave their window. Plays a queue of two rows of one WAV and a
//  CUE window of another through a player on the manual render pump, and
//  reads every frame back exactly (Player.m). Publishes a title and a
//  duration through the Now Playing controller, over sinks of its own, and
//  reads them back (NowPlaying.m).
//  Downloads a file and reads a range of it through an HTTP transfer client
//  over the fake web server (ShareLinks.m). Answers one command through the
//  debug channel (DebugChannel.m). Makes a folder grants' store over a
//  defaults suite of its own, and checks that a new temporary folder is not
//  readable (SandboxAccess.m).
//  Coalesces an open split into batches into one ordered open, through the
//  open coordinator (AppOpening.m). Exits 0 when all thirty-four hold.
//

#import <Foundation/Foundation.h>
#import <math.h>
#import "AudioBPMAnalyzer.h"
#import "AudioError.h"
#import "AudioFileHandle.h"
#import "AudioDeviceManager.h"
#import "AudioFX+Pipeline.h"
#import "AudioLevelMeter.h"
#import "AudioVarispeed.h"
#import "CueWindowMath.h"
#import "PINCache+VibeAudioCache.h"
#import "NSURL+Hash.h"
#import "PlatformColor.h"
#import "VibePlaylist.h"
#import "VibePlaylistEntry.h"
#import "VibePlaylistFile.h"
#import "CrossfadingImageView.h"
#import "DrawnControls.h"
#import "EqualizerIndicatorView.h"
#import "PitchControlPanel.h"
#import "PitchFaderView.h"
#import "FolderWalk.h"
#import "ScaledImageView.h"
#import "SymbolButton.h"
#import "VibeDetentSlider.h"
#import "VibeLinkLabel.h"
#import "SettingsPanesWindowController.h"
#import "SettingsPaneViewController.h"
#import "SettingsShortcutsViewController.h"
#import "SettingsSidebarController.h"
#import "ShortcutLayout.h"

// Tags.mm's check, in Objective-C++, since the wrapper's header is C++.
FOUNDATION_EXTERN BOOL ConsumerReadsTags(void);
// Metadata.mm's check, since TagLib's writer is C++.
FOUNDATION_EXTERN BOOL ConsumerLoadsMetadata(void);
// Waveform.mm's check, since the waveform's headers are C++.
FOUNDATION_EXTERN BOOL ConsumerWaveformHolds(void);
FOUNDATION_EXTERN BOOL ConsumerLoadsAWaveform(void);
FOUNDATION_EXTERN BOOL ConsumerHitsTheWaveformCache(void);
// FileLoading.m's checks.
FOUNDATION_EXTERN BOOL ConsumerOpensAFile(void);
FOUNDATION_EXTERN BOOL ConsumerCancelsACloudOpen(void);
// Player.m's check, beside the delegate that drives its queue.
FOUNDATION_EXTERN BOOL ConsumerPlaysAQueue(void);
// WaveformStyles.mm's check, since the renderers' headers are C++.
FOUNDATION_EXTERN BOOL ConsumerWaveformStylesHold(void);
// WaveformView.mm's check, since the summary's header is C++.
FOUNDATION_EXTERN BOOL ConsumerWaveformViewDraws(void);
// NowPlaying.m's check.
FOUNDATION_EXTERN BOOL ConsumerPublishesNowPlaying(void);
// AppOpening.m's check.
FOUNDATION_EXTERN BOOL ConsumerOrdersASplitOpen(void);
// ShareLinks.m's check, over the fake web server.
FOUNDATION_EXTERN BOOL ConsumerFetchesFromTheFakeHost(void);
// DebugChannel.m's check, beside its own table.
FOUNDATION_EXTERN BOOL ConsumerDebugChannelAnswers(void);
// SandboxAccess.m's check.
FOUNDATION_EXTERN BOOL ConsumerSandboxAccessHolds(void);

// A pane whose sections a block builds, so main needs no pane classes.
@interface ConsumerPane : SettingsPaneViewController
@property (nonatomic, copy) NSArray<NSView *> *(^build)(ConsumerPane *pane);
@end

@implementation ConsumerPane
- (void)loadView {
    [self loadPaneWithSections:self.build(self)];
}
- (void)changed:(id)sender {
}
@end

// A canonical 16-bit stereo WAV in a temporary file, its bytes written here,
// so no reader is its own oracle. Frame i's left sample is first + i, and its
// right sample the negation.
FOUNDATION_EXTERN NSURL *ConsumerRampWAV(uint32_t rate, int16_t count, int16_t first);

NSURL *ConsumerRampWAV(uint32_t rate, int16_t count, int16_t first) {
    NSMutableData *wav = [NSMutableData dataWithBytes:"RIFF" length:4];
    uint32_t chunk = 36 + (uint32_t)count * 4, fmtSize = 16, byteRate = rate * 4, dataSize = (uint32_t)count * 4;
    uint16_t pcm = 1, channels = 2, align = 4, bits = 16;
    [wav appendBytes:&chunk length:4];
    [wav appendBytes:"WAVEfmt " length:8];
    [wav appendBytes:&fmtSize length:4];
    [wav appendBytes:&pcm length:2];
    [wav appendBytes:&channels length:2];
    [wav appendBytes:&rate length:4];
    [wav appendBytes:&byteRate length:4];
    [wav appendBytes:&align length:2];
    [wav appendBytes:&bits length:2];
    [wav appendBytes:"data" length:4];
    [wav appendBytes:&dataSize length:4];
    for (int16_t i = 0; i < count; i++) {
        int16_t frame[2] = {(int16_t)(first + i), (int16_t)-(first + i)};
        [wav appendBytes:frame length:sizeof frame];
    }
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"wav"]]];
    [wav writeToURL:url atomically:YES];
    return url;
}

static BOOL Settles(BOOL (^done)(void));

// A queue of plain URLs, keyed by themselves. Two URLs for one file stay two
// rows. Off parks at the end, All wraps, One replays, and a shuffled cycle
// under All plays every row once.
static BOOL QueueWalksItsSuccessors(void) {
    NSURL *a = [NSURL fileURLWithPath:@"/consumer/a.mp3"];
    NSURL *b = [NSURL fileURLWithPath:@"/consumer/b.mp3"];
    NSURL *again = [[NSURL alloc] initFileURLWithPath:a.path];
    VibePlaylist<NSURL *> *queue = [[VibePlaylist<NSURL *> alloc] initWithURLKey:^NSURL *(NSURL *url) {
        return url;
    } sourceKey:^NSString *(NSURL *url) {
        return url.path;
    }];
    [queue replaceAllWithTracks:@[a, b, again] startingAtIndex:NSNotFound];
    if (again == a || [queue indexesOfTracksWithURL:a].count != 2 || [queue getIndexForTrack:again] != 2
            || queue.trackEndSuccessor != b) {
        fprintf(stderr, "consumer: the queue merged two rows of one file\n");
        return NO;
    }
    queue.currentIndex = 2;
    NSURL *off = queue.trackEndSuccessor;
    queue.repeatMode = VibeRepeatModeAll;
    NSURL *all = queue.trackEndSuccessor;
    queue.repeatMode = VibeRepeatModeOne;
    NSURL *one = queue.trackEndSuccessor;
    if (off || all != a || one != again) {
        fprintf(stderr, "consumer: the successors under Off, All, and One were %s, %s, and %s\n",
                off.path.UTF8String, all.path.UTF8String, one.path.UTF8String);
        return NO;
    }
    queue.repeatMode = VibeRepeatModeAll;
    queue.shuffleEnabled = YES;
    NSMutableArray<NSURL *> *heard = [NSMutableArray arrayWithObject:queue.currentTrack];
    for (NSUInteger i = 0; i < 5; i++) {
        NSURL *next = queue.trackEndSuccessor;
        if (!next || ![queue advanceAtTrackEnd] || queue.currentTrack != next) {
            fprintf(stderr, "consumer: the shuffled queue stopped after %lu tracks\n", (unsigned long)heard.count);
            return NO;
        }
        [heard addObject:next];
    }
    for (NSUInteger cycle = 0; cycle < 2; cycle++) {
        NSArray<NSURL *> *played = [heard subarrayWithRange:NSMakeRange(cycle * 3, 3)];
        if ([played indexOfObjectIdenticalTo:a] == NSNotFound || [played indexOfObjectIdenticalTo:b] == NSNotFound
                || [played indexOfObjectIdenticalTo:again] == NSNotFound) {
            fprintf(stderr, "consumer: a shuffled cycle did not play every row once\n");
            return NO;
        }
    }
    return YES;
}

// An M3U of a file whole and a CUE window, written and read back as the same
// entries, and a two-track CUE sheet read as two windows of its file.
static BOOL PlaylistsRoundTrip(void) {
    NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES
                                            attributes:nil error:NULL];
    NSURL *song = [directory URLByAppendingPathComponent:@"song.mp3"];
    NSURL *mix = [directory URLByAppendingPathComponent:@"mix.flac"];
    NSURL *sheet = [directory URLByAppendingPathComponent:@"mix.cue"];
    [[NSData dataWithBytes:"song" length:4] writeToURL:song atomically:YES];
    [[NSData dataWithBytes:"mix" length:3] writeToURL:mix atomically:YES];
    NSString *cue = @"PERFORMER \"DJ\"\nFILE \"mix.flac\" WAVE\n"
                     "  TRACK 01 AUDIO\n    TITLE \"One\"\n    INDEX 01 00:00:00\n"
                     "  TRACK 02 AUDIO\n    TITLE \"Two\"\n    INDEX 01 01:00:00\n";
    [[cue dataUsingEncoding:NSUTF8StringEncoding] writeToURL:sheet atomically:YES];
    NSArray<VibePlaylistEntry *> *cueEntries = [VibePlaylistFile entriesForPlaylistAtURL:sheet];
    BOOL sheetRead = cueEntries.count == 2 && [cueEntries[0].url.lastPathComponent isEqual:@"mix.flac"]
            && cueEntries[0].cueStart == 0 && cueEntries[0].cueEnd == 4500 && cueEntries[1].cueStart == 4500
            && cueEntries[1].cueEnd == 0 && [cueEntries[1].cueTitle isEqual:@"Two"]
            && [cueEntries[1].cuePerformer isEqual:@"DJ"];

    VibePlaylistEntry *whole = [VibePlaylistEntry entryWithURL:song];
    VibePlaylistEntry *window = [[VibePlaylistEntry alloc] initWithURL:mix cueStart:4500 cueEnd:9000 title:@"Two"
                                                             performer:@"DJ" sheet:sheet trackNumber:2 duration:60
                                                          displayTitle:@"Two" displayArtist:@"DJ"];
    NSURL *list = [directory URLByAppendingPathComponent:@"set.m3u"];
    NSError *error = nil;
    BOOL written = [VibePlaylistFile writeM3UForEntries:@[whole, window] relativeToDirectory:directory toURL:list
                                                  error:&error];
    NSArray<VibePlaylistEntry *> *read = [VibePlaylistFile entriesForPlaylistAtURL:list];
    NSString *text = [NSString stringWithContentsOfURL:list encoding:NSUTF8StringEncoding error:NULL];
    BOOL listRead = written && read.count == 2 && [read[0].url.lastPathComponent isEqual:@"song.mp3"]
            && !read[0].isWindowed && [read[1].url.lastPathComponent isEqual:@"mix.flac"]
            && read[1].cueStart == 4500 && read[1].cueEnd == 9000 && [read[1].cueTitle isEqual:@"Two"]
            && read[1].cueTrackNumber == 2 && [text containsString:@"#EXTINF:60,DJ - Two\n"];
    [NSFileManager.defaultManager removeItemAtURL:directory error:NULL];
    if (!sheetRead || !listRead) {
        fprintf(stderr, "consumer: the sheet read %lu entries, and the M3U %lu (%s)\n",
                (unsigned long)cueEntries.count, (unsigned long)read.count, error.localizedDescription.UTF8String);
        return NO;
    }
    return YES;
}

// The same folder as a catalog scans it: both tracks in batches, the M3U
// dropped, reading nothing, and a complete verdict once the token counts both.
static BOOL FolderScanScansACatalog(NSURL *album) {
    NSProgress *token = [NSProgress discreteProgressWithTotalUnitCount:-1];
    NSMutableArray<NSString *> *scanned = [NSMutableArray array];
    __block NSUInteger batches = 0;
    __block NSArray<NSNumber *> *verdicts = nil;
    __block NSArray<NSArray<NSError *> *> *failures = nil;
    [FolderWalk scanRoots:@[album] readPolicy:VibeFolderScanReadPolicyNone progress:token
                    batch:^(NSArray<VibePlaylistEntry *> *entries) {
        batches++;
        [scanned addObjectsFromArray:[entries valueForKeyPath:@"url.lastPathComponent"]];
    } completion:^(NSArray<NSNumber *> *rootVerdicts, NSArray<NSArray<NSError *> *> *rootFailures) {
        dispatch_async(dispatch_get_main_queue(), ^{
            failures = rootFailures;
            verdicts = rootVerdicts;
        });
    }];
    BOOL settled = Settles(^BOOL { return verdicts != nil; });
    BOOL complete = settled && [verdicts isEqual:@[@(VibeFolderScanVerdictComplete)]]
            && [failures isEqual:@[@[]]] && batches == 1 && token.completedUnitCount == 2
            && [[NSSet setWithArray:scanned] isEqual:[NSSet setWithArray:@[@"Track 2.mp3", @"Track 10.flac"]]]
            && scanned.count == 2;
    if (!complete) {
        fprintf(stderr, "consumer: the scan gave %s in %lu batches, %s, and %lld counted\n",
                scanned.description.UTF8String, (unsigned long)batches, verdicts.description.UTF8String,
                token.completedUnitCount);
        return NO;
    }
    return YES;
}

// A folder of two tracks and an M3U, walked in each order. The walk drops the
// M3U, since it would double the tracks, and the newer track leads under
// newest first. Opened alone, the M3U keeps its own order under any sort.
static BOOL FolderScanWalksATree(void) {
    NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    NSURL *album = [directory URLByAppendingPathComponent:@"album" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:album withIntermediateDirectories:YES
                                            attributes:nil error:NULL];
    NSURL *second = [album URLByAppendingPathComponent:@"Track 2.mp3"];
    NSURL *tenth = [album URLByAppendingPathComponent:@"Track 10.flac"];
    NSURL *list = [album URLByAppendingPathComponent:@"set.m3u"];
    [[NSData dataWithBytes:"two" length:3] writeToURL:second atomically:YES];
    [[NSData dataWithBytes:"ten" length:3] writeToURL:tenth atomically:YES];
    [[@"Track 10.flac\nTrack 2.mp3\n" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:list atomically:YES];
    [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:-60]}
                                   ofItemAtPath:second.path error:NULL];
    [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:-30]}
                                   ofItemAtPath:tenth.path error:NULL];

    NSArray<NSString *> * (^walk)(NSURL *, VibeFolderOpenSort, NSUInteger *) =
            ^NSArray<NSString *> *(NSURL *url, VibeFolderOpenSort sort, NSUInteger *folders) {
        __block NSArray<VibePlaylistEntry *> *found = nil;
        __block NSUInteger count = 0;
        [FolderWalk expandAndFilterList:@[url] sortedBy:sort
                             completion:^(NSArray<VibePlaylistEntry *> *entries, NSUInteger folderCount) {
            dispatch_async(dispatch_get_main_queue(), ^{
                count = folderCount;
                found = entries;
            });
        }];
        if (!Settles(^BOOL { return found != nil; })) {
            return nil;
        }
        *folders = count;
        return [found valueForKeyPath:@"url.lastPathComponent"];
    };
    NSUInteger byNameFolders = 0, newestFolders = 0, receivedFolders = 0, listFolders = 9;
    NSArray<NSString *> *byName = walk(album, VibeFolderOpenSortName, &byNameFolders);
    NSArray<NSString *> *newest = walk(album, VibeFolderOpenSortNewestFirst, &newestFolders);
    NSArray<NSString *> *received = walk(album, VibeFolderOpenSortAsReceived, &receivedFolders);
    NSArray<NSString *> *listed = walk(list, VibeFolderOpenSortName, &listFolders);
    BOOL scanned = FolderScanScansACatalog(album);
    [NSFileManager.defaultManager removeItemAtURL:directory error:NULL];
    if (!scanned) {
        return NO;
    }
    NSArray<NSString *> *numeric = @[@"Track 2.mp3", @"Track 10.flac"];
    NSArray<NSString *> *reversed = @[@"Track 10.flac", @"Track 2.mp3"];
    BOOL walked = [byName isEqual:numeric] && [newest isEqual:reversed]
            && [[NSSet setWithArray:received ?: @[]] isEqual:[NSSet setWithArray:numeric]] && received.count == 2
            && byNameFolders == 1 && newestFolders == 1 && receivedFolders == 1
            && [listed isEqual:reversed] && listFolders == 0;
    if (!walked) {
        fprintf(stderr, "consumer: the walk listed %s by name, %s newest first, %s as received, and %s from the M3U\n",
                byName.description.UTF8String, newest.description.UTF8String, received.description.UTF8String,
                listed.description.UTF8String);
        return NO;
    }
    return YES;
}

// Runs main's loop until done says so, for at most ten seconds.
// Thirty seconds of the analyzer tests' click track: a short decaying burst
// on each beat over a quiet tone. Fed in 4096-frame blocks.
static float ClickTrackTempo(double bpm) {
    const double rate = 44100.0;
    const size_t total = (size_t)(rate * 30.0);
    const double period = 60.0 / bpm * rate;
    float *audio = malloc(total * sizeof(float));
    for (size_t i = 0; i < total; i++) {
        double sinceBeat = fmod((double)i, period);
        double click = exp(-sinceBeat / 200.0) * sin((double)i * 0.7);
        audio[i] = (float)(0.9 * click + 0.05 * sin((double)i * 0.03));
    }
    AudioBPMAnalyzer *analyzer = [[AudioBPMAnalyzer alloc] initWithSampleRate:rate];
    for (size_t offset = 0; offset < total; offset += 4096) {
        [analyzer appendMonoSamples:audio + offset frameCount:MIN((size_t)4096, total - offset)];
    }
    free(audio);
    return [analyzer finish];
}

static BOOL Settles(BOOL (^done)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!done() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return done();
}

// The first view of a class under a view that passes a test, the view included.
static __kindof NSView *Find(NSView *view, Class kind, BOOL (^match)(id view)) {
    if ([view isKindOfClass:kind] && match(view)) {
        return view;
    }
    for (NSView *child in view.subviews) {
        NSView *found = Find(child, kind, match);
        if (found) {
            return found;
        }
    }
    return nil;
}

// How many views of a class sit under a view, the view included.
static NSUInteger Count(NSView *view, Class kind) {
    NSUInteger count = [view isKindOfClass:kind] ? 1 : 0;
    for (NSView *child in view.subviews) {
        count += Count(child, kind);
    }
    return count;
}

// Whether a view, drawn into a bitmap with no window, shows any pixel.
static BOOL Draws(NSView *view) {
    NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    for (NSInteger y = 0; y < rep.pixelsHigh; y++) {
        for (NSInteger x = 0; x < rep.pixelsWide; x++) {
            if ([rep colorAtX:x y:y].alphaComponent > 0) {
                return YES;
            }
        }
    }
    return NO;
}

// The equalizer's levels: the same five, always, and a count of the bars
// that want them.
@interface ConsumerLevels : NSObject <EqualizerLevelSource>
@property (nonatomic) NSInteger consumers;
@end

@implementation ConsumerLevels
- (BOOL)copyEqualizerLevels:(float *)outLevels count:(NSUInteger)count sequence:(uint64_t *)outSequence {
    for (NSUInteger i = 0; i < count; i++) {
        outLevels[i] = 0.8f;
    }
    *outSequence = 1;
    return YES;
}
- (void)equalizerLevelsWanted:(BOOL)wanted {
    self.consumers += wanted ? 1 : -1;
}
@end

// The bars ask their source once they are visible, in a window, and audio
// plays. They draw, and they let go when they leave the window.
static BOOL EqualizerDrawsFromItsSource(void) {
    ConsumerLevels *levels = [ConsumerLevels new];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 40, 24)
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES];
    window.releasedWhenClosed = NO;
    EqualizerIndicatorView *bars = [[EqualizerIndicatorView alloc] initWithFrame:NSMakeRect(0, 0, 16, 12)];
    bars.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    bars.levelSource = levels;
    bars.presentationVisible = YES;
    bars.audioOutputActive = YES;
    [window.contentView addSubview:bars];
    NSInteger wanted = levels.consumers;
    [bars layoutSubtreeIfNeeded];
    NSBitmapImageRep *rep = [bars bitmapImageRepForCachingDisplayInRect:bars.bounds];
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [bars.layer renderInContext:context.CGContext];
    [context flushGraphics];
    NSUInteger lit = 0;
    for (NSInteger y = 0; y < rep.pixelsHigh; y++) {
        for (NSInteger x = 0; x < rep.pixelsWide; x++) {
            lit += [rep colorAtX:x y:y].alphaComponent > 0;
        }
    }
    [bars removeFromSuperview];
    if (wanted != 1 || lit == 0 || levels.consumers != 0) {
        fprintf(stderr, "consumer: the bars wanted %ld, lit %lu pixels, and left %ld\n", (long)wanted,
                (unsigned long)lit, (long)levels.consumers);
        return NO;
    }
    return YES;
}

enum { kFrames = 512 };

static OSStatus Ramp(void *context, const AudioTimeStamp *stamp, UInt32 frames, AudioBufferList *into) CA_REALTIME_API {
    uint64_t *next = context;
    for (UInt32 c = 0; c < into->mNumberBuffers; c++) {
        float *out = into->mBuffers[c].mData;
        for (UInt32 n = 0; n < frames; n++) {
            out[n] = (float)((*next + n) % 1024) / 1024.0f;
        }
    }
    *next += frames;
    return noErr;
}

static float Tone(uint64_t frame) {
    return (float)(0.5 * sin(2.0 * M_PI * 1000.0 * (double)frame / 48000.0));
}

// A second of a 1 kHz tone through a connected FX chain with nothing engaged,
// then through a meter. The chain hands the tone back exactly. The meter
// lights the band from 800 to 4000 Hz, and the other four stay dark.
static BOOL TonePassesFXAndMeter(void) {
    dispatch_queue_t queue = dispatch_queue_create("consumer.audio", DISPATCH_QUEUE_SERIAL);
    AudioFX *fx = [[AudioFX alloc] initWithQueue:queue scheduler:^(NSTimeInterval seconds, dispatch_block_t block) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), queue, block);
    } afterRenderLeaves:^(dispatch_block_t work) {
        work();
    }];
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    AudioLevelPublisher *publisher = [[AudioLevelPublisher alloc] init];
    AudioLevelMeter *meter = [[AudioLevelMeter alloc] initWithFormat:format publisher:publisher
                                                   normalizationMode:kLevelDefaultNormalizationMode];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:kFrames];
    __block NSUInteger hosted = 0;
    __block OSStatus status = noErr;
    __block uint64_t changed = UINT64_MAX;
    dispatch_sync(queue, ^{
        [fx setConnected:YES format:format maximumFrameCount:kFrames];
        hosted = fx.hostedUnitCount;
        [meter install];
        AudioTimeStamp stamp = {0};
        stamp.mFlags = kAudioTimeStampSampleTimeValid;
        for (uint64_t first = 0; first < 48000 && hosted && status == noErr; first += kFrames) {
            for (UInt32 n = 0; n < kFrames; n++) {
                buffer.floatChannelData[0][n] = Tone(first + n);
                buffer.floatChannelData[1][n] = Tone(first + n);
            }
            buffer.frameLength = kFrames;
            stamp.mSampleTime = (Float64)first;
            status = VibeFXChainRender(fx.chain, &stamp, kFrames, buffer.mutableAudioBufferList);
            for (UInt32 n = 0; n < kFrames && changed == UINT64_MAX; n++) {
                float want = Tone(first + n);
                if (buffer.floatChannelData[0][n] != want || buffer.floatChannelData[1][n] != want) {
                    changed = first + n;
                }
            }
            VibeLevelMeterRender(meter.meter, buffer.floatChannelData, 2, kFrames, &stamp);
        }
    });
    float levels[kLevelBandCount] = {0};
    uint64_t sequence = 0;
    BOOL read = [publisher copyLevels:levels count:kLevelBandCount sequence:&sequence];
    dispatch_sync(queue, ^{
        [meter remove];
        [fx setConnected:NO format:nil maximumFrameCount:kFrames];
    });
    if (!hosted || status != noErr || changed != UINT64_MAX) {
        fprintf(stderr, "consumer: the chain hosted %lu units, rendered status %d, and changed frame %llu\n",
                (unsigned long)hosted, (int)status, changed);
        return NO;
    }
    BOOL dark = levels[0] < 0.1f && levels[1] < 0.1f && levels[2] < 0.1f && levels[4] < 0.1f;
    if (!read || !sequence || levels[3] < 0.5f || !dark) {
        fprintf(stderr, "consumer: the meter read %d at %llu: %.3f %.3f %.3f %.3f %.3f\n", read, sequence,
                levels[0], levels[1], levels[2], levels[3], levels[4]);
        return NO;
    }
    return YES;
}

int main(void) {
    // An app pushes its error domain at launch, before any player exists.
    VibeAudioErrorSetDomain(@"vibe-libs.Consumer");
    VibeVarispeed *stage = VibeVarispeedCreate(2, kFrames);
    if (!stage) {
        fprintf(stderr, "consumer: no stage\n");
        return 1;
    }
    float left[kFrames], right[kFrames];
    VibeStereoBufferList out = { 2, {{1, sizeof left, left}, {1, sizeof right, right}} };
    AudioTimeStamp stamp = {0};
    uint64_t next = 0;
    for (int slice = 0; slice < 8; slice++) {
        uint64_t first = next;
        VibeVarispeedRender(stage, Ramp, &next, &stamp, kFrames, (AudioBufferList *)&out);
        for (UInt32 n = 0; n < kFrames; n++) {
            float want = (float)((first + n) % 1024) / 1024.0f;
            if (left[n] != want || right[n] != want) {
                fprintf(stderr, "consumer: frame %llu is %f, not %f\n", first + n, left[n], want);
                return 1;
            }
        }
    }
    VibeVarispeedTable *replaced = NULL;
    if (!VibeVarispeedSetPitch(stage, 2.0, &replaced)) {
        fprintf(stderr, "consumer: no table\n");
        return 1;
    }
    for (int slice = 0; slice < 8; slice++) {
        VibeVarispeedRender(stage, Ramp, &next, &stamp, kFrames, (AudioBufferList *)&out);
    }
    if (replaced) {
        VibeVarispeedRetire(stage, replaced);
    }
    BOOL engaged = VibeVarispeedEngaged(stage);
    VibeVarispeedFree(stage);
    if (!engaged) {
        fprintf(stderr, "consumer: the converter never joined\n");
        return 1;
    }
    if (!TonePassesFXAndMeter()) {
        return 1;
    }
    NSString *hex = VibeHexStringFromColor(VibeColorFromHexString(@"#12345678"));
    if (![hex isEqualToString:@"#12345678"]) {
        fprintf(stderr, "consumer: the color came back as %s\n", hex.UTF8String);
        return 1;
    }
    NSRect frame = NSMakeRect(0, 0, 120, 20);
    VibeSlider *slider = [[VibeSlider alloc] initWithFrame:frame];
    slider.doubleValue = 0.5;
    VibeSwitch *toggle = [[VibeSwitch alloc] initWithFrame:NSMakeRect(0, 0, 44, 20)];
    VibeDetentSlider *detent = [[VibeDetentSlider alloc] initWithFrame:frame];
    detent.detentValue = 0.5;
    SymbolButton *button = [[SymbolButton alloc] initWithFrame:NSMakeRect(0, 0, 30, 30)];
    button.symbolName = @"play.fill";
    NSImage *note = [NSImage imageWithSystemSymbolName:@"music.note" accessibilityDescription:nil];
    ScaledImageView *scaled = [[ScaledImageView alloc] initWithFrame:frame];
    scaled.image = note;
    CrossfadingImageView *crossfading = [[CrossfadingImageView alloc] initWithFrame:frame];
    crossfading.image = note;
    VibeLinkLabel *link = [VibeLinkLabel labelWithString:@"vibe-libs"];
    link.linkURL = [NSURL URLWithString:@"https://github.com/cmicali/vibe-libs"];
    link.linkRange = NSMakeRange(0, 9);
    PitchFaderView *fader = [[PitchFaderView alloc] initWithFrame:NSMakeRect(0, 0, 88, 300)];
    PitchControlPanel *pitch = [[PitchControlPanel alloc] initWithFrame:NSMakeRect(0, 0, kPitchPanelWidth, 400)];
    pitch.title = @"PITCH";
    pitch.cornerRadius = 8;
    for (NSView *view in @[slider, toggle, detent, button, scaled, crossfading, link, fader, pitch]) {
        if (!Draws(view)) {
            fprintf(stderr, "consumer: %s drew nothing\n", view.className.UTF8String);
            return 1;
        }
    }
    if (![fader accessibilityPerformIncrement] || fader.pitch != 0.5f) {
        fprintf(stderr, "consumer: the pitch fader stepped to %.2f\n", fader.pitch);
        return 1;
    }
    NSMutableArray<NSColor *> *pair = [@[NSColor.blackColor, NSColor.whiteColor] mutableCopy];
    ConsumerPane *look = [[ConsumerPane alloc] initWithEffectsSink:^(NSUInteger effects) {}];
    look.build = ^NSArray<NSView *> *(ConsumerPane *pane) {
        SettingsColorRow *colors = [SettingsColorRow rowWithCaptions:@[@"Dark", @"Light"]
                supportsAlpha:NO
                         read:^NSColor *(NSUInteger index) { return pair[index]; }
                        write:^(NSUInteger index, NSColor *color) { pair[index] = color; }
                      changed:^(BOOL continuous) {}];
        return @[[SettingsSectionView sectionWithHeader:@"Look" rows:@[
            [SettingsRowView rowWithTitle:@"Accent" control:colors],
            [SettingsRowView rowWithTitle:@"Compact" control:[pane switchWithAction:@selector(changed:)]],
        ]]];
    };
    ConsumerPane *sound = [[ConsumerPane alloc] initWithEffectsSink:^(NSUInteger effects) {}];
    sound.build = ^NSArray<NSView *> *(ConsumerPane *pane) {
        NSSlider *volume = nil;
        NSTextField *readout = nil;
        NSStackView *cluster = [pane detentSliderClusterWithDetent:0.5 min:0 max:1 action:@selector(changed:) width:160
                                                            slider:&volume valueLabel:&readout];
        return @[[SettingsSectionView sectionWithRows:@[[SettingsRowView rowWithTitle:@"Volume" control:cluster]]]];
    };
    // The recorder's monitor sees only events NSApp sends.
    [NSApplication sharedApplication];
    VibeShortcutSetKeyNames(@"Space", @"Keypad %@", @"Key %ld", @"None");
    NSArray<NSArray *> *commands = @[@[@"zoom_in", @(kVibeShortcutNone)], @[@"zoom_out", @(kVibeShortcutNone)]];
    NSMutableDictionary<NSString *, NSNumber *> *bindings = [NSMutableDictionary dictionary];
    NSMutableArray<NSNumber *> *assigned = [NSMutableArray array];
    SettingsShortcutsViewController *keys = [[SettingsShortcutsViewController alloc]
            initWithEffectsSink:^(NSUInteger effects) {}
                    commandRows:^{ return @[@[@"View", @[@[@"zoom_in", @"Zoom In"], @[@"zoom_out", @"Zoom Out"]]]]; }
             shortcutForCommand:^(NSString *identifier) { return VibeShortcutEffective(commands, identifier, bindings); }
                      overrides:^{ return [bindings copy]; }
                   setOverrides:^(NSDictionary<NSString *, NSNumber *> *overrides) { [bindings setDictionary:overrides]; }
                         assign:^(VibeShortcut shortcut, NSString *identifier, NSString **loser) {
                             [assigned addObject:@(shortcut)];
                             [bindings setDictionary:VibeShortcutOverridesByAssigning(commands, bindings, identifier,
                                                                                      shortcut, 0, loser)];
                             return VibeShortcutAssignmentStored;
                         }];
    keys.commandColumnTitle = @"Command";
    keys.shortcutColumnTitle = @"Shortcut";
    keys.recordTitle = @"Record Shortcut";
    keys.clearTitle = @"Clear";
    keys.resetAllTitle = @"Reset All";
    keys.explainer = @"Select a command, then record its shortcut.";
    keys.layoutNote = @"Keys follow the keyboard layout.";
    keys.selectTip = @"Select a command first.";
    keys.noneTip = @"This command has no shortcut.";
    keys.defaultsTip = @"Every shortcut is its default.";
    keys.undoActionName = @"Change Shortcut";
    keys.recordingFormat = @"Type a shortcut for %@.";
    keys.reservedFormat = @"%@ is reserved.";
    keys.unusableCaption = @"That key cannot be shown.";
    keys.reassignedFormat = @"%@ moved to %@ from %@.";
    SettingsPanesWindowController *settings = [[SettingsPanesWindowController alloc]
            initWithPaneGroups:@[@[
                [SettingsPanesWindowController paneItemWithViewController:look identifier:@"look"
                                                                    label:@"Look" symbolName:@"paintbrush"],
                [SettingsPanesWindowController paneItemWithViewController:sound identifier:@"sound"
                                                                    label:@"Sound" symbolName:@"speaker.wave.2"],
                [SettingsPanesWindowController paneItemWithViewController:keys identifier:@"keys"
                                                                    label:@"Keys" symbolName:@"keyboard"],
            ]]
                     backTitle:@"Back" forwardTitle:@"Forward" undoTitle:@"Undo" redoTitle:@"Redo"
             searchPlaceholder:@"Search" noResultsText:@"No Results"];
    if (Count(look.view, SettingsColorRow.class) != 1 || Count(look.view, VibeSwitch.class) != 1
            || Count(look.view, NSSlider.class) != 0 || Count(sound.view, NSSlider.class) != 1) {
        fprintf(stderr, "consumer: the panes do not hold the color pair, the switch, and the slider\n");
        return 1;
    }
    NSSplitViewController *split = (NSSplitViewController *)settings.window.contentViewController;
    SettingsSidebarController *sidebar =
            (SettingsSidebarController *)split.splitViewItems.firstObject.viewController;
    [sidebar.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
    if (![settings.selectedTabItem.identifier isEqual:@"sound"] || ![settings.window.title isEqual:@"Sound"]
            || settings.window.isVisible) {
        fprintf(stderr, "consumer: the sidebar did not select the second pane\n");
        return 1;
    }
    [sidebar.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:2] byExtendingSelection:NO];
    [keys refreshFromSettings];
    NSTableView *list = Find(keys.view, NSTableView.class, ^BOOL(id view) { return YES; });
    [list selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
    NSButton *record = Find(keys.view, NSButton.class, ^BOOL(NSButton *button) {
        return [button.title isEqualToString:@"Record Shortcut"];
    });
    [record performClick:nil];
    NSEventModifierFlags held = NSEventModifierFlagControl | NSEventModifierFlagOption;
    for (NSNumber *type in @[@(NSEventTypeKeyDown), @(NSEventTypeKeyUp)]) {
        [NSApp sendEvent:[NSEvent keyEventWithType:(NSEventType)type.unsignedIntegerValue location:NSZeroPoint
                                     modifierFlags:held timestamp:0 windowNumber:settings.window.windowNumber
                                           context:nil characters:@"" charactersIgnoringModifiers:@""
                                         isARepeat:NO keyCode:0]];
    }
    VibeShortcut recorded = VibeShortcutMake(0, held);
    NSTableCellView *cell = [list viewAtColumn:1 row:1 makeIfNecessary:YES];
    if (![assigned isEqual:@[@(recorded)]] || ![bindings isEqual:@{@"zoom_in": @(recorded)}]
            || ![cell.textField.stringValue isEqualToString:VibeShortcutDisplayString(recorded)]) {
        fprintf(stderr, "consumer: the pane did not record ⌃⌥ and the key, and shows %s\n",
                cell.textField.stringValue.UTF8String);
        return 1;
    }
    [settings.window close];
    NSURL *file = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    [[NSData dataWithBytes:"one" length:3] writeToURL:file atomically:YES];
    NSString *key = file.cacheKey;
    [[NSData dataWithBytes:"four" length:4] writeToURL:file atomically:YES];
    NSString *changed = file.cacheKey;
    [NSFileManager.defaultManager removeItemAtURL:file error:NULL];
    if (![key hasPrefix:@"3-"] || ![changed hasPrefix:@"4-"] || file.cacheKey) {
        fprintf(stderr, "consumer: the disk keys were %s, then %s\n", key.UTF8String, changed.UTF8String);
        return 1;
    }
    NSRange window = VibeCueWindow(75, 150, 48000, 480000, NO);
    if (!NSEqualRanges(window, NSMakeRange(48000, 48000))) {
        fprintf(stderr, "consumer: the window is %s\n", NSStringFromRange(window).UTF8String);
        return 1;
    }
    if (!ConsumerOpensAFile() || !ConsumerCancelsACloudOpen()) {
        return 1;
    }
    NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES
                                            attributes:nil error:NULL];
    PINCache *cache = [PINCache audioCacheWithName:@"consumer" rootPath:directory.path];
    [cache.diskCache setObject:@"entry" forKey:@"key"];
    __block NSUInteger entries = 0;
    __block BOOL counted = NO;
    [cache audioDiskUsageWithCompletion:^(NSUInteger fileCount, unsigned long long totalBytes) {
        entries = fileCount;
        counted = YES;
    }];
    BOOL cached = Settles(^BOOL { return counted; }) && entries == 1
            && [cache.diskCache.cacheURL.path hasPrefix:directory.path]
            && [(NSString *)[cache.diskCache objectForKey:@"key"] isEqual:@"entry"];
    [NSFileManager.defaultManager removeItemAtURL:directory error:NULL];
    if (!cached) {
        fprintf(stderr, "consumer: the disk cache holds %lu entries\n", (unsigned long)entries);
        return 1;
    }
    // A published snapshot, empty or not. The first sweep runs from the
    // manager's init, and a refused sweep retries. A HAL with no devices
    // publishes an empty one. A HAL that cannot read its device list, as on a
    // runner with no coreaudiod, publishes none, so the check is skipped then.
    AudioDeviceManager *outputs = AudioDeviceManager.sharedInstance;
    if (!Settles(^BOOL { return outputs.cachedOutputDevices != nil; })) {
        AudioObjectPropertyAddress list = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal,
                                           kAudioObjectPropertyElementMain};
        UInt32 size = 0;
        OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &list, 0, NULL, &size);
        if (status == noErr) {
            fprintf(stderr, "consumer: the device manager published no snapshot of a readable HAL\n");
            return 1;
        }
        printf("consumer: skipped the output devices, since the HAL reads no device list (OSStatus %d)\n",
               (int)status);
    }
    else {
        NSArray<AudioDevice *> *found = outputs.cachedOutputDevices;
        AudioDevice *standard = nil;
        for (AudioDevice *device in found) {
            if (device.isSystemDefault) {
                standard = device;
            }
        }
        printf("consumer: %lu output devices, the default is %s\n", (unsigned long)found.count,
               standard ? standard.name.UTF8String : "none");
    }
    // Each frame's left sample is its index, and its right sample the negation.
    enum { kFrames = 1000 };
    NSURL *wavURL = ConsumerRampWAV(44100, kFrames, 0);
    NSError *readError = nil;
    AudioFileHandle *handle = [[AudioFileHandle alloc] initForReading:wavURL error:&readError];
    AVAudioPCMBuffer *frames = handle ? [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat
                                                                       frameCapacity:kFrames + 16] : nil;
    BOOL read = frames && [handle readIntoBuffer:frames error:&readError] && frames.frameLength == kFrames
            && handle.length == kFrames && [handle.decoderName isEqualToString:@"dr_wav"];
    for (AVAudioFrameCount i = 0; read && i < kFrames; i++) {
        read = frames.floatChannelData[0][i] == i / 32768.0f && frames.floatChannelData[1][i] == -(float)i / 32768.0f;
    }
    handle = nil;
    [NSFileManager.defaultManager removeItemAtURL:wavURL error:NULL];
    if (!read) {
        fprintf(stderr, "consumer: the handle read %u frames (%s)\n", frames.frameLength,
                readError.localizedDescription.UTF8String);
        return 1;
    }
    float tempo = ClickTrackTempo(128.0);
    if (fabsf(tempo - 128.0f) > 1.0f) {
        fprintf(stderr, "consumer: the click track's tempo is %.2f\n", tempo);
        return 1;
    }
    if (!ConsumerReadsTags() || !ConsumerLoadsMetadata() || !QueueWalksItsSuccessors() || !PlaylistsRoundTrip() ||
        !FolderScanWalksATree()) {
        return 1;
    }
    if (!ConsumerWaveformHolds() || !ConsumerLoadsAWaveform() || !ConsumerHitsTheWaveformCache()) {
        return 1;
    }
    if (!ConsumerWaveformStylesHold() || !ConsumerWaveformViewDraws()) {
        return 1;
    }
    if (!EqualizerDrawsFromItsSource()) {
        return 1;
    }
    if (!ConsumerPlaysAQueue()) {
        return 1;
    }
    if (!ConsumerPublishesNowPlaying()) {
        return 1;
    }
    if (!ConsumerFetchesFromTheFakeHost() || !ConsumerDebugChannelAnswers()) {
        return 1;
    }
    if (!ConsumerSandboxAccessHolds()) {
        return 1;
    }
    if (!ConsumerOrdersASplitOpen()) {
        return 1;
    }
    printf("consumer OK\n");
    return 0;
}
