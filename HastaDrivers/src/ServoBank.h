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
    // pulseMinUs/pulseMaxUs: pulse width mapped to 0deg/180deg. Defaults
    //       are a starting guess, not a measured value -- see
    //       setPulseRangeUs() below; ServoCalibration exists specifically
    //       to nail these down empirically per servo.
    ServoBank(const uint8_t* pins, uint8_t numServos, uint32_t pwmFreqHz = 600,
              uint16_t pulseMinUs = 100, uint16_t pulseMaxUs = 3000);

    // Sets the global PWM frequency/resolution and centers every channel
    // at 90 degrees. Call once from setup().
    void begin();

    // Commands one channel to an angle in degrees, clamped to [0, 180].
    void writeDeg(uint8_t channel, float deg);

    // Commands every channel to the same angle.
    void writeAllDeg(float deg);

    uint8_t numServos() const { return _numServos; }
    uint32_t pwmFreqHz() const { return _pwmFreqHz; }
    uint16_t pulseMinUs() const { return _pulseMinUs; }
    uint16_t pulseMaxUs() const { return _pulseMaxUs; }

    // Changes the shared PWM carrier at runtime. analogWriteFreq() is a
    // GLOBAL RP2040 setting (see the class note above), so this retunes
    // every channel in this bank at once -- fine for this project (one
    // servo per bank), and lets a caller re-tune without a reflash.
    // Doesn't itself re-issue any channel's last commanded angle; the
    // caller should call writeDeg() again afterwards if it wants the
    // servo to actually hold position through the change (a mid-flight
    // carrier change briefly glitches whatever's currently outputting,
    // same as any other analogWriteFreq() call).
    void setPwmFreqHz(uint32_t hz);

    // Changes the commanded-degrees -> pulse-width-us mapping used by
    // writeDeg() at runtime. Doesn't itself move the servo -- the next
    // writeDeg() call picks up the new range.
    void setPulseRangeUs(uint16_t minUs, uint16_t maxUs);

private:
    const uint8_t* _pins;
    uint8_t _numServos;
    uint32_t _pwmFreqHz;
    uint16_t _pulseMinUs;
    uint16_t _pulseMaxUs;

    static const uint32_t PWM_RANGE = 65535; // 16-bit duty resolution
};