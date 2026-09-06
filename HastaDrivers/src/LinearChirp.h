#pragma once
#include <Arduino.h>

// Linear chirp position generator: instantaneous frequency sweeps linearly
// from f0Hz to f1Hz over periodS seconds, then the caller is expected to
// wrap t_s back to 0 and repeat. Header-only -- small enough not to need
// its own .cpp.
//
// Phase is the integral of 2*pi*f(t) dt, where f(t) = f0 + rate*t:
//   phase(t) = 2*pi*(f0*t + rate*t^2/2)
class LinearChirp {
public:
    LinearChirp(float f0Hz, float f1Hz, float periodS, float centerDeg, float amplitudeDeg)
        : _f0(f0Hz),
        _rate((f1Hz - f0Hz) / periodS),
        _periodS(periodS),
        _center(centerDeg),
        _amplitude(amplitudeDeg) {
    }

    // t_s: elapsed time within the repeating period, in seconds [0, periodS).
    // phaseOffsetDeg: per-channel phase offset if you want channels staggered
    // instead of all moving in unison (0 = unison).
    float deg(float t_s, float phaseOffsetDeg = 0.0f) const {
        float phase = 2.0f * PI * (_f0 * t_s + 0.5f * _rate * t_s * t_s);
        phase += radians(phaseOffsetDeg);
        return _center + _amplitude * sinf(phase);
    }

    // Instantaneous frequency at time t_s -- handy for logging/verification.
    float instFreqHz(float t_s) const { return _f0 + _rate * t_s; }

    float periodS() const { return _periodS; }

private:
    float _f0;
    float _rate;
    float _periodS;
    float _center;
    float _amplitude;
};