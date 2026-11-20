//
//  PlayableExtensions.m
//  vibe-libs
//

#import "PlayableExtensions.h"

@implementation PlayableExtensions

+ (NSArray<NSString *> *)ordered {
    static NSArray<NSString *> *ordered;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ordered = @[@"wav", @"wave", @"bwf", @"w64", @"aif", @"aiff", @"aifc", @"afc", @"flac", @"wv", @"ape", @"dsf", @"caf",
                    @"m4a", @"mp4", @"qta", @"m4b", @"m4r", @"aac", @"adts",
                    @"ogg", @"oga", @"opus", @"mp3", @"mp2"];
    });
    return ordered;
}

+ (NSSet<NSString *> *)lookup {
    static NSSet<NSString *> *lookup;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lookup = [NSSet setWithArray:PlayableExtensions.ordered];
    });
    return lookup;
}

+ (NSSet<NSString *> *)tagParsed {
    static NSSet<NSString *> *tagParsed;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableSet<NSString *> *set = [PlayableExtensions.lookup mutableCopy];
        [set minusSet:[NSSet setWithArray:@[@"w64", @"caf"]]];
        tagParsed = set;
    });
    return tagParsed;
}

// "c" in the case of the extension's last letter, or "wvc" for none.
static NSString *VibeCorrectionExtension(NSString *extension) {
    if (extension.length == 0) {
        return @"wvc";
    }
    unichar last = [extension characterAtIndex:extension.length - 1];
    return [extension stringByAppendingString:[NSCharacterSet.uppercaseLetterCharacterSet characterIsMember:last] ? @"C" : @"c"];
}

+ (NSArray<NSURL *> *)wavPackCorrectionSpellingsOf:(NSURL *)url {
    NSURL *base = url.URLByDeletingPathExtension;
    NSMutableArray<NSURL *> *spellings = [NSMutableArray array];
    for (NSString *spelling in [NSOrderedSet orderedSetWithArray:@[VibeCorrectionExtension(url.pathExtension), @"wvc", @"WVC"]]) {
        [spellings addObject:[base URLByAppendingPathExtension:spelling]];
    }
    return spellings;
}

+ (NSArray<NSString *> *)wavPackPathsOfCorrectionPath:(NSString *)path {
    NSString *extension = path.pathExtension;
    if (![extension.lowercaseString isEqualToString:@"wvc"]) {
        return @[];
    }
    NSString *base = path.stringByDeletingPathExtension;
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSString *spelling in [NSOrderedSet orderedSetWithArray:@[[extension substringToIndex:2], @"wv", @"WV"]]) {
        [paths addObject:[base stringByAppendingPathExtension:spelling]];
    }
    return paths;
}

@end
