#pragma once
#include <Arduino.h>
#include <SPI.h>

// Minimal driver for an RLS Orbis through-hole encoder (SPI variant) --
// position + status only. Written from the RLS BRD01 data sheet (issue 16),
// "SPI - Serial peripheral interface" section. Shares SPI1 with other
// devices: it never starts or remaps the bus (the owner of the bus does,
// see HastaDAQ v2's EncoderPorts.h) and applies its own SPISettings per
// transaction, so a mode-3 MT6835 can sit on the same bus.
//
// WIRE PROTOCOL (from the data sheet):
//   * NCS low latches the position; wait tS (>= 9 us, 14 us for the
//     multi-turn "14M" part) before the first clock.
//   * The first 8 clocks also carry a command byte on MOSI; a byte that
//     matches no command (0x00 here) returns only position + status + CRC.
//   * Reply, MSB first: [16-bit multi-turn counter, multi-turn parts only]
//     then 16 bits = 14-bit position left-aligned in b15:b2, b1 = error
//     (active LOW), b0 = warning (active LOW), then an 8-bit inverted CRC.
//   * NCS must stay high for tP >= 20 us between frames; fCL <= 4 MHz.
//   * MISO is high-Z while NCS is high, so the bus can be shared.
//
// NOT VERIFIED ON HARDWARE:
//   * SPI mode. The data sheet's timing diagram shows SCK idling low and
//     data shifting out on rising edges, which points to SPI_MODE1 (sample
//     on the falling edge). That is inferred, not stated -- if readings are
//     garbage, construct with SPI_MODE3 (or MODE0) and compare.
//   * The CRC is not checked (its definition is in RLS document CRCD01,
//     not read). A reading is rejected only if the error bit is low or the
//     whole word is 0xFFFF (what an absent device on a pulled-up/floating
//     MISO tends to return).
//   * The multi-turn counter is clocked out and ignored (its signedness is
//     not covered by the sections read); turns are tracked by unwrapping
//     the 14-bit position in software, like Mt6835Encoder.
//
// Zero/unwrap API deliberately mirrors Mt6835Encoder so the two can be
// used interchangeably by the caller.
class OrbisEncoder {
public:
    OrbisEncoder(uint8_t cs, uint32_t spiHz = 1000000, bool multiturn = false, uint8_t spiMode = SPI_MODE1)
        : _cs(cs), _multiturn(multiturn), _spiSettings(spiHz, MSBFIRST, spiMode) {
    }

    // Sets the chip-select high and primes the unwrap state. The SPI1 bus
    // must already be started.
    void begin() {
        pinMode(_cs, OUTPUT);
        digitalWrite(_cs, HIGH);
        _lastEndUs = micros();
        _primed = false;
        update();
    }

    // Change the part type at run time (before begin()/configure) -- a
    // multi-turn part has a different frame length and a longer tS.
    void setMultiturn(bool multiturn) { _multiturn = multiturn; }
    bool multiturn() const { return _multiturn; }

    // Reads one frame and refreshes the cached angle. Returns true if the
    // reading was accepted (valid() reports the last result).
    bool update() {
        // keep NCS high for tP (20 us) since the end of the previous frame
        uint32_t sinceEnd = micros() - _lastEndUs;
        if (sinceEnd < T_P_US + 5) delayMicroseconds(T_P_US + 5 - sinceEnd);

        uint8_t buf[5] = {0, 0, 0, 0, 0}; // MOSI stays 0x00: no command
        const uint8_t n = _multiturn ? 5 : 3;
        SPI1.beginTransaction(_spiSettings);
        digitalWrite(_cs, LOW);
        delayMicroseconds(_multiturn ? T_S_MULTI_US : T_S_SINGLE_US);
        SPI1.transfer(buf, n);
        digitalWrite(_cs, HIGH);
        SPI1.endTransaction();
        _lastEndUs = micros();

        const uint8_t off = _multiturn ? 2 : 0; // skip the multi-turn counter
        const uint16_t word = ((uint16_t)buf[off] << 8) | buf[off + 1];
        _lastWord = word;
        const bool errorBitLow = (word & 0x0002) == 0; // active low: low = position invalid
        if (errorBitLow || word == 0xFFFF) {
            _valid = false;
            _failCount++;
            return false;
        }
        _warning = (word & 0x0001) == 0;
        _valid = true;

        float rawDeg = (float)(word >> 2) / 16384.0f * 360.0f;
        if (!_primed) {
            _lastRawDeg = rawDeg;
            _continuousDeg = rawDeg;
            _primed = true;
            return true;
        }
        float delta = rawDeg - _lastRawDeg;
        if (delta > 180.0f) delta -= 360.0f;
        else if (delta < -180.0f) delta += 360.0f;
        _continuousDeg += delta;
        _lastRawDeg = rawDeg;
        return true;
    }

    // True if the most recent frame was accepted (error bit clear, not 0xFFFF).
    bool valid() const { return _valid; }
    // True if the encoder's warning bit was set on the last accepted frame
    // (valid position, but operating conditions near limits).
    bool warning() const { return _warning; }
    uint32_t failCount() const { return _failCount; }
    uint16_t lastWord() const { return _lastWord; } // raw 16-bit position+status word, for bench debugging

    // Continuous (unwrapped) angle in degrees relative to the last zero.
    float getDegrees() const { return _continuousDeg - _zeroOffsetDeg; }

    void zeroAtCurrentPosition() { _zeroOffsetDeg = _continuousDeg; }

    // Raw absolute angle [0,360) that currently reads as 0 deg (same
    // save/re-apply scheme as Mt6835Encoder::zeroOffsetRawDegrees()).
    float zeroOffsetRawDegrees() const {
        float zero = fmodf(_lastRawDeg - getDegrees(), 360.0f);
        if (zero < 0.0f) zero += 360.0f;
        return zero;
    }
    void setZeroOffsetRawDegrees(float zeroRawDeg) {
        float delta = fmodf(_lastRawDeg - zeroRawDeg, 360.0f);
        if (delta > 180.0f) delta -= 360.0f;
        else if (delta <= -180.0f) delta += 360.0f;
        _zeroOffsetDeg = _continuousDeg - delta;
    }

private:
    static const uint32_t T_S_SINGLE_US = 10; // data sheet min 9 us (14B resolution)
    static const uint32_t T_S_MULTI_US = 15;  // data sheet min 14 us (14M multi-turn)
    static const uint32_t T_P_US = 20;        // data sheet min NCS-high pause between frames

    uint8_t _cs;
    bool _multiturn;
    SPISettings _spiSettings;
    uint32_t _lastEndUs = 0;
    bool _primed = false;
    bool _valid = false;
    bool _warning = false;
    uint32_t _failCount = 0;
    uint16_t _lastWord = 0;
    float _lastRawDeg = 0.0f;
    float _continuousDeg = 0.0f;
    float _zeroOffsetDeg = 0.0f;
};
