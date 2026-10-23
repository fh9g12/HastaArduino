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
//
// POLARITY. All edge/pulse arguments and getters are in terms of the
// EXTERNAL (cable-level) signal, not the GPIO. The optional inInverted /
// outInverted flags tell this class that the board inverts the pin on its
// way to the cable, and it does the translation:
//   - inInverted : an opto-isolated input pulls the GPIO LOW when the
//     cable signal is HIGH (HastaDAQ v2). A cable RISING edge is then a pin
//     FALLING edge, and setInEdge()/inEdge() still speak cable edges.
//   - outInverted: an open-collector NPN drives the cable (HastaDAQ v2):
//     GPIO HIGH = line pulled LOW. Idle cable level is LOW and a pulse is a
//     HIGH pulse, as before, so the idle GPIO level is HIGH and the pulse
//     is a GPIO LOW. (Until begin() runs the GPIO floats, the transistor is
//     off and the line is released, so a pulled-up line is briefly HIGH at
//     power-up -- call begin() as early as possible in setup().)
// Defaults (both false, pin pulled down internally) are the original
// HastaDAQ wiring, so older sketches are unaffected.
class TriggerIO {
public:
    // externalPullUp: the board already pulls the input pin up (v2: 10k to
    // 3V3 behind the opto), so use a plain input rather than the internal
    // pull-down (a pull-down would fight the external pull-up).
    void begin(uint8_t inPin, uint8_t outPin,
               bool inInverted = false, bool outInverted = false, bool externalPullUp = false) {
        _inPin = inPin;
        _outPin = outPin;
        _inInverted = inInverted;
        _outInverted = outInverted;
        _instance = this;

        // Output first: get the idle level onto the line as early as possible.
        pinMode(_outPin, OUTPUT);
        digitalWrite(_outPin, idleLevel());

        pinMode(_inPin, externalPullUp ? INPUT : INPUT_PULLDOWN);
        attachInterrupt(digitalPinToInterrupt(_inPin), isrTrampoline, (PinStatus)pinEdgeMode());
    }

    // RISING or FALLING (Arduino's constants), of the cable signal.
    void setInEdge(int edgeMode) {
        if (edgeMode == _inEdgeMode) return;
        _inEdgeMode = edgeMode;
        detachInterrupt(digitalPinToInterrupt(_inPin));
        attachInterrupt(digitalPinToInterrupt(_inPin), isrTrampoline, (PinStatus)pinEdgeMode());
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
        digitalWrite(_outPin, activeLevel());
        _outActive = true;
        _outStartUs = micros();
    }

    // Call every loop iteration -- non-blocking pulse-width timing.
    void update() {
        if (_outActive && (micros() - _outStartUs) >= (uint32_t)(_outPulseMs * 1000.0f)) {
            digitalWrite(_outPin, idleLevel());
            _outActive = false;
        }
    }

private:
    // GPIO level during a pulse / while idle (cable pulse is always "HIGH").
    PinStatus activeLevel() const { return _outInverted ? LOW : HIGH; }
    PinStatus idleLevel() const { return _outInverted ? HIGH : LOW; }

    // Interrupt edge to put on the pin for the requested cable edge.
    int pinEdgeMode() const {
        if (!_inInverted) return _inEdgeMode;
        return _inEdgeMode == RISING ? FALLING : RISING;
    }

    static void isrTrampoline() {
        if (_instance) _instance->_pending = true;
    }

    static TriggerIO* _instance;

    uint8_t _inPin = 0, _outPin = 0;
    bool _inInverted = false, _outInverted = false;
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
