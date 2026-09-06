#pragma once
#include <Arduino.h>

// Non-blocking multi-channel servo driver using native hardware PWM
// (analogWriteFreq/analogWrite) rather than the PIO-based Servo library,
// which is hardcoded to a fixed 50Hz refresh. Confirmed working up to
// 600Hz carrier on a Futaba S-AG300; 700Hz confirmed non-functional.
//
// analogWriteFreq() is a GLOBAL setting on RP2040/RP2350 -- there is no
// per-pin PWM frequency -- so every channel in one ServoBank necessarily
// shares the same carrier frequency. Use a second ServoBank instance if
// you genuinely need a different carrier for a different set of pins
// (uncommon, and begin() would need to not clobber the other bank's
// analogWriteFreq() call if you do).
class ServoBank {
public:
    // pins: array of GPIO pins, one per channel -- must stay valid for the
    //       lifetime of this object (a plain array/pointer is kept, not copied).
    // numServos: how many channels in `pins`.
    // pwmFreqHz: the shared PWM carrier frequency in Hz.
    ServoBank(const uint8_t* pins, uint8_t numServos, uint32_t pwmFreqHz = 600);

    // Sets the global PWM frequency/resolution and centers every channel
    // at 90 degrees. Call once from setup().
    void begin();

    // Commands one channel to an angle in degrees, clamped to [0, 180].
    void writeDeg(uint8_t channel, float deg);

    // Commands every channel to the same angle.
    void writeAllDeg(float deg);

    uint8_t numServos() const { return _numServos; }
    uint32_t pwmFreqHz() const { return _pwmFreqHz; }

private:
    const uint8_t* _pins;
    uint8_t _numServos;
    uint32_t _pwmFreqHz;

    // Standard assumption -- known to only produce ~90 degrees of real
    // travel on this servo rather than its rated 180. A wider 500-2500us
    // range was tried and gave confusing, inconsistent results (a
    // narrower and shifted responsive window rather than a wider one),
    // so parked back here until a proper encoder sweep-and-log
    // calibration is done to find the real pulse/angle relationship
    // rather than guessing at these two numbers further.
    static const int PULSE_MIN_US = 1000; // pulse width at 0 degrees
    static const int PULSE_MAX_US = 2000; // pulse width at 180 degrees
    static const uint32_t PWM_RANGE = 65535; // 16-bit duty resolution
};