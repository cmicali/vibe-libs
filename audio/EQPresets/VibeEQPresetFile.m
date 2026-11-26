//
//  VibeEQPresetFile.m
//  vibe-libs
//

#import "VibeEQPresetFile.h"

NSErrorDomain const VibeEQPresetFileErrorDomain = @"VibeEQPresetFileErrorDomain";

static const double kDefaultQ = 0.707;

// A number with a point as the decimal mark, whatever the locale, or NO.
static BOOL ReadNumber(NSString *token, double *value) {
    NSScanner *scanner = [NSScanner scannerWithString:token];
    scanner.locale = nil;
    double read = 0;
    if (![scanner scanDouble:&read] || !scanner.isAtEnd || !isfinite(read)) {
        return NO;
    }
    *value = read;
    return YES;
}

static NSArray<NSString *> *Tokens(NSString *text) {
    NSArray *parts = [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return [parts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
}

static BOOL ReadType(NSString *token, VibeEQBandType *type) {
    static NSDictionary<NSString *, NSNumber *> *types;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        types = @{
            @"PK" : @(VibeEQBandTypePeak),      @"PEQ" : @(VibeEQBandTypePeak),
            @"LSC" : @(VibeEQBandTypeLowShelf), @"LS" : @(VibeEQBandTypeLowShelf),
            @"HSC" : @(VibeEQBandTypeHighShelf), @"HS" : @(VibeEQBandTypeHighShelf),
            @"LP" : @(VibeEQBandTypeLowPass),   @"LPQ" : @(VibeEQBandTypeLowPass),
            @"HP" : @(VibeEQBandTypeHighPass),  @"HPQ" : @(VibeEQBandTypeHighPass),
        };
    });
    NSNumber *found = types[token.uppercaseString];
    if (found == nil) {
        return NO;
    }
    *type = found.integerValue;
    return YES;
}

// "ON PK Fc 105 Hz Gain -3.1 dB Q 0.70", the part after "Filter 1:".
static VibeEQBand *ReadFilter(NSString *text) {
    NSArray<NSString *> *tokens = Tokens(text);
    if (tokens.count < 2) {
        return nil;
    }
    NSString *state = tokens[0].uppercaseString;
    if (![state isEqualToString:@"ON"] && ![state isEqualToString:@"OFF"]) {
        return nil;
    }
    VibeEQBandType type;
    if (!ReadType(tokens[1], &type)) {
        return nil;
    }
    double frequency = NAN, gain = 0, q = kDefaultQ;
    for (NSUInteger i = 2; i + 1 < tokens.count; i++) {
        NSString *key = tokens[i].lowercaseString;
        double *slot = [key isEqualToString:@"fc"] ? &frequency
                     : [key isEqualToString:@"gain"] ? &gain
                     : [key isEqualToString:@"q"] ? &q
                     : NULL;
        if (slot != NULL && ReadNumber(tokens[i + 1], slot)) {
            i++;
        }
    }
    if (isnan(frequency)) {
        return nil;
    }
    return [[VibeEQBand alloc] initWithType:type
                                  frequency:frequency
                                     gainDB:gain
                                          q:q
                                    enabled:[state isEqualToString:@"ON"]];
}

// To three decimals, with no trailing zeros: 105, -3.1, 0.707.
static NSString *Number(double value) {
    NSString *text = [NSString stringWithFormat:@"%.3f", value];
    while ([text hasSuffix:@"0"]) {
        text = [text substringToIndex:text.length - 1];
    }
    if ([text hasSuffix:@"."]) {
        text = [text substringToIndex:text.length - 1];
    }
    return [text isEqualToString:@"-0"] ? @"0" : text;
}

@implementation VibeEQPresetFile

+ (VibeEQPreset *)presetFromEqualizerAPOText:(NSString *)text name:(NSString *)name error:(NSError **)error {
    double preamp = 0;
    NSMutableArray<VibeEQBand *> *bands = [NSMutableArray array];
    for (NSString *rawLine in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) {
            continue;
        }
        NSString *label = [line substringToIndex:colon.location].lowercaseString;
        NSString *rest = [line substringFromIndex:NSMaxRange(colon)];
        if ([label isEqualToString:@"preamp"]) {
            NSString *value = Tokens(rest).firstObject;
            if (value != nil) {
                ReadNumber(value, &preamp);
            }
        } else if ([label hasPrefix:@"filter"] && bands.count < kVibeListeningMaxBands) {
            VibeEQBand *band = ReadFilter(rest);
            if (band != nil) {
                [bands addObject:band];
            }
        }
    }
    if (bands.count == 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:VibeEQPresetFileErrorDomain
                                         code:VibeEQPresetFileErrorNoFilters
                                     userInfo:@{NSDebugDescriptionErrorKey : @"The text holds no filter to read."}];
        }
        return nil;
    }
    return [[VibeEQPreset alloc] initWithIdentifier:[@"user." stringByAppendingString:NSUUID.UUID.UUIDString]
                                               name:name
                                               kind:VibeEQPresetKindUser
                                             source:nil
                                              bands:bands
                                           preampDB:preamp];
}

+ (NSString *)equalizerAPOTextForPreset:(VibeEQPreset *)preset {
    NSMutableString *text = [NSMutableString stringWithFormat:@"Preamp: %@ dB\n", Number(preset.preampDB)];
    [preset.bands enumerateObjectsUsingBlock:^(VibeEQBand *band, NSUInteger index, BOOL *stop) {
        NSString *state = band.enabled ? @"ON" : @"OFF";
        NSString *fc = Number(band.frequency), *q = Number(band.q);
        switch (band.type) {
            case VibeEQBandTypeLowPass:
            case VibeEQBandTypeHighPass:
                [text appendFormat:@"Filter %lu: %@ %@ Fc %@ Hz Q %@\n", (unsigned long)index + 1, state,
                                   band.type == VibeEQBandTypeLowPass ? @"LPQ" : @"HPQ", fc, q];
                break;
            case VibeEQBandTypePeak:
            case VibeEQBandTypeLowShelf:
            case VibeEQBandTypeHighShelf: {
                NSString *type = band.type == VibeEQBandTypePeak ? @"PK"
                               : band.type == VibeEQBandTypeLowShelf ? @"LSC"
                               : @"HSC";
                [text appendFormat:@"Filter %lu: %@ %@ Fc %@ Hz Gain %@ dB Q %@\n", (unsigned long)index + 1, state,
                                   type, fc, Number(band.gainDB), q];
                break;
            }
        }
    }];
    return text;
}

@end
