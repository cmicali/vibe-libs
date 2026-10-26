# core/Graphics

Images, colors, and type for an app on either platform. It depends on nothing. It holds the platform aliases, the bounded image decode, the hex and blend colors, the dominant color, the OKLCH clamp, the dark-mode helpers, the blur, and the typography table. It came from Vibe.

## Shared

`PlatformTypes.h` defines `VibeImage` and `VibeColor`. They are `NSImage` and `NSColor` on macOS, and `UIImage` and `UIColor` on iOS. A model header can then carry an image without importing AppKit or UIKit. **Do not add aliases for their own sake.**

`PlatformImage.h` and `PlatformColor.h` hold free functions over a foreign class. The class differs per platform, so there is no single class to hang a category on. Everything else here is a category, except `Fonts`, which is a class of its own.

- `VibeDecodedImageWithData` is the bounded ImageIO decode. It never materializes the full-size bitmap. It takes 10 to 100 ms, so keep it off the main thread.
- `VibeDominantColorOfImage` is a weighted hue histogram over a fixed 32×32 downsample, so its cost does not depend on the image's size. **It works in a CoreGraphics bitmap context of its own**, not in either platform's bitmap type. `NSBitmapImageRep` and `UIImage`'s backing store share no layout, so one implementation serves both. `NSImage (Util)`'s `dominantColor` and `UIImage (VibeDominantColor)` forward to it.
- `PlatformColor.h` carries the `#RRGGBB[AA]` form of a stored color and the linear blend. An opaque color stays six digits. It has `extern "C"` guards, because C++ files include it.
- The three art sizes in `PlatformImage.h` are Vibe's: the list-row thumbnail, the display cap, and the archived display rendition.

## Mac/

- **`NSView+DarkMode`** holds `NSAppearance (DarkMode)`, the Aqua and DarkAqua `bestMatch` fold. `NSView`'s `isDark` is written in terms of it. A caller holding an appearance, not a view, asks the appearance. `iOS/UIView+DarkMode` is its mirror, so shared call sites read the same.
- **`NSColor+OKLCH`** clamps a color's lightness and chroma in OKLCH, because HSB brightness is blind to hue. Out of gamut, chroma gives way, never hue or lightness.
- **`NSImage+Util`**: `symbolNamed:pointSize:weight:palette:accessibilityDescription:` is the one way to build an SF Symbol with palette colors. The palette is applied over the sized configuration, since a symbol image holds only one. `availableSymbolName:fallback:` answers the factory symbol for a name this macOS lacks. `imageWithSize:drawnBy:` draws into a fresh sRGB bitmap. It also resizes, crops to a square, and forwards `dominantColor`.
- **`Fonts`** is the typography table. Text is Helvetica Neue, and `fontForNumbers:` has monospaced digits, so changing values do not jitter. Its slots are a face-and-size table keyed by an integer the app chooses. `Fonts` reads no setting. The app pushes each slot before its first read. An empty or uninstalled face falls back to the built-in font, so a slot never returns nil. A named numeric face gains monospaced digits. Vibe's five slots and its theme push stay in Vibe.

## iOS/

- **`UIView+DarkMode`** is the mirror of `NSView+DarkMode`.
- **`UIImage+Blur`**'s `vibeBlurredBackdrop` bakes a blurred, darkened copy for a static backdrop. A `UIVisualEffectView` re-blurs on every frame that anything behind it moves. The blur runs at a few dozen pixels, so its cost does not depend on the image's size. It is memoized on the image. Main thread only.
- **`UIImage+DominantColor`**'s `vibeDominantColor` memoizes the dominant color on the image, nil included. A pager that reconfigures a page on reuse then never rasterizes during a swipe.

## Tests

`Tests/core/Graphics/Mac/` holds the hex color tests and the image tests: the crop, the resize, the lower band's darkness, and the dominant color. They run on macOS. The iOS target builds the shared files and the iOS half. Vibe's tests of its artwork, themes, and waveform colors exercise the rest through Vibe's own classes, so they stay in Vibe. The minimal consumer round-trips a color with alpha through its hex form.
