#pragma once
#include <Arduino.h>
#include <math.h>

// Triangle-wave position generator for a full-range calibration sweep:
// ramps linearly from startDeg to endDeg over halfPeriodS, then back down
// over another halfPeriodS, repeating. Two linear ramps per period gives
// both sweep directions (useful for spotting backlash/hysteresis between
// commanded pulse width and actual encoder angle) in one run, rather than
// needing a separate one-shot state machine. Header-only -- small enough
// not to need its own .cpp, same as LinearChirp.
class SweepWave {
public:
    SweepWave(float startDeg, float endDeg, float halfPeriodS)
        : _start(startDeg), _end(endDeg), _halfPeriodS(halfPeriodS) {
    }

    // t_s: elapsed time within the repeating period, in seconds [0, periodS).
    float deg(float t_s) const {
        float phase = fmodf(t_s, 2.0f * _halfPeriodS);
        if (phase <= _halfPeriodS) {
            return _start + (_end - _start) * (phase / _halfPeriodS);
        }
        return _end + (_start - _end) * ((phase - _halfPeriodS) / _halfPeriodS);
    }

    float periodS() const { return 2.0f * _halfPeriodS; }

private:
    float _start;
    float _end;
    float _halfPeriodS;
};
