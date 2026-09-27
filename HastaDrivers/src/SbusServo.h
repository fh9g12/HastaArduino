#pragma once
#include <Arduino.h>
#include <sbus.h>

// Drives one channel of an SBUS-native servo, for comparing SBUS vs PWM
// (ServoBank) actuation on otherwise identical test rigs. SBUS is always
// a full 16-channel frame -- every channel other than `channel` is held
// at a fixed neutral value.
//
// Uses Serial2, not Serial1 -- confusingly, on this core Serial1 is bound
// to hardware UART0 and Serial2 to UART1 (see the extern declarations'
// own comments in cores/rp2040/SerialUART.h). GPIO20 (TX) and GPIO21
// (RX) are only valid alternate-function pins for UART1 (confirmed in
// SerialUART.cpp's setTX()/setRX() pin-validity bitsets), so Serial1
// would reject them -- SerialUART::setTX()/setRX() panic() on an invalid
// pin, and that panic message may not even reach the USB-CDC Serial
// monitor, which looked exactly like the whole sketch silently hanging.
// If GPIO20/21 ever change, re-check both pins land in the SAME UART's
// valid-pin bitset in SerialUART.cpp before assuming this still applies.
//
// RP2040/RP2350 isn't one of the platforms the bolderflight/sbus library
// explicitly supports inversion for (Teensy, STM32L4, ESP32 -- checked
// its actual source, src/sbus.cpp: any unrecognised platform falls
// through to a generic Serial.begin() with NO inversion applied, silently
// ignoring the library's own `inverted` constructor argument). SBUS is
// idle-low (inverted UART), so this class handles inversion itself via
// the earlephilhower core's own SerialUART::setInvertTX()/setInvertRX()
// -- confirmed by reading cores/rp2040/SerialUART.cpp: begin() applies
// gpio_set_outover()/gpio_set_inover() from those flags exactly once per
// begin(), not repeated per-write, so it's a solid fit.
//
// An earlier version of this file called gpio_set_outover()/
// gpio_set_inover() directly instead. Confirmed working (via a dedicated
// LED bring-up test, GpioInvertBringup.ino) for the RAW MECHANISM, but
// that direct approach is fragile in general: this core's digitalWrite()
// calls gpio_set_function() on every single call (not just once in
// pinMode()), and gpio_set_function() clears override bits as a side
// effect -- so anything that ever calls digitalWrite() on the same pin
// would silently wipe the override out. SerialUART's own
// setInvertTX/RX() doesn't have that problem (begin() re-applies them
// from its own stored flags, not a one-shot external poke), so it's used
// here instead now that it's been confirmed to exist.
//
// Constructor note: on a generic (non-ESP32) Arduino core, bfs::SbusTx
// only takes (HardwareSerial*, inverted) -- no pin arguments (that
// overload is ESP32-only). Pin assignment instead goes through the
// earlephilhower core's own Serial2.setTX()/setRX() remap, same pattern
// as SPI1's remap in Mt6835Encoder.h. The `inverted` argument passed to
// bfs::SbusTx itself is inert on this platform (see above) -- true is
// passed anyway for documentation of intent; the real inversion happens
// via setInvertTX/RX() below.
//
// SBUS2 note: SBUS2 (Futaba's protocol) adds bidirectional telemetry
// time-slots on top of the same core 25-byte control frame, but accepts
// plain SBUS control frames fine without the telemetry extension being
// used -- this class never reads telemetry back (the MT6835 encoder is
// the ground-truth feedback for this rig instead), so that's not a
// concern here.
class SbusServo {
public:
    // txPin/rxPin: tied together externally at the SBUS connector (same
    // "two GPIOs, wired together outside the chip" approach the
    // bolderflight examples use on other platforms -- no single-wire
    // half-duplex peripheral mode needed).
    // channel: which of SBUS's 16 channels carries the commanded position.
    // chMin/chMax: raw SBUS channel value mapped to 0deg/180deg.
    // Defaults are 0-2047 -- confirmed empirically (bench testing) to be
    // this servo's actual usable range (128deg achieved), wider than the
    // 172-1811 "standard RC" convention (only 104deg) -- but still
    // tunable via CONFIG since it's specific to this servo, same
    // reasoning as ServoBank's pulseMinUs/pulseMaxUs. NEVER set chMax to
    // 2048 or above: SBUS channels are packed as 11-bit fields on the
    // wire (0-2047), so 2048 (bit 11 set, bits 0-10 all zero) truncates
    // to 0 when serialized -- confirmed on the bench, commanding exactly
    // that value snaps the servo to zero instead of full-scale.
    // chMax=2047 is the real ceiling, not a round-number guess.
    // broadcastAll: when true (the default -- servo's bound channel
    // usually isn't known yet the first time this rig gets wired up),
    // every one of SBUS's 16 channels is driven to the same commanded
    // value instead of just `channel`, so it doesn't matter which
    // channel the servo is actually listening on. Switch it off (via
    // setBroadcastAll() / CONFIG's "broadcast" field, no reflash needed)
    // once the real channel is known, so this rig isn't quietly also
    // commanding 15 other channels something might care about later.
    SbusServo(int8_t txPin, int8_t rxPin, uint8_t channel = 0,
              int16_t chMin = 0, int16_t chMax = 2047, bool broadcastAll = true)
        : _txPin(txPin), _rxPin(rxPin), _channel(channel),
        _chMin(chMin), _chMax(chMax), _broadcastAll(broadcastAll), _sbusTx(&Serial2, true) {
    }

    void begin() {
        for (int i = 0; i < 16; i++) {
            _data.ch[i] = (172 + 1811) / 2; // neutral on every unused channel
        }

        // All four of these are "call before .begin()" settings on
        // SerialUART -- pin remap, then inversion, then Begin() (which
        // calls Serial2.begin() internally and applies both).
        Serial2.setTX(_txPin);
        Serial2.setRX(_rxPin);
        Serial2.setInvertTX(true);
        Serial2.setInvertRX(true);
        _sbusTx.Begin();

        writeDeg(90.0f); // center on startup
    }

    // Switches between standard SBUS (100000 baud) and "Fast SBUS"
    // (200000 baud, a less formally standardised but increasingly common
    // variant some receivers/servos support for a quicker update rate).
    // Not the same thing as SBUS2 (that's about telemetry, this is about
    // baud) -- your servos being SBUS2 doesn't tell you whether they
    // support the faster baud too, so default false (standard) and only
    // opt into fast once basic control is confirmed working.
    //
    // The bfs library only lets you pick fast-vs-standard via a
    // constructor argument (fixed at construction, no "change it later"
    // method) -- this bypasses that and re-configures the UART directly,
    // since Write() just pushes bytes at whatever baud Serial2 currently
    // has, regardless of what baud Begin() originally set it up with. No
    // need to re-apply inversion here -- setInvertTX/RX() are sticky
    // SerialUART-level settings, not a one-shot poke, so begin()
    // re-applies them itself every time it (re)configures the UART.
    void setFast(bool fast) {
        _fast = fast;
        Serial2.begin(_fast ? 200000UL : 100000UL, SERIAL_8E2);
    }

    bool fast() const { return _fast; }

    void writeDeg(float deg) {
        deg = constrain(deg, 0.0f, 180.0f);
        int16_t value = _chMin + (int16_t)((deg / 180.0f) * (_chMax - _chMin));
        if (_broadcastAll) {
            for (int i = 0; i < 16; i++) _data.ch[i] = value;
        } else {
            _data.ch[_channel] = value;
        }
        retransmit();
    }

    // Re-sends the last commanded value without changing it. SBUS
    // servos expect a steadily repeating frame -- like a PWM servo
    // expects a repeating pulse -- a single one-shot frame isn't enough
    // to reliably hold position; most implementations have a
    // signal-loss failsafe. Call this periodically (see
    // sbusUpdateIntervalMs in the sketch) whenever writeDeg() isn't
    // already being called at a fast enough rate on its own (e.g.
    // during a static settle/hold).
    void retransmit() {
        _sbusTx.data(_data);
        _sbusTx.Write();
    }

    void setChannelRange(int16_t chMin, int16_t chMax) {
        _chMin = chMin;
        _chMax = chMax;
    }

    int16_t chMin() const { return _chMin; }
    int16_t chMax() const { return _chMax; }

    // See the constructor comment -- broadcast every channel identically
    // (true, the default) vs just `channel` (false).
    void setBroadcastAll(bool broadcastAll) { _broadcastAll = broadcastAll; }
    bool broadcastAll() const { return _broadcastAll; }

    // Only matters once broadcastAll is switched off.
    void setChannel(uint8_t channel) { _channel = channel; }
    uint8_t channel() const { return _channel; }

private:
    int8_t _txPin, _rxPin;
    uint8_t _channel;
    int16_t _chMin, _chMax;
    bool _broadcastAll;
    bool _fast = false;
    bfs::SbusData _data;
    bfs::SbusTx _sbusTx;
};
