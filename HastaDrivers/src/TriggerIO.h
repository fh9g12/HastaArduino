#pragma once
#include <Arduino.h>

// One external trigger-in pin (interrupt-driven, configurable edge) and
// one trigger-out pulse pin, bundled together since every rig that needs
// one tends to need both (synchronising a capture with other equipment,
// and pulsing out so this rig can be the sync master for others).
//
// Trigger-in uses a static ISR trampoline (attachInterrupt() needs a
// plain function pointer, not a member function) -- this means only ONE
// TriggerIO instance is supported per sketch. Fine for every rig so far
// (one trigger in/out pair each), but worth knowing if that ever changes.
class TriggerIO {
public:
    void begin(uint8_t inPin, uint8_t outPin) {
        _inPin = inPin;
        _outPin = outPin;
        _instance = this;

        pinMode(_inPin, INPUT_PULLDOWN);
        attachInterrupt(digitalPinToInterrupt(_inPin), isrTrampoline, (PinStatus)_inEdgeMode);

        pinMode(_outPin, OUTPUT);
        digitalWrite(_outPin, LOW);
    }

    // RISING or FALLING (Arduino's constants).
    void setInEdge(int edgeMode) {
        if (edgeMode == _inEdgeMode) return;
        _inEdgeMode = edgeMode;
        detachInterrupt(digitalPinToInterrupt(_inPin));
        attachInterrupt(digitalPinToInterrupt(_inPin), isrTrampoline, (PinStatus)_inEdgeMode);
    }
    int inEdge() const { return _inEdgeMode; }

    void setOutPulseMs(float ms) { _outPulseMs = ms; }
    float outPulseMs() const { return _outPulseMs; }

    // Returns true exactly once per detected edge -- call every loop
    // iteration and act on a true return (e.g. attempt to fire a capture).
    bool pollPending() {
        if (!_pending) return false;
        _pending = false;
        return true;
    }

    // Starts the output pulse -- call whenever a trigger event happens
    // (from any source), so external equipment can sync off it too.
    void pulseOut() {
        digitalWrite(_outPin, HIGH);
        _outActive = true;
        _outStartUs = micros();
    }

    // Call every loop iteration -- non-blocking pulse-width timing.
    void update() {
        if (_outActive && (micros() - _outStartUs) >= (uint32_t)(_outPulseMs * 1000.0f)) {
            digitalWrite(_outPin, LOW);
            _outActive = false;
        }
    }

private:
    static void isrTrampoline() {
        if (_instance) _instance->_pending = true;
    }

    static TriggerIO* _instance;

    uint8_t _inPin = 0, _outPin = 0;
    int _inEdgeMode = RISING;
    float _outPulseMs = 2.0f;
    volatile bool _pending = false;
    bool _outActive = false;
    uint32_t _outStartUs = 0;
};

// Safe as a plain (non-inline) static definition in a header ONLY because
// every sketch using this is a single .ino with no additional .cpp files
// (true of every rig in this repo, incl. HastaDAQ's split-into-headers
// layout) -- the whole sketch compiles as one translation unit, so this
// is defined exactly once. Would need `inline` (C++17) if that ever
// changes; not used here since the earlephilhower core's actual build
// flags for this aren't confirmed, and the plain version is simplest
// while it stays true.
TriggerIO* TriggerIO::_instance = nullptr;
