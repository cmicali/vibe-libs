//
//  VibeEQEditorMath.h
//  vibe-libs
//
//  The EQ editor's geometry: the log frequency axis, the dB axis, the
//  graphic sliders' steps, the node hit test, and the Q gestures. Pure C over
//  CoreGraphics, header-only, and tested.
//

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <math.h>

NS_ASSUME_NONNULL_BEGIN

static const double kVibeEQMinFrequency = 20;
static const double kVibeEQMaxFrequency = 20000;
static const double kVibeEQMinQ = 0.1;
static const double kVibeEQMaxQ = 10;
static const double kVibeEQMaxGainDB = 24;
// The graphic face's sliders and the dB axis until a band needs more.
static const double kVibeEQNarrowRangeDB = 12;
static const double kVibeEQGraphicStepDB = 0.5;
// The parametric face's gain steps, by drag and by key.
static const double kVibeEQParametricStepDB = 0.1;

static inline double VibeEQClamp(double value, double low, double high) {
    if (isnan(value)) {
        return low;
    }
    return value < low ? low : (value > high ? high : value);
}

// x for a frequency on a log axis from 20 Hz at minX to 20 kHz at minX + width.
static inline CGFloat VibeEQXForFrequency(double frequency, CGFloat minX, CGFloat width) {
    double f = VibeEQClamp(frequency, kVibeEQMinFrequency, kVibeEQMaxFrequency);
    return minX + width * (CGFloat)(log(f / kVibeEQMinFrequency) / log(kVibeEQMaxFrequency / kVibeEQMinFrequency));
}

static inline double VibeEQFrequencyForX(CGFloat x, CGFloat minX, CGFloat width) {
    if (width <= 0) {
        return kVibeEQMinFrequency;
    }
    double t = VibeEQClamp((x - minX) / width, 0, 1);
    return kVibeEQMinFrequency * pow(kVibeEQMaxFrequency / kVibeEQMinFrequency, t);
}

// y for a gain on a linear axis from -range at minY to +range at minY + height.
static inline CGFloat VibeEQYForGain(double gainDB, CGFloat minY, CGFloat height, double rangeDB) {
    double t = (VibeEQClamp(gainDB, -rangeDB, rangeDB) + rangeDB) / (2 * rangeDB);
    return minY + height * (CGFloat)t;
}

// Past the axis's ends it goes on, to ±24, so a drag past the top of a ±12
// axis can widen it.
static inline double VibeEQGainForY(CGFloat y, CGFloat minY, CGFloat height, double rangeDB) {
    if (height <= 0) {
        return 0;
    }
    double t = (y - minY) / height;
    return VibeEQClamp(t * 2 * rangeDB - rangeDB, -kVibeEQMaxGainDB, kVibeEQMaxGainDB);
}

// The dB axis: ±12, widening to ±24 once the largest boost or cut passes 12.
static inline double VibeEQRangeForPeak(double largestMagnitudeDB) {
    return fabs(largestMagnitudeDB) > kVibeEQNarrowRangeDB + 1e-9 ? kVibeEQMaxGainDB : kVibeEQNarrowRangeDB;
}

// A gain rounded to the nearest step, and held to ±limit. -0 reads as 0.
static inline double VibeEQSnapGain(double gainDB, double step, double limitDB) {
    double snapped = round(VibeEQClamp(gainDB, -limitDB, limitDB) / step) * step;
    return snapped == 0 ? 0 : snapped;
}

// A dragged frequency, rounded to three significant figures so a field
// shows a round number.
static inline double VibeEQRoundFrequency(double frequency) {
    double f = VibeEQClamp(frequency, kVibeEQMinFrequency, kVibeEQMaxFrequency);
    double scale = pow(10, floor(log10(f)) - 2);
    return VibeEQClamp(round(f / scale) * scale, kVibeEQMinFrequency, kVibeEQMaxFrequency);
}

// Q, two significant figures, held to 0.1 to 10.
static inline double VibeEQRoundQ(double q) {
    double v = VibeEQClamp(q, kVibeEQMinQ, kVibeEQMaxQ);
    double scale = pow(10, floor(log10(v)) - 1);
    return VibeEQClamp(round(v / scale) * scale, kVibeEQMinQ, kVibeEQMaxQ);
}

// Option-drag: up narrows the band, doubling Q every 60 points.
static inline double VibeEQQForVerticalDrag(double startQ, CGFloat deltaY) {
    return VibeEQClamp(startQ * pow(2, deltaY / 60.0), kVibeEQMinQ, kVibeEQMaxQ);
}

// A scroll: up narrows the band, doubling Q every 40 points of travel.
static inline double VibeEQQForScroll(double q, CGFloat deltaY) {
    return VibeEQClamp(q * pow(2, deltaY / 40.0), kVibeEQMinQ, kVibeEQMaxQ);
}

// A frequency moved by a fraction of an octave, as an arrow key does.
static inline double VibeEQFrequencyByOctaves(double frequency, double octaves) {
    return VibeEQClamp(frequency * pow(2, octaves), kVibeEQMinFrequency, kVibeEQMaxFrequency);
}

// The node under a point: the nearest within radius, the later one on a
// tie, since it is drawn on top. NSNotFound when none is.
static inline NSUInteger VibeEQNodeIndexAtPoint(const CGPoint *nodes, NSUInteger count, CGPoint point,
                                                CGFloat radius) {
    NSUInteger best = NSNotFound;
    CGFloat bestDistance = radius * radius;
    for (NSUInteger i = 0; i < count; i++) {
        CGFloat dx = nodes[i].x - point.x;
        CGFloat dy = nodes[i].y - point.y;
        CGFloat distance = dx * dx + dy * dy;
        if (distance <= bestDistance) {
            bestDistance = distance;
            best = i;
        }
    }
    return best;
}

// The graphic slider whose column holds x: ten equal columns across width.
// NSNotFound outside them.
static inline NSUInteger VibeEQColumnAtX(CGFloat x, CGFloat minX, CGFloat width, NSUInteger columns) {
    if (columns == 0 || width <= 0 || x < minX || x >= minX + width) {
        return NSNotFound;
    }
    return MIN((NSUInteger)((x - minX) / (width / (CGFloat)columns)), columns - 1);
}

static inline CGFloat VibeEQColumnCenterX(NSUInteger column, CGFloat minX, CGFloat width, NSUInteger columns) {
    return minX + (width / (CGFloat)columns) * ((CGFloat)column + 0.5);
}

// The band selected after one is removed: the one that took its place, or
// the new last one. NSNotFound when none is left.
static inline NSUInteger VibeEQSelectionAfterRemoving(NSUInteger removed, NSUInteger remaining) {
    return remaining == 0 ? NSNotFound : MIN(removed, remaining - 1);
}

// Where a new band goes: 1 kHz on an empty EQ, otherwise the middle of the
// widest gap between the bands and the axis's ends, on the log axis, so it
// never lands on another. The first of equal gaps wins.
static inline double VibeEQFrequencyForNewBand(const double *_Nullable frequencies, NSUInteger count) {
    if (count == 0) {
        return 1000;
    }
    double edges[66];
    count = MIN(count, (NSUInteger)64);
    edges[0] = kVibeEQMinFrequency;
    edges[1] = kVibeEQMaxFrequency;
    for (NSUInteger i = 0; i < count; i++) {
        edges[i + 2] = VibeEQClamp(frequencies[i], kVibeEQMinFrequency, kVibeEQMaxFrequency);
    }
    // Insertion sort: an EQ has at most 20 bands.
    for (NSUInteger i = 1; i < count + 2; i++) {
        for (NSUInteger j = i; j > 0 && edges[j - 1] > edges[j]; j--) {
            double swap = edges[j];
            edges[j] = edges[j - 1];
            edges[j - 1] = swap;
        }
    }
    double best = 1000, widest = -1;
    for (NSUInteger i = 0; i + 1 < count + 2; i++) {
        double gap = log(edges[i + 1] / edges[i]);
        if (gap > widest + 1e-9) {
            widest = gap;
            best = sqrt(edges[i] * edges[i + 1]);
        }
    }
    return best;
}

NS_ASSUME_NONNULL_END
