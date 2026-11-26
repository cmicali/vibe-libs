//
//  VibeEQEditorFormat.h
//  vibe-libs
//
//  How the editor writes and reads its numbers, in a locale's digits. The
//  units are the SI symbols, which no locale changes.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// "1,000 Hz"
NSString *VibeEQFormatFrequency(double frequency, NSLocale *locale);
// "31", "500", "1k", "2.5k", "16k": the graphic face's and the axis's labels.
NSString *VibeEQFormatShortFrequency(double frequency, NSLocale *locale);
// "+3.0 dB", "0.0 dB", "-4.5 dB": a plain sign, so every locale reads it.
NSString *VibeEQFormatGain(double gainDB, NSLocale *locale);
// "1.4", "0.71", "10": two significant figures.
NSString *VibeEQFormatQ(double q, NSLocale *locale);
// A plain number for a field, with no grouping: "1000", "-3.0", "0.71".
NSString *VibeEQFormatFieldNumber(double value, NSUInteger minimumFractionDigits, NSUInteger maximumFractionDigits,
                                  NSLocale *locale);
// A number typed in a field, in the locale's digits or plain ones. A "k"
// after the number multiplies it by 1,000, and a unit after it is ignored.
// NO when it holds no number.
BOOL VibeEQParseNumber(NSString *text, NSLocale *locale, double *outValue);

NS_ASSUME_NONNULL_END
