//
//  VibeEQPresetLibrary.m
//  vibe-libs
//

#import "VibeEQPresetLibrary.h"

// Lowercase, with no marks. The letters that hold no mark to strip, as in
// "RØDE", are spelled out, so "rode" finds it.
static NSString *Folded(NSString *text) {
    static NSDictionary<NSString *, NSString *> *letters;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        letters = @{@"ø" : @"o", @"æ" : @"ae", @"œ" : @"oe", @"ß" : @"ss", @"đ" : @"d", @"ł" : @"l", @"ı" : @"i"};
    });
    NSString *folded = [text stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch
                                                 locale:nil];
    for (NSString *letter in letters) {
        folded = [folded stringByReplacingOccurrencesOfString:letter withString:letters[letter]];
    }
    return folded;
}

static VibeEQPreset *BuiltIn(NSString *identifier, NSString *name, NSArray<NSNumber *> *gains) {
    return [[VibeEQPreset alloc] initWithIdentifier:[@"builtin." stringByAppendingString:identifier]
                                               name:name
                                               kind:VibeEQPresetKindBuiltIn
                                             source:nil
                                              bands:[VibeListeningSettings graphicBandsWithGains:gains]
                                           preampDB:0];
}

enum { kRankPrefix, kRankWord, kRankContains, kRankEveryWord, kRankCount };

// How well `name` matches `query`, both folded, or kRankCount for no match.
static NSUInteger Rank(NSString *name, NSString *query, NSArray<NSString *> *words) {
    NSCharacterSet *alphanumerics = NSCharacterSet.alphanumericCharacterSet;
    NSUInteger rank = kRankCount;
    NSRange search = NSMakeRange(0, name.length);
    while (rank > kRankWord) {
        NSRange found = [name rangeOfString:query options:NSLiteralSearch range:search];
        if (found.location == NSNotFound) {
            break;
        }
        if (found.location == 0) {
            return kRankPrefix;
        }
        BOOL wordStart = ![alphanumerics characterIsMember:[name characterAtIndex:found.location - 1]];
        rank = MIN(rank, wordStart ? (NSUInteger)kRankWord : (NSUInteger)kRankContains);
        search = NSMakeRange(found.location + 1, name.length - found.location - 1);
    }
    if (rank < kRankCount || words.count < 2) {
        return rank;
    }
    for (NSString *word in words) {
        if ([name rangeOfString:word options:NSLiteralSearch].location == NSNotFound) {
            return kRankCount;
        }
    }
    return kRankEveryWord;
}

@implementation VibeEQPresetLibrary {
    NSArray<VibeEQPreset *> * (^_loader)(void);
    dispatch_queue_t _queue;
    // Set once, on _queue: the headphones in name order, their folded names,
    // and the lookup.
    NSArray<VibeEQPreset *> *_headphones;
    NSArray<NSString *> *_foldedNames;
    NSDictionary<NSString *, VibeEQPreset *> *_byIdentifier;
}

+ (instancetype)sharedLibrary {
    static VibeEQPresetLibrary *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[VibeEQPresetLibrary alloc] initWithHeadphonesLoader:^NSArray<VibeEQPreset *> * {
            return @[];
        }];
    });
    return shared;
}

- (instancetype)initWithHeadphonesLoader:(NSArray<VibeEQPreset *> * (^)(void))loader {
    self = [super init];
    if (self) {
        _loader = [loader copy];
        _queue = dispatch_queue_create("vibe.eqpresets.library", DISPATCH_QUEUE_SERIAL);
        _builtInPresets = @[
            BuiltIn(@"flat", @"Flat", @[ @0, @0, @0, @0, @0, @0, @0, @0, @0, @0 ]),
            BuiltIn(@"bass-boost", @"Bass Boost", @[ @6, @5, @4, @2, @0, @0, @0, @0, @0, @0 ]),
            BuiltIn(@"treble-boost", @"Treble Boost", @[ @0, @0, @0, @0, @0, @0, @1, @3, @5, @6 ]),
            BuiltIn(@"vocal", @"Vocal", @[ @-2, @-2, @-1, @0, @2, @3, @3, @2, @0, @-1 ]),
            BuiltIn(@"loudness", @"Loudness", @[ @5, @4, @2, @0, @-1, @0, @0, @1, @3, @4 ]),
            BuiltIn(@"bass-cut", @"Bass Cut", @[ @-6, @-5, @-4, @-2, @0, @0, @0, @0, @0, @0 ]),
        ];
    }
    return self;
}

// On _queue.
- (void)loadIfNeeded {
    if (_headphones != nil) {
        return;
    }
    NSArray<VibeEQPreset *> *headphones =
        [_loader() ?: @[] sortedArrayUsingComparator:^NSComparisonResult(VibeEQPreset *a, VibeEQPreset *b) {
            NSComparisonResult result =
                [a.name compare:b.name options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch];
            return result != NSOrderedSame ? result : [a.name compare:b.name];
        }];
    _loader = nil;
    NSMutableArray<NSString *> *foldedNames = [NSMutableArray arrayWithCapacity:headphones.count];
    for (VibeEQPreset *preset in headphones) {
        [foldedNames addObject:Folded(preset.name)];
    }
    _foldedNames = foldedNames;
    _byIdentifier = [NSDictionary dictionaryWithObjects:headphones forKeys:[headphones valueForKey:@"identifier"]];
    _headphones = headphones;
}

- (void)searchHeadphones:(NSString *)query
                   limit:(NSUInteger)limit
              completion:(void (^)(NSArray<VibeEQPreset *> *results))completion {
    NSString *folded = [Folded(query) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    dispatch_async(_queue, ^{
        [self loadIfNeeded];
        NSArray<VibeEQPreset *> *results = [self headphonesMatching:folded limit:limit];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(results);
        });
    });
}

// On _queue. Each rank keeps the name order, so ties sort by name.
- (NSArray<VibeEQPreset *> *)headphonesMatching:(NSString *)query limit:(NSUInteger)limit {
    NSUInteger cap = limit == 0 ? NSUIntegerMax : limit;
    if (query.length == 0) {
        return _headphones.count > cap ? [_headphones subarrayWithRange:NSMakeRange(0, cap)] : _headphones;
    }
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSString *word in [query componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (word.length > 0) {
            [words addObject:word];
        }
    }
    NSMutableArray<VibeEQPreset *> *ranked[kRankCount];
    for (NSUInteger rank = 0; rank < kRankCount; rank++) {
        ranked[rank] = [NSMutableArray array];
    }
    for (NSUInteger index = 0; index < _foldedNames.count; index++) {
        NSUInteger rank = Rank(_foldedNames[index], query, words);
        if (rank < kRankCount) {
            [ranked[rank] addObject:_headphones[index]];
        }
    }
    NSMutableArray<VibeEQPreset *> *results = [NSMutableArray array];
    for (NSUInteger rank = 0; rank < kRankCount && results.count < cap; rank++) {
        NSUInteger take = MIN(ranked[rank].count, cap - results.count);
        [results addObjectsFromArray:[ranked[rank] subarrayWithRange:NSMakeRange(0, take)]];
    }
    return results;
}

- (VibeEQPreset *)headphoneWithIdentifier:(NSString *)identifier {
    __block VibeEQPreset *found;
    dispatch_sync(_queue, ^{
        [self loadIfNeeded];
        found = self->_byIdentifier[identifier];
    });
    return found;
}

@end
