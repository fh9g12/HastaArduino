#pragma once
#include <Arduino.h>
#include <sbus.h>

// Multi-channel SBUS servo driver -- N independently-commanded channels
// sharing ONE physical SBUS bus/frame (unlike SbusServo.h, which drives
// exactly one channel, or all 16 identically). All 16 SBUS channels live
// in one bfs::SbusData frame regardless of how many servos you actually
// have wired up, so this class just owns that one frame and lets you
// address a subset of its channels by a small local index (0..numServos-1)
// rather than raw SBUS channel numbers.
//
// See SbusServo.h for the detailed rationale behind every design choice
// reused here unchanged: Serial2 (not Serial1 -- GPIO20/21 are UART1-only
// pins), SerialUART::setInvertTX/RX() for SBUS's idle-low inversion (not
// a raw gpio_set_outover() poke -- confirmed fragile against
// digitalWrite() elsewhere), and the chMax=2047 (not 2048) ceiling from
// SBUS's 11-bit channel packing.
//
// Unlike SbusServo.h (which maps 0..180 deg onto a configurable raw range),
// this class is calibrated to the HastaDAQ servos: programmed via the
// Futaba CIU-3 for 1520 us centre and 920..2120 us end-points = +/-48.06
// deg. SBUS channel value <-> pulse width uses the Futaba S.BUS convention
// of 0.625 us per count with 1024 = 1520 us, i.e. 920 us = 64, 1520 us =
// 1024, 2120 us = 1984. All angles here are degrees CENTRED ON 0.
class SbusServoBank {
public:
    static constexpr float US_PER_COUNT = 0.625f;
    static constexpr int16_t CENTRE_COUNT = 1024;
    static constexpr int16_t MIN_COUNT = 64;    // 920 us
    static constexpr int16_t MAX_COUNT = 1984;  // 2120 us
    static constexpr float TRAVEL_DEG = 48.06f; // at MIN_COUNT / MAX_COUNT
    static constexpr float COUNTS_PER_DEG = (MAX_COUNT - CENTRE_COUNT) / TRAVEL_DEG;

    // txPin/rxPin: tied together externally at the SBUS connector, same
    // as SbusServo.h.
    // channels: SBUS channel number (0-15) for each of numServos local
    // indices, e.g. {0,1,2,3,4} if your receiver/servos are bound to the
    // first 5 SBUS channels in order.
    // chMin/chMax: per-channel hard clamp on the raw SBUS value actually
    // sent, defaulting to the servos' programmed end-points. Narrow it via
    // setChannelRange() to software-limit one surface's travel; the
    // degrees<->counts scale itself stays fixed.
    SbusServoBank(int8_t txPin, int8_t rxPin, const uint8_t* channels, uint8_t numServos,
                  int16_t chMin = MIN_COUNT, int16_t chMax = MAX_COUNT)
        : _txPin(txPin), _rxPin(rxPin), _numServos(numServos), _sbusTx(&Serial2, true) {
        for (uint8_t i = 0; i < _numServos && i < MAX_SERVOS; i++) {
            _channels[i] = channels[i];
            _chMin[i] = chMin;
            _chMax[i] = chMax;
        }
    }

    void begin() {
        for (int i = 0; i < 16; i++) {
            _data.ch[i] = CENTRE_COUNT; // neutral (1520 us) on every unused channel
        }

        Serial2.setTX(_txPin);
        Serial2.setRX(_rxPin);
        Serial2.setInvertTX(true);
        Serial2.setInvertRX(true);
        _sbusTx.Begin();

        writeAllDeg(0.0f); // center every managed channel on startup
    }

    void setFast(bool fast) {
        _fast = fast;
        Serial2.begin(_fast ? 200000UL : 100000UL, SERIAL_8E2);
    }

    bool fast() const { return _fast; }

    // index: local index (0..numServos-1), NOT a raw SBUS channel number.
    // deg: degrees centred on 0. Clamped to the channel's chMin/chMax, and
    // lastCommandedDeg() reports what was actually sent after that clamp.
    void writeDeg(uint8_t index, float deg) {
        if (index >= _numServos) return;
        int16_t value = (int16_t)lroundf(CENTRE_COUNT + deg * COUNTS_PER_DEG);
        value = constrain(value, _chMin[index], _chMax[index]);
        _data.ch[_channels[index]] = value;
        _lastCommandedDeg[index] = (value - CENTRE_COUNT) / COUNTS_PER_DEG;
    }

    void writeAllDeg(float deg) {
        for (uint8_t i = 0; i < _numServos; i++) writeDeg(i, deg);
    }

    float lastCommandedDeg(uint8_t index) const {
        return (index < _numServos) ? _lastCommandedDeg[index] : 0.0f;
    }

    // Re-sends the current frame without changing any value -- see
    // SbusServo.h::retransmit() for why this matters (SBUS servos expect
    // a steadily repeating frame, not a one-shot).
    void retransmit() {
        _sbusTx.data(_data);
        _sbusTx.Write();
    }

    void setChannelRange(uint8_t index, int16_t chMin, int16_t chMax) {
        if (index >= _numServos) return;
        // Never beyond the 11-bit field (2048 would wrap to 0) or the
        // servos' programmed end-points.
        chMin = constrain(chMin, MIN_COUNT, MAX_COUNT);
        chMax = constrain(chMax, MIN_COUNT, MAX_COUNT);
        if (chMax <= chMin) return;
        _chMin[index] = chMin;
        _chMax[index] = chMax;
    }

    int16_t chMin(uint8_t index) const { return (index < _numServos) ? _chMin[index] : 0; }
    int16_t chMax(uint8_t index) const { return (index < _numServos) ? _chMax[index] : 2047; }

    uint8_t numServos() const { return _numServos; }

private:
    static const uint8_t MAX_SERVOS = 8; // headroom above the 5 channels this project needs

    int8_t _txPin, _rxPin;
    uint8_t _numServos;
    uint8_t _channels[MAX_SERVOS];
    int16_t _chMin[MAX_SERVOS];
    int16_t _chMax[MAX_SERVOS];
    float _lastCommandedDeg[MAX_SERVOS] = {0};
    bool _fast = false;
    bfs::SbusData _data;
    bfs::SbusTx _sbusTx;
};
