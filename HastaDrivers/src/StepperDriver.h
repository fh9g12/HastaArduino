#pragma once
#include <Arduino.h>

// Minimal STEP/DIR stepper driver -- drives an A4988 (or any STEP/DIR
// compatible driver: DRV8825, TMC2208 in legacy mode, etc). Microstepping
// (MS1/MS2/MS3) and RESET/SLEEP are assumed hardwired/jumpered on the
// driver board itself (see wiring/encoder-calibration-rig.yml) -- this
// class touches STEP/DIR always, and optionally ENABLE (see
// setEnablePin() below), matching the rest of this project's "keep the
// MCU side minimal" style.
//
// ENABLE is software-controlled, not hardwired, because of a real bench
// finding on this rig: with ENABLE permanently jumpered low (driver
// always enabled), the stepper wouldn't turn even though STEP/DIR pulses
// were confirmed correct on a scope/multimeter; holding ENABLE high
// (disabled) through setup() and WiFi connect, then enabling only once
// everything else is up, reliably fixed it. Root cause not fully
// confirmed (suspected: undefined STEP/DIR pin state during the window
// between power-on and StepperDriver::begin()'s pinMode() calls, while
// an already-enabled driver could latch onto that noise), but the fix
// is reproducible -- see EncoderCalibration.ino's setup() for the
// disable-early/enable-late sequencing.
//
// Non-blocking, timer-polled: call update() as often as possible from
// loop() (or a tight capture loop, same pattern as ServoCalibration's
// runCapture()) -- it toggles STEP whenever enough time has passed for
// the currently-set speed, without ever calling delay(). No PIO/DMA
// step generation -- deliberately simple, matching this project's
// established style; the encoder is the ground truth for this rig's
// calibration work, not the stepper's own step timing precision, so
// software-loop jitter at the step level isn't a concern here.
class StepperDriver {
public:
    // stepPin/dirPin: driven directly; everything else on the driver
    // board (MS1-3, ENABLE, RESET/SLEEP) is assumed hardwired -- see the
    // wiring diagram.
    // degPerStep: the motor's full-step angle (1.8deg for the
    // SY42STH47-1684B) divided by the driver's microstep setting -- e.g.
    // 1.8/8 = 0.225 for 1/8 microstepping. Only used to convert
    // steps/sec speed commands and cumulative step count into degrees;
    // doesn't affect the actual pulses generated.
    StepperDriver(uint8_t stepPin, uint8_t dirPin, float degPerStep)
        : _stepPin(stepPin), _dirPin(dirPin), _degPerStep(degPerStep) {
    }

    void begin() {
        pinMode(_stepPin, OUTPUT);
        pinMode(_dirPin, OUTPUT);
        digitalWrite(_stepPin, LOW);
        digitalWrite(_dirPin, LOW);
    }

    // Constant-speed rotation in degrees/second -- sign gives direction.
    // 0 stops (update() becomes a no-op until set again).
    void setSpeedDegPerS(float speedDegPerS) {
        _speedDegPerS = speedDegPerS;
        float stepsPerS = fabsf(speedDegPerS) / _degPerStep;
        _stepIntervalUs = (stepsPerS > 0.0f) ? (uint32_t)(1000000.0f / stepsPerS) : 0;
        // LOW-for-positive (not HIGH) -- chosen empirically so that a
        // positive commanded speed matches the encoder's own direction
        // convention (the encoder's sign is fixed by its physical
        // mounting/SPI reading, not adjustable in software, so this side
        // is the one that had to flip).
        digitalWrite(_dirPin, speedDegPerS >= 0.0f ? LOW : HIGH);
    }

    float speedDegPerS() const { return _speedDegPerS; }

    // Call as often as possible (every loop() iteration, or inside a
    // capture loop) -- emits one STEP pulse whenever the interval for the
    // current speed has elapsed. No-op if speed is 0.
    void update() {
        if (_stepIntervalUs == 0) return;
        uint32_t now = micros();
        if (now - _lastStepUs >= _stepIntervalUs) {
            _lastStepUs = now;
            digitalWrite(_stepPin, HIGH);
            delayMicroseconds(2); // A4988 minimum STEP pulse width is ~1us
            digitalWrite(_stepPin, LOW);
            _stepCount += (_speedDegPerS >= 0.0f) ? 1 : -1;
        }
    }

    void stop() { setSpeedDegPerS(0.0f); }

    // Position-tracking mode (as opposed to setSpeedDegPerS()'s constant-
    // velocity mode) -- steps toward desiredDeg, one step at a time,
    // paced to at most maxSpeedDegPerS. Call every loop iteration (or
    // every capture-loop iteration) while following a trajectory (sine,
    // chirp) -- unlike a servo, a STEP/DIR stepper can't jump straight to
    // a commanded position, so this is what actually generates the
    // direction reversals a position waveform needs. No-op once within
    // one step of desiredDeg (a stepper's fundamental quantisation --
    // can't do better than that). maxSpeedDegPerS is a real, enforced
    // cap (not just a hint): pass a generous-but-finite value (e.g. a
    // multiple of the trajectory's own peak velocity) rather than an
    // effectively-unbounded one, so a large sudden position error (mid-
    // test hiccup, bad parameters) can't burst-step far faster than the
    // motor can physically follow in one go.
    void trackTo(float desiredDeg, float maxSpeedDegPerS) {
        float error = desiredDeg - cumulativeDeg();
        if (fabsf(error) < _degPerStep) return;

        uint32_t minIntervalUs = (uint32_t)(1000000.0f * _degPerStep / maxSpeedDegPerS);
        uint32_t now = micros();
        if (now - _lastStepUs < minIntervalUs) return;
        _lastStepUs = now;

        bool positive = error > 0.0f;
        // Same LOW-for-positive convention as setSpeedDegPerS() -- see there.
        digitalWrite(_dirPin, positive ? LOW : HIGH);
        digitalWrite(_stepPin, HIGH);
        delayMicroseconds(2);
        digitalWrite(_stepPin, LOW);
        _stepCount += positive ? 1 : -1;
    }

    float degPerStep() const { return _degPerStep; }

    // Optional -- only needed if ENABLE is wired to a GPIO instead of
    // jumpered on the driver board (see the class comment above for why
    // this rig needs it). Call once from setup(), before or after
    // begin(); drives ENABLE high (disabled) immediately, matching the
    // "start disabled" half of the validated sequencing.
    void setEnablePin(uint8_t pin) {
        _enablePin = pin;
        pinMode(_enablePin, OUTPUT);
        digitalWrite(_enablePin, HIGH);
    }

    // ENABLE is active-low on the A4988. No-op if setEnablePin() was
    // never called (driver stays hardwired-enabled in that case).
    void setEnabled(bool enabled) {
        if (_enablePin != PIN_NOT_SET) digitalWrite(_enablePin, enabled ? LOW : HIGH);
    }

    // Cumulative commanded angle since begin() (or resetPosition()) --
    // unbounded (doesn't wrap at 360), so it directly tracks total
    // rotation across many turns. Mod by 360 to compare against the
    // encoder's own single-turn wrapped reading.
    float cumulativeDeg() const { return _stepCount * _degPerStep; }
    void resetPosition() { _stepCount = 0; }

private:
    static const uint8_t PIN_NOT_SET = 255;

    uint8_t _stepPin, _dirPin;
    float _degPerStep;
    float _speedDegPerS = 0.0f;
    uint32_t _stepIntervalUs = 0;
    uint32_t _lastStepUs = 0;
    int32_t _stepCount = 0;
    uint8_t _enablePin = PIN_NOT_SET;
};
