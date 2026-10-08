#pragma once
#include <Arduino.h>

// "1-cosine" doublet position generator -- the standard flight-test
// control input shape (distinct from a plain sine): starts and ends at
// `center` with zero slope at both ends, rising smoothly to a single
// peak mid-period. Classic use: a clean, non-jarring single pulse to
// excite a mode without the persistent oscillation a sine/chirp gives.
//
// deg(t) = center + (amplitude/2) * (1 - cos(2*pi*t/periodS)), one full
// period only -- same "shape defines one period, caller wraps elapsed
// time via fmodf() for repeats" convention as LinearChirp.h/SweepWave.h,
// so a multi-cycle run is just periodS*cycles at the call site.
class OneMinusCosine {
public:
    OneMinusCosine(float periodS, float centerDeg, float amplitudeDeg)
        : _periodS(periodS), _center(centerDeg), _amplitude(amplitudeDeg) {
    }

    // t_s: elapsed time within one period, in seconds [0, periodS).
    float deg(float t_s) const {
        float phase = 2.0f * PI * (t_s / _periodS);
        return _center + (_amplitude / 2.0f) * (1.0f - cosf(phase));
    }

    float periodS() const { return _periodS; }

private:
    float _periodS;
    float _center;
    float _amplitude;
};
