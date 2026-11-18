//
//  MusicalKeyColor.h
//  vibe-libs
//
//  A key's color around the Camelot wheel: one hue per wheel number, with 1
//  green as on the printed wheel. So keys that mix harmonically sit in
//  neighboring hues, and a relative major and minor share one.
//

#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import "MusicalKey.h"

NS_ASSUME_NONNULL_BEGIN

// The color resolves per appearance: less saturated on dark chrome, and
// darker on light, since one fixed color cannot read on both. Never full
// brightness, which reads as garish beside dimmed text. nil for a key that is
// not valid, VibeMusicalKeyNone among them. Each number's color is made once,
// so two keys of one number answer the same object.
#if TARGET_OS_OSX
@class NSColor;
FOUNDATION_EXPORT NSColor *_Nullable VibeMusicalKeyCamelotColor(VibeMusicalKey key);
#else
@class UIColor;
FOUNDATION_EXPORT UIColor *_Nullable VibeMusicalKeyCamelotColor(VibeMusicalKey key);
#endif

NS_ASSUME_NONNULL_END
