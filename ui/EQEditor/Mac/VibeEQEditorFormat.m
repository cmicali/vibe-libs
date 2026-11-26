//
//  VibeEQEditorFormat.m
//  vibe-libs
//

#import "VibeEQEditorFormat.h"

// Formatters are slow to make, so each kind is kept for the last locale it
// served. Main thread only, as the view is.
static NSNumberFormatter *VibeEQFormatter(NSString *kind, NSLocale *locale, void (^configure)(NSNumberFormatter *)) {
    static NSMutableDictionary<NSString *, NSNumberFormatter *> *cache;
    if (!cache) {
        cache = [NSMutableDictionary dictionary];
    }
    NSNumberFormatter *formatter = cache[kind];
    if (!formatter || ![formatter.locale.localeIdentifier isEqualToString:locale.localeIdentifier]) {
        formatter = [[NSNumberFormatter alloc] init];
        formatter.locale = locale;
        configure(formatter);
        cache[kind] = formatter;
    }
    return formatter;
}

NSString *VibeEQFormatFrequency(double frequency, NSLocale *locale) {
    NSNumberFormatter *f = VibeEQFormatter(@"frequency", locale, ^(NSNumberFormatter *formatter) {
        formatter.numberStyle = NSNumberFormatterDecimalStyle;
        formatter.maximumFractionDigits = 0;
    });
    return [NSString stringWithFormat:@"%@ Hz", [f stringFromNumber:@(round(frequency))]];
}

NSString *VibeEQFormatShortFrequency(double frequency, NSLocale *locale) {
    NSNumberFormatter *f = VibeEQFormatter(@"short", locale, ^(NSNumberFormatter *formatter) {
        formatter.numberStyle = NSNumberFormatterDecimalStyle;
        formatter.usesGroupingSeparator = NO;
        formatter.maximumFractionDigits = 1;
    });
    if (frequency >= 1000) {
        return [NSString stringWithFormat:@"%@k", [f stringFromNumber:@(frequency / 1000)]];
    }
    return [f stringFromNumber:@(round(frequency))];
}

NSString *VibeEQFormatGain(double gainDB, NSLocale *locale) {
    NSNumberFormatter *f = VibeEQFormatter(@"gain", locale, ^(NSNumberFormatter *formatter) {
        formatter.numberStyle = NSNumberFormatterDecimalStyle;
        formatter.minimumFractionDigits = 1;
        formatter.maximumFractionDigits = 1;
    });
    double rounded = round(gainDB * 10) / 10;
    NSString *sign = rounded > 0 ? @"+" : (rounded < 0 ? @"-" : @"");
    return [NSString stringWithFormat:@"%@%@ dB", sign, [f stringFromNumber:@(fabs(rounded))]];
}

NSString *VibeEQFormatQ(double q, NSLocale *locale) {
    NSNumberFormatter *f = VibeEQFormatter(@"q", locale, ^(NSNumberFormatter *formatter) {
        formatter.numberStyle = NSNumberFormatterDecimalStyle;
        formatter.usesSignificantDigits = YES;
        formatter.minimumSignificantDigits = 2;
        formatter.maximumSignificantDigits = 2;
    });
    return [f stringFromNumber:@(q)];
}

NSString *VibeEQFormatFieldNumber(double value, NSUInteger minimumFractionDigits, NSUInteger maximumFractionDigits,
                                  NSLocale *locale) {
    NSString *kind = [NSString stringWithFormat:@"field-%lu-%lu", (unsigned long)minimumFractionDigits,
                                                (unsigned long)maximumFractionDigits];
    NSNumberFormatter *f = VibeEQFormatter(kind, locale, ^(NSNumberFormatter *formatter) {
        formatter.numberStyle = NSNumberFormatterDecimalStyle;
        formatter.usesGroupingSeparator = NO;
        formatter.minimumFractionDigits = minimumFractionDigits;
        formatter.maximumFractionDigits = maximumFractionDigits;
    });
    double scale = pow(10, (double)maximumFractionDigits);
    double rounded = round(value * scale) / scale;
    return [f stringFromNumber:@(rounded == 0 ? 0 : rounded)];
}

BOOL VibeEQParseNumber(NSString *text, NSLocale *locale, double *outValue) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    // The locale's minus and decimal separator, read as plain ones, with no
    // grouping, so "1,000" in English and "1.000" in German are a thousand.
    NSString *decimal = [locale objectForKey:NSLocaleDecimalSeparator] ?: @".";
    NSString *grouping = [locale objectForKey:NSLocaleGroupingSeparator] ?: @",";
    NSMutableString *plain = [NSMutableString string];
    NSUInteger index = 0;
    if ([trimmed hasPrefix:@"+"]) {
        index = 1;
    } else if ([trimmed hasPrefix:@"-"] || [trimmed hasPrefix:@"−"]) {
        [plain appendString:@"-"];
        index = 1;
    }
    BOOL sawDigit = NO;
    BOOL sawDecimal = NO;
    for (; index < trimmed.length; index++) {
        unichar c = [trimmed characterAtIndex:index];
        NSString *s = [NSString stringWithCharacters:&c length:1];
        if (c >= '0' && c <= '9') {
            [plain appendString:s];
            sawDigit = YES;
        } else if (!sawDecimal && ([s isEqualToString:decimal] || (c == '.' && ![grouping isEqualToString:@"."]))) {
            [plain appendString:@"."];
            sawDecimal = YES;
        } else if ([s isEqualToString:grouping] || c == ' ' || c == 0x00A0 || c == 0x202F) {
            continue;
        } else {
            break;
        }
    }
    if (!sawDigit) {
        return NO;
    }
    double value = plain.doubleValue;
    NSString *rest = [[trimmed substringFromIndex:index] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if ([rest hasPrefix:@"k"] || [rest hasPrefix:@"K"]) {
        value *= 1000;
    }
    if (outValue) {
        *outValue = value;
    }
    return YES;
}
