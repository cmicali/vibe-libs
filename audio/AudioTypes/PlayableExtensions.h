//
//  PlayableExtensions.h
//  vibe-libs
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Every audio extension the decoders open. Foundation-only so both readers can
// import it: the app's folder walk imports its playlist reader, so neither
// could own the set.
//
// Must cover every spelling CFBundleDocumentTypes admits, conformance
// included (com.microsoft.waveform-audio is wav, wave AND bwf;
// public.mpeg-4-audio takes in the m4r ringtone, public.aac-audio adts), or
// the Finder offers the app a file the open filter silently discards.
@interface PlayableExtensions : NSObject

// Lowercase, lossless before lossy: a playlist entry naming a missing file
// takes the first spelling that exists, so the order picks the replacement.
@property (class, readonly) NSArray<NSString *> *ordered;

@property (class, readonly) NSSet<NSString *> *lookup;

// The playable ones TagLib parses (the tag parser's open by extension, adts
// by its content). The rest — w64, caf — take their facts from
// CoreAudio, which reads only a whole local file.
@property (class, readonly) NSSet<NSString *> *tagParsed;

// A hybrid WavPack file's correction file, which is never a song: the
// spellings to look for beside the .wv at `url`, in order. The same name, with
// the .wv's extension and a c in its case (wv to wvc, WV to WVC), then wvc,
// then WVC. A case-sensitive volume needs all three. A file with no extension
// looks for its name plus .wvc. audio/Decode's play and its indexer's check
// both search these.
+ (NSArray<NSURL *> *)wavPackCorrectionSpellingsOf:(NSURL *)url;

// The other way: the WavPack files a correction file at `path` may belong
// to, as paths in its folder: its name with wv in the .wvc's case, then in
// lowercase, then in uppercase, each once. Empty for a path that is not a
// .wvc. An app that watches its folders reads a .wv again when its .wvc
// comes or goes, since the .wv then plays lossless or lossy.
+ (NSArray<NSString *> *)wavPackPathsOfCorrectionPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
