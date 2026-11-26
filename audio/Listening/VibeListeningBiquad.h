//
//  VibeListeningBiquad.h
//  vibe-libs
//
//  The RBJ cookbook's biquads, which both the response math and the stage use,
//  so the curve an editor draws is the one that plays.
//

#import "VibeListeningSettings.h"
#include <math.h>

typedef struct {
    double b0, b1, b2, a1, a2;  // normalized, so a0 is 1
} VibeListeningBiquad;

// A band's center is held under 0.48 of the rate, so a high band at a low rate
// stays a filter.
static inline VibeListeningBiquad VibeListeningBiquadMake(VibeEQBandType type, double frequency, double gainDB,
                                                          double q, double sampleRate) {
    double f0 = fmin(frequency, 0.48 * sampleRate);
    double w0 = 2.0 * M_PI * f0 / sampleRate;
    double cw = cos(w0);
    double alpha = sin(w0) / (2.0 * q);
    double A = pow(10.0, gainDB / 40.0);
    double sqrtA2alpha = 2.0 * sqrt(A) * alpha;
    double b0, b1, b2, a0, a1, a2;
    switch (type) {
        case VibeEQBandTypeLowShelf:
            b0 = A * ((A + 1) - (A - 1) * cw + sqrtA2alpha);
            b1 = 2 * A * ((A - 1) - (A + 1) * cw);
            b2 = A * ((A + 1) - (A - 1) * cw - sqrtA2alpha);
            a0 = (A + 1) + (A - 1) * cw + sqrtA2alpha;
            a1 = -2 * ((A - 1) + (A + 1) * cw);
            a2 = (A + 1) + (A - 1) * cw - sqrtA2alpha;
            break;
        case VibeEQBandTypeHighShelf:
            b0 = A * ((A + 1) + (A - 1) * cw + sqrtA2alpha);
            b1 = -2 * A * ((A - 1) + (A + 1) * cw);
            b2 = A * ((A + 1) + (A - 1) * cw - sqrtA2alpha);
            a0 = (A + 1) - (A - 1) * cw + sqrtA2alpha;
            a1 = 2 * ((A - 1) - (A + 1) * cw);
            a2 = (A + 1) - (A - 1) * cw - sqrtA2alpha;
            break;
        case VibeEQBandTypeLowPass:
            b0 = (1 - cw) / 2;
            b1 = 1 - cw;
            b2 = (1 - cw) / 2;
            a0 = 1 + alpha;
            a1 = -2 * cw;
            a2 = 1 - alpha;
            break;
        case VibeEQBandTypeHighPass:
            b0 = (1 + cw) / 2;
            b1 = -(1 + cw);
            b2 = (1 + cw) / 2;
            a0 = 1 + alpha;
            a1 = -2 * cw;
            a2 = 1 - alpha;
            break;
        case VibeEQBandTypePeak:
        default:
            b0 = 1 + alpha * A;
            b1 = -2 * cw;
            b2 = 1 - alpha * A;
            a0 = 1 + alpha / A;
            a1 = -2 * cw;
            a2 = 1 - alpha / A;
            break;
    }
    return (VibeListeningBiquad){b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0};
}

// The filter's magnitude, in dB, at `frequency`.
static inline double VibeListeningBiquadResponseDB(VibeListeningBiquad f, double frequency, double sampleRate) {
    double w = 2.0 * M_PI * frequency / sampleRate;
    double c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w);
    double nr = f.b0 + f.b1 * c1 + f.b2 * c2, ni = -(f.b1 * s1 + f.b2 * s2);
    double dr = 1.0 + f.a1 * c1 + f.a2 * c2, di = -(f.a1 * s1 + f.a2 * s2);
    double power = (nr * nr + ni * ni) / (dr * dr + di * di);
    return 10.0 * log10(fmax(power, 1e-30));
}
