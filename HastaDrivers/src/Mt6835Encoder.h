#pragma once
#include <Arduino.h>
#include <SPI.h>

// Minimal, dependency-free MT6835 magnetic encoder driver -- SPI1 remapped
// onto whichever GPIOs it's wired to. Implements exactly the one SPI
// transaction this project needs (read the current shaft angle); no
// SimpleFOC/SimpleFOCDrivers dependency, unlike an earlier version of this
// file. Pulling in SimpleFOC's full motor-control framework just for one
// register read made ServoCalibration's compile dramatically slower (and
// was implicated in Visual Studio crashing during IntelliSense indexing)
// for a dependency this project never otherwise needed -- BLDCMotor,
// current sense, communications, etc. are all unused here.
//
// Wire protocol ported from SimpleFOCDrivers' MT6835.cpp
// (readRawAngle21()), which is itself the confirmed-working reference for
// this exact pin/init sequence. See the MT6835 datasheet for the full
// register map if you need more than an angle read later.
//
// Tracks continuous (unwrapped) angle across the encoder's 0/360 wrap
// point -- genuinely multi-turn, not just a "servo never spins past one
// revolution" special case: this same unwrap logic is what makes
// cumulative angle come out right for EncoderCalibration's continuously-
// spinning stepper rig, not just ServoCalibration's bounded sweeps.
// update() tracks crossings via shortest-path delta between consecutive
// readings, same technique SimpleFOC's Sensor base class used (that's
// the "multi-turn" behaviour this class deliberately reimplements
// without the rest of SimpleFOC).
//
// Also has optional User Auto-Calibration support (getCalibrationStatus/
// setCalEnPin/setCalibrationEnabled below) for EncoderCalibration --
// unused by ServoCalibration/SbusServoCalibration, but harmless to have
// present (they just never call those methods).
class Mt6835Encoder {
public:
    // sck/mosi/miso/cs: GPIOs wired to the encoder.
    // spiHz: SPI clock -- 1MHz is the confirmed-working value from the
    // original bring-up; the datasheet implies up to ~16.7MHz is possible.
    Mt6835Encoder(uint8_t sck, uint8_t mosi, uint8_t miso, uint8_t cs, uint32_t spiHz = 1000000)
        : _sck(sck), _mosi(mosi), _miso(miso), _cs(cs),
        _spiSettings(spiHz, MSBFIRST, SPI_MODE3) {
    }

    // Pin remap MUST happen before SPI1.begin() -- same ordering
    // requirement as the SimpleFOC driver had. Call once from setup().
    //
    // initBus = false: another object already remapped and started SPI1
    // (several SPI devices on one bus, each with its own CS -- HastaDAQ v2's
    // EncoderPorts does this), so skip the pin remap / SPI1.begin() and only
    // set up this device's chip-select. The default (true) is the original
    // single-device behaviour.
    void begin(bool initBus = true) {
        pinMode(_cs, OUTPUT);
        digitalWrite(_cs, HIGH);
        if (initBus) {
            SPI1.setSCK(_sck);
            SPI1.setTX(_mosi);
            SPI1.setRX(_miso);
            SPI1.begin();
        }

        // Prime the unwrap state with a real reading so the first update()
        // doesn't see a bogus delta from an unset 0.0 default.
        _lastRawDeg = readRawDeg();
        _continuousDeg = _lastRawDeg;
    }

    // Call every loop iteration (or before each read) to refresh the
    // cached angle over SPI.
    void update() {
        float rawDeg = readRawDeg();
        float delta = rawDeg - _lastRawDeg;
        if (delta > 180.0f) delta -= 360.0f;       // wrapped 360->0, actually still increasing
        else if (delta < -180.0f) delta += 360.0f; // wrapped 0->360, actually still decreasing
        _continuousDeg += delta;
        _lastRawDeg = rawDeg;
    }

    // Continuous (unwrapped) shaft angle in degrees, relative to the last
    // zeroAtCurrentPosition() call. Deliberately NOT wrapped to [0,360) --
    // see the class comment above for why.
    float getDegrees() const {
        return _continuousDeg - _zeroOffsetDeg;
    }

    // Software zero offset -- remembers the current reading as the new
    // zero point. Doesn't touch the encoder's own zero register/EEPROM
    // (see zeroOnChip() below for that) -- this is instant and free of
    // any write-cycle concern, and is all ANGLE?/getDegrees() need, so
    // prefer this unless you specifically need the chip's OWN ABZ/UVW/
    // PWM output pins (which this software offset has no effect on) to
    // also reflect the new zero point. Call update() first so this
    // captures a fresh reading.
    void zeroAtCurrentPosition() {
        _zeroOffsetDeg = _continuousDeg;
    }

    // --- Saving a zero across power cycles (no hardware change) ---------
    // The MT6835 is an ABSOLUTE single-turn encoder: its raw angle [0,360)
    // is the same after every power-up. So a zero can be described by the
    // raw angle that reads as 0 -- read it once after zeroing, keep the
    // number on the host, and re-apply it later instead of re-zeroing.
    // Only valid while the encoder/magnet hasn't moved relative to what it
    // measures. Software only (RAM): nothing is written to the chip.

    // The raw angle [0,360) that currently reads as 0 deg. Call update()
    // first so the raw reading is fresh.
    float zeroOffsetRawDegrees() const {
        float zero = fmodf(_lastRawDeg - getDegrees(), 360.0f);
        if (zero < 0.0f) zero += 360.0f;
        return zero;
    }

    // Re-applies a zero saved from zeroOffsetRawDegrees(). The shaft is
    // taken to be within +/-180 deg of that zero (so a reading just either
    // side of the 0/360 raw wrap comes out as a small +/- angle, not
    // ~360). Call update() first so the raw reading is fresh.
    void setZeroOffsetRawDegrees(float zeroRawDeg) {
        float delta = fmodf(_lastRawDeg - zeroRawDeg, 360.0f); // (-360, 360)
        if (delta > 180.0f) delta -= 360.0f;
        else if (delta <= -180.0f) delta += 360.0f;
        _zeroOffsetDeg = _continuousDeg - delta;
    }

    // Hardware zero: MT6835's confirmed "Auto Setting Zero-Position" SPI
    // command (datasheet section 7.6.7) -- writes the CURRENT shaft
    // position as the new zero into the chip's own ZERO_POS[11:0]
    // register. Unlike zeroAtCurrentPosition() above, this actually
    // changes what the chip's ABZ/UVW/PWM output pins (and any other
    // host reading it directly) report as zero -- worth doing if you use
    // those outputs, or want the zero point independent of this specific
    // host's software state.
    //
    // This only updates the volatile register -- it does NOT survive a
    // power cycle unless you separately call programEeprom() (see below,
    // and note its wear-cycle caution). Returns true if the chip
    // acknowledged the command (0x55), false otherwise.
    bool zeroOnChip() {
        return sendCommandExpectAck(MT6835_OP_AUTO_ZERO);
    }

    // Persists the CURRENT register map (including whatever zeroOnChip()
    // or setAutoCalFreq() last set) to EEPROM, so it survives a power
    // cycle -- datasheet section 7.6.6. Returns true if acknowledged.
    //
    // NOT free: EEPROM is rated for only ~1000 erase/program cycles
    // (datasheet Electrical Characteristics) -- don't call this
    // routinely/every test run, only when you deliberately want THIS
    // zero point to persist. The datasheet also requires waiting >6s
    // after a successful call before powering the chip down, to let the
    // write actually complete.
    bool programEeprom() {
        return sendCommandExpectAck(MT6835_OP_PROGRAM_EEPROM);
    }

    // Reads MT6835's calibration-status register (0x113, bits 7:6),
    // confirmed against the actual MagnTek datasheet (Rev.1.3, section
    // 9.2): 0=No Calibration, 1=Running Calibration, 2=Calibration
    // Failed, 3=Calibration Successful. Also confirmed: User
    // Auto-Calibration requires >64 revolutions at a constant speed
    // matching the AUTOCAL_FREQ[2:0] register (0x00E bits 6:4) BEFORE
    // pulling CAL_EN high, and after a successful calibration the chip
    // needs >6s before power-down to finish committing the result to
    // EEPROM. See setAutoCalFreq() below.
    uint8_t getCalibrationStatus() {
        return readRegister(MT6835_REG_CAL_STATUS) >> 6;
    }

    // Sets the User Auto-Calibration rotation-speed bucket -- register
    // 0x00E bits 6:4, confirmed from the datasheet's AUTOCAL_FREQ[2:0]
    // table (section 9.2):
    //   0=3200-6400RPM 1=1600-3200 2=800-1600 3=400-800
    //   4=200-400 5=100-200 6=50-100 7=25-50RPM
    // MUST be called (with a bucket matching your actual constant
    // rotation speed) before pulling CAL_EN high, per the datasheet's
    // documented procedure -- the DSP needs to know what speed range to
    // expect. Read-modify-write: preserves GPIO_DS (bit7) and the
    // reserved/MagnTek-only bits (3:0), which live in the same register.
    void setAutoCalFreq(uint8_t bucket) {
        uint8_t current = readRegister(MT6835_REG_AUTOCAL_FREQ);
        uint8_t updated = (current & 0b10001111) | ((bucket & 0x7) << 4);
        writeRegister(MT6835_REG_AUTOCAL_FREQ, updated);
    }

    // Optional -- only useful if your specific breakout board exposes
    // MT6835's CAL_EN pin (see wiring notes; small breakout PCBs
    // sometimes don't). Call once from setup() if you're using it.
    void setCalEnPin(uint8_t pin) {
        _calEnPin = pin;
        pinMode(_calEnPin, OUTPUT);
        digitalWrite(_calEnPin, LOW);
    }

    // Pull CAL_EN high (while the shaft rotates at constant speed) to
    // trigger MT6835's internal User Auto-Calibration; pull it low again
    // once done. No-op if setCalEnPin() was never called. Call
    // setAutoCalFreq() first, and keep rotating at that speed for >64
    // revolutions after this -- see getCalibrationStatus() above for the
    // full confirmed procedure.
    void setCalibrationEnabled(bool enabled) {
        if (_calEnPin != PIN_NOT_SET) digitalWrite(_calEnPin, enabled ? HIGH : LOW);
    }

private:
    static const uint8_t MT6835_OP_READ = 0b0011;
    static const uint8_t MT6835_OP_WRITE = 0b0110;
    static const uint8_t MT6835_OP_AUTO_ZERO = 0b0101;
    static const uint8_t MT6835_OP_PROGRAM_EEPROM = 0b1100;
    static const uint16_t MT6835_REG_CAL_STATUS = 0x113;
    static const uint16_t MT6835_REG_AUTOCAL_FREQ = 0x00E;
    static const uint8_t PIN_NOT_SET = 255;

    static const uint32_t COUNTS_PER_REV = 2097152UL; // 2^21 -- 21-bit angle resolution

    uint8_t readRegister(uint16_t addr) {
        uint8_t data[3] = {
            (uint8_t)((MT6835_OP_READ << 4) | (addr >> 8)),
            (uint8_t)(addr & 0xFF),
            0
        };
        SPI1.beginTransaction(_spiSettings);
        digitalWrite(_cs, LOW);
        SPI1.transfer(data, 3);
        digitalWrite(_cs, HIGH);
        SPI1.endTransaction();
        return data[2];
    }

    void writeRegister(uint16_t addr, uint8_t value) {
        uint8_t data[3] = {
            (uint8_t)((MT6835_OP_WRITE << 4) | (addr >> 8)),
            (uint8_t)(addr & 0xFF),
            value
        };
        SPI1.beginTransaction(_spiSettings);
        digitalWrite(_cs, LOW);
        SPI1.transfer(data, 3);
        digitalWrite(_cs, HIGH);
        SPI1.endTransaction();
    }

    // Shared by zeroOnChip()/programEeprom() -- both are address-less
    // (all-zero address field) commands that return an 8-bit ack byte
    // (0x55 = success) instead of register data. See datasheet Figures
    // 21/23 for the wire format both share.
    bool sendCommandExpectAck(uint8_t opcode) {
        uint8_t data[3] = { (uint8_t)(opcode << 4), 0x00, 0x00 };
        SPI1.beginTransaction(_spiSettings);
        digitalWrite(_cs, LOW);
        SPI1.transfer(data, 3);
        digitalWrite(_cs, HIGH);
        SPI1.endTransaction();
        return data[2] == 0x55;
    }

    float readRawDeg() {
        // MT6835_OP_ANGLE (0b1010) in the top nibble, angle register
        // address in the second byte, four don't-care bytes clocked out
        // to receive the 21-bit angle + 3-bit status + 8-bit CRC reply.
        uint8_t data[6] = { 0b10100000, 0x03, 0, 0, 0, 0 };
        SPI1.beginTransaction(_spiSettings);
        digitalWrite(_cs, LOW);
        SPI1.transfer(data, 6);
        digitalWrite(_cs, HIGH);
        SPI1.endTransaction();
        uint32_t raw21 = ((uint32_t)data[2] << 13) | ((uint32_t)data[3] << 5) | (data[4] >> 3);
        return (float)raw21 / (float)COUNTS_PER_REV * 360.0f;
    }

    uint8_t _sck, _mosi, _miso, _cs;
    SPISettings _spiSettings;
    float _lastRawDeg = 0.0f;
    float _continuousDeg = 0.0f;
    float _zeroOffsetDeg = 0.0f;
    uint8_t _calEnPin = PIN_NOT_SET;
};
