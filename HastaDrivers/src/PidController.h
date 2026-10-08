#pragma once
#include <Arduino.h>

// Minimal live-tunable PID controller -- deg-in/deg-out, dt supplied by
// the caller each update() (so it doesn't care what rate it's actually
// called at, matching how HastaDAQ.ino runs this at its own configurable
// "slow" rate, independent of sensor sampling/streaming rates).
//
// Anti-windup: basic clamped-integration only (freeze the integral term
// while the output is saturated against outputLimitDeg) -- not a full
// back-calculation scheme. Fine for a slow trim-hold loop with a
// deliberately modest output authority; revisit if this ever needs to
// fight something faster/bigger than the setpoint trim excursions this
// was designed for.
class PidController {
public:
    void setGains(float kp, float ki, float kd) {
        _kp = kp; _ki = ki; _kd = kd;
    }
    float kp() const { return _kp; }
    float ki() const { return _ki; }
    float kd() const { return _kd; }

    void setTarget(float targetDeg) { _target = targetDeg; }
    float target() const { return _target; }

    // Symmetric +/- clamp on the output -- real safety limit on how much
    // authority this loop has over the commanded surface position, not
    // just a cosmetic default.
    void setOutputLimit(float limitDeg) { _outputLimit = fabsf(limitDeg); }
    float outputLimit() const { return _outputLimit; }

    // Clears integral/derivative history AND the internal dt timestamp
    // (see update(measurement) below) -- call when enabling the loop (or
    // changing target sharply) so neither a stale integral/derivative
    // NOR a bogus huge dt (from time elapsed while disabled) cause a
    // jump on the next update() call.
    void reset() {
        _integral = 0.0f;
        _hasLastError = false;
        _lastOutput = 0.0f;
        _hasLastUpdate = false;
    }

    // measurement: current process value (e.g. encoder angle, deg).
    // dtS: elapsed time since the last update() call, in seconds.
    float update(float measurement, float dtS) {
        if (dtS <= 0.0f) return _lastOutput;

        float error = _target - measurement;
        float derivative = _hasLastError ? (error - _lastError) / dtS : 0.0f;
        float unclamped = _kp * error + _ki * (_integral + error * dtS) + _kd * derivative;
        float output = constrain(unclamped, -_outputLimit, _outputLimit);

        // Only accumulate the integral when the output isn't currently
        // saturated -- prevents it winding up unboundedly while clamped.
        if (fabsf(output - unclamped) < 1e-6f) {
            _integral += error * dtS;
        }

        _lastError = error;
        _hasLastError = true;
        _lastOutput = output;
        return output;
    }

    // Self-timing convenience -- computes dtS from micros() internally
    // (tracking its own last-call timestamp), so the caller doesn't need
    // to separately manage a timestamp variable AND remember to keep it
    // in sync with reset() (a real bug this repo hit once already: a
    // stale timestamp from before the loop was disabled producing a
    // bogus huge dt on the first update() after re-enabling). Just call
    // this every loop iteration while the loop is enabled; reset() (see
    // above) makes the first call after enabling a safe no-op-ish return
    // instead of an unbounded dt.
    float update(float measurement) {
        uint32_t nowUs = micros();
        if (!_hasLastUpdate) {
            _lastUpdateUs = nowUs;
            _hasLastUpdate = true;
            return _lastOutput; // no elapsed time to integrate over yet
        }
        float dtS = (nowUs - _lastUpdateUs) / 1000000.0f;
        _lastUpdateUs = nowUs;
        return update(measurement, dtS);
    }

    float lastOutput() const { return _lastOutput; }
    float lastError() const { return _lastError; }

private:
    float _kp = 0.0f, _ki = 0.0f, _kd = 0.0f;
    float _target = 0.0f;
    float _outputLimit = 15.0f; // deg -- modest default authority
    float _integral = 0.0f;
    float _lastError = 0.0f;
    float _lastOutput = 0.0f;
    bool _hasLastError = false;
    uint32_t _lastUpdateUs = 0;
    bool _hasLastUpdate = false;
};
