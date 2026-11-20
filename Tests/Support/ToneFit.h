//
//  ToneFit.h
//  vibe-libs
//
//  VibeFitTones is the one tone fit, with VibeFitTone and VibeDB beside it.
//  The player's quality measurements and the DSD decode's tests share it. It
//  imports Foundation alone, so any test bundle can take it.
//

#import <Foundation/Foundation.h>

#include <math.h>
#include <stdlib.h>

// The least-squares fit of c + Σ a_k·cos(ω_k t) + b_k·sin(ω_k t) over
// `count` samples, t = (index + n) / rate − origin: the tones at their exact
// frequencies, jointly, and the power of everything else. `a` and `b` receive
// each tone's cos and sin terms when given.
static inline double VibeFitTones(const double *x, NSUInteger count, const double *frequencies, int tones, double rate,
                                   double index, double origin, double *a, double *b) {
    int size = 2 * tones + 1;
    double *m = (double *)calloc((size_t)size * size, sizeof(double)), *v = (double *)calloc((size_t)size, sizeof(double));
    double *basis = (double *)malloc((size_t)size * sizeof(double));
    double *coefficients = (double *)calloc((size_t)size, sizeof(double));
    for (NSUInteger n = 0; n < count; n++) {
        double t = (index + n) / rate - origin;
        basis[0] = 1;
        for (int k = 0; k < tones; k++) {
            double phase = 2 * M_PI * frequencies[k] * t;
            basis[1 + 2 * k] = cos(phase);
            basis[2 + 2 * k] = sin(phase);
        }
        for (int i = 0; i < size; i++) {
            v[i] += basis[i] * x[n];
            for (int j = i; j < size; j++) {
                m[i * size + j] += basis[i] * basis[j];
            }
        }
    }
    for (int i = 0; i < size; i++) {
        for (int j = 0; j < i; j++) {
            m[i * size + j] = m[j * size + i];
        }
    }
    // Gaussian elimination with partial pivoting on the normal equations.
    for (int col = 0; col < size; col++) {
        int pivot = col;
        for (int row = col + 1; row < size; row++) {
            if (fabs(m[row * size + col]) > fabs(m[pivot * size + col])) pivot = row;
        }
        if (pivot != col) {
            for (int k = 0; k < size; k++) {
                double swap = m[col * size + k]; m[col * size + k] = m[pivot * size + k]; m[pivot * size + k] = swap;
            }
            double swap = v[col]; v[col] = v[pivot]; v[pivot] = swap;
        }
        for (int row = col + 1; row < size; row++) {
            double factor = m[row * size + col] / m[col * size + col];
            for (int k = col; k < size; k++) {
                m[row * size + k] -= factor * m[col * size + k];
            }
            v[row] -= factor * v[col];
        }
    }
    for (int row = size - 1; row >= 0; row--) {
        double sum = v[row];
        for (int k = row + 1; k < size; k++) {
            sum -= m[row * size + k] * coefficients[k];
        }
        coefficients[row] = sum / m[row * size + row];
    }
    double residual = 0;
    for (NSUInteger n = 0; n < count; n++) {
        double t = (index + n) / rate - origin, e = x[n] - coefficients[0];
        for (int k = 0; k < tones; k++) {
            double phase = 2 * M_PI * frequencies[k] * t;
            e -= coefficients[1 + 2 * k] * cos(phase) + coefficients[2 + 2 * k] * sin(phase);
        }
        residual += e * e;
    }
    for (int k = 0; k < tones; k++) {
        if (a) a[k] = coefficients[1 + 2 * k];
        if (b) b[k] = coefficients[2 + 2 * k];
    }
    free(m);
    free(v);
    free(basis);
    free(coefficients);
    return residual / count;
}

// One tone of VibeFitTones, with its amplitude.
typedef struct {
    double amplitude;   // hypot(a, b)
    double a, b;        // cos and sin terms
    double residualPower;
} VibeToneFit;

static inline VibeToneFit VibeFitTone(const double *x, NSUInteger count, double frequency, double rate, double index,
                                      double origin) {
    VibeToneFit fit;
    fit.residualPower = VibeFitTones(x, count, &frequency, 1, rate, index, origin, &fit.a, &fit.b);
    fit.amplitude = hypot(fit.a, fit.b);
    return fit;
}

// A power ratio in dB; -400 for none.
static inline double VibeDB(double ratio) {
    return ratio > 0 ? 10 * log10(ratio) : -400;
}
