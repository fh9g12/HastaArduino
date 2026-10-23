#pragma once
#include <Arduino.h>

// Debounced "soft stop" input: a normally-closed loop at the end of a cable
// (SOFTSTOP+ to SOFTSTOP-, where SOFTSTOP- is board GND) read through a series
// resistor by a GPIO that the board pulls up to 3V3.
//
//   loop closed (switch/cable intact)  -> pin LOW  -> RUN
//   loop open   (pressed or cable cut) -> pin HIGH -> STOP   (fail-safe)
//
// The class only reports the state; what STOP means (here: halt and disarm
// the excitation, keep holding trim and control) is the sketch's decision.
//
// - It starts in STOP and only goes to RUN after the pin has read LOW for
//   releaseDebounceUs, so an open or unplugged loop at power-up never lets a
//   manoeuvre start.
// - STOP is reported after the pin has read HIGH for stopDebounceUs (short:
//   a stop should act quickly, but a noise glitch on a long cable should not
//   trip it).
// - setEnabled(false) is a bench mode for rigs without the stop loop fitted:
//   stopped() then always returns false, while level()/stopCount() keep
//   tracking the pin.
class SoftStop {
public:
    void begin(uint8_t pin, uint32_t stopDebounceUs = 2000, uint32_t releaseDebounceUs = 50000) {
        _pin = pin;
        _stopDebounceUs = stopDebounceUs;
        _releaseDebounceUs = releaseDebounceUs;
        pinMode(_pin, INPUT); // external 10k pull-up on the board; no internal pull
        _stopped = true;      // fail-safe until the loop is seen closed
        _candidateHigh = true;
        _candidateSinceUs = micros();
    }

    // Call every loop() iteration.
    void update() {
        const uint32_t now = micros();
        const bool high = digitalRead(_pin) == HIGH;
        _level = high;
        if (high != _candidateHigh) {
            _candidateHigh = high;
            _candidateSinceUs = now;
            return;
        }
        const uint32_t held = now - _candidateSinceUs;
        if (high && !_stopped && held >= _stopDebounceUs) {
            _stopped = true;
            _stopCount++;
            _stopEvent = true;
        } else if (!high && _stopped && held >= _releaseDebounceUs) {
            _stopped = false;
        }
    }

    // True while the stop is asserted (always false in bench mode).
    bool stopped() const { return _enabled && _stopped; }
    // Raw pin level: true = HIGH (loop open).
    bool level() const { return _level; }
    // Debounced state ignoring the enable flag (for status reporting).
    bool stoppedRaw() const { return _stopped; }

    // True exactly once per transition into STOP -- act on it (e.g. log, halt).
    bool consumeStopEvent() {
        if (!_stopEvent) return false;
        _stopEvent = false;
        return true;
    }
    uint32_t stopCount() const { return _stopCount; }

    void setEnabled(bool enabled) { _enabled = enabled; }
    bool enabled() const { return _enabled; }

private:
    uint8_t _pin = 0;
    uint32_t _stopDebounceUs = 2000, _releaseDebounceUs = 50000;
    bool _enabled = true;
    bool _stopped = true;
    bool _level = true;
    bool _candidateHigh = true;
    uint32_t _candidateSinceUs = 0;
    bool _stopEvent = false;
    uint32_t _stopCount = 0;
};
