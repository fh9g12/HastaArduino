#pragma once
#include <Arduino.h>
#include <SPI.h>
#include <math.h>
#include <Mt6835Encoder.h>
#include <OrbisEncoder.h>

// The four ENC1..ENC4 SPI ports of the HastaDAQ v2 board: ONE shared SPI1 bus
// (SCK GP10, MOSI GP11, MISO GP12) and one chip-select per port. Each port
// can hold an MT6835, an RLS Orbis (single- or multi-turn), or nothing; the
// type is set per port, either in ENC_DEFAULT_TYPES below or at run time with
// the ENCCONFIG SCPI command.
//
// Why one bus is fine: both parts release MISO when their CS is high (MagnTek
// MT6835 data sheet "MISO stays Hi-Z when not outputting"; RLS Orbis BRD01
// "NCS high -> MISO high-Z"), and each driver applies its own SPISettings
// (MT6835 mode 3, Orbis mode 1 -- see OrbisEncoder.h for that being inferred)
// on every transaction. NOT yet measured with two real devices on the bus.
//
// Polling: update() reads every active port at most once per ENC_POLL_US,
// not on every loop() pass, so a fast loop doesn't spend its time on SPI.
// Reads are blocking but short (MT6835 ~50 us, Orbis ~40 us at 1 MHz).
//
// Un-configured (NONE) ports are never read -- a floating MISO would only
// return garbage -- and report NaN degrees so logs make the gap obvious.

enum class EncType : uint8_t { NONE = 0, MT6835 = 1, ORBIS = 2, ORBIS_MT = 3 };

// ---- EDIT THIS TO MATCH WHAT IS PLUGGED IN (or send ENCCONFIG after boot) ----
// ENC1 is the pitch encoder the elevator control loop uses.
static const EncType ENC_DEFAULT_TYPES[4] = {
    EncType::MT6835, // ENC1
    EncType::NONE,   // ENC2
    EncType::NONE,   // ENC3
    EncType::NONE,   // ENC4
};

// chip-select GPIOs per port, from the schematic: ENC1..ENC4 = GP13, GP9, GP8, GP7
static const uint8_t ENC_CS_PINS[4] = { 13, 9, 8, 7 };
static const uint32_t ENC_POLL_US = 1000; // read each active port at most every 1 ms

class EncoderPorts {
public:
    static const uint8_t NUM_PORTS = 4;

    EncoderPorts()
        : _mt{ Mt6835Encoder(SCK_PIN, MOSI_PIN, MISO_PIN, ENC_CS_PINS[0]),
               Mt6835Encoder(SCK_PIN, MOSI_PIN, MISO_PIN, ENC_CS_PINS[1]),
               Mt6835Encoder(SCK_PIN, MOSI_PIN, MISO_PIN, ENC_CS_PINS[2]),
               Mt6835Encoder(SCK_PIN, MOSI_PIN, MISO_PIN, ENC_CS_PINS[3]) },
          _orb{ OrbisEncoder(ENC_CS_PINS[0]), OrbisEncoder(ENC_CS_PINS[1]),
                OrbisEncoder(ENC_CS_PINS[2]), OrbisEncoder(ENC_CS_PINS[3]) } {
    }

    // Call once from setup(): drives every CS high, starts SPI1 on the shared
    // pins, then brings up each port that ENC_DEFAULT_TYPES says is fitted.
    void begin() {
        for (uint8_t i = 0; i < NUM_PORTS; i++) {
            pinMode(ENC_CS_PINS[i], OUTPUT);
            digitalWrite(ENC_CS_PINS[i], HIGH);
        }
        SPI1.setSCK(SCK_PIN);
        SPI1.setTX(MOSI_PIN);
        SPI1.setRX(MISO_PIN);
        SPI1.begin();
        for (uint8_t i = 0; i < NUM_PORTS; i++) {
            _type[i] = EncType::NONE;
            configure(i, ENC_DEFAULT_TYPES[i]);
        }
    }

    // Sets what is on a port (0-based index) and initialises it. Returns false
    // for a bad port, or if an Orbis port reads an invalid frame straight away
    // (wrong mode, nothing connected, or an error flag) -- it is still left
    // configured and will start reporting once it reads valid.
    bool configure(uint8_t port, EncType type) {
        if (port >= NUM_PORTS) return false;
        _type[port] = type;
        _valid[port] = false;
        switch (type) {
            case EncType::NONE:
                return true;
            case EncType::MT6835:
                _mt[port].begin(false); // bus already started in begin()
                _valid[port] = true;
                return true;
            case EncType::ORBIS:
            case EncType::ORBIS_MT:
                _orb[port].setMultiturn(type == EncType::ORBIS_MT);
                _orb[port].begin();
                _valid[port] = _orb[port].valid();
                return _valid[port];
        }
        return false;
    }

    // Call every loop() iteration.
    void update() {
        const uint32_t now = micros();
        if (now - _lastPollUs < ENC_POLL_US) return;
        _lastPollUs = now;
        for (uint8_t i = 0; i < NUM_PORTS; i++) {
            switch (_type[i]) {
                case EncType::MT6835:
                    _mt[i].update();
                    _valid[i] = true; // MT6835 reads have no validity flag here
                    break;
                case EncType::ORBIS:
                case EncType::ORBIS_MT:
                    _orb[i].update();
                    _valid[i] = _orb[i].valid();
                    break;
                default:
                    break;
            }
        }
    }

    EncType type(uint8_t port) const { return port < NUM_PORTS ? _type[port] : EncType::NONE; }
    bool active(uint8_t port) const { return type(port) != EncType::NONE; }
    // False while an Orbis reports an error / no valid frame; always true for an MT6835.
    bool valid(uint8_t port) const { return port < NUM_PORTS && active(port) && _valid[port]; }
    bool warning(uint8_t port) const {
        return port < NUM_PORTS && isOrbis(_type[port]) && _orb[port].warning();
    }
    uint32_t failCount(uint8_t port) const {
        return (port < NUM_PORTS && isOrbis(_type[port])) ? _orb[port].failCount() : 0;
    }

    // Continuous angle (deg, relative to the port's zero); NaN if the port is NONE.
    float angleDeg(uint8_t port) const {
        if (port >= NUM_PORTS) return NAN;
        switch (_type[port]) {
            case EncType::MT6835: return _mt[port].getDegrees();
            case EncType::ORBIS:
            case EncType::ORBIS_MT: return _orb[port].getDegrees();
            default: return NAN;
        }
    }

    void zero(uint8_t port) {
        if (port >= NUM_PORTS) return;
        if (_type[port] == EncType::MT6835) _mt[port].zeroAtCurrentPosition();
        else if (isOrbis(_type[port])) _orb[port].zeroAtCurrentPosition();
    }
    float zeroOffsetRaw(uint8_t port) const {
        if (port >= NUM_PORTS) return NAN;
        if (_type[port] == EncType::MT6835) return _mt[port].zeroOffsetRawDegrees();
        if (isOrbis(_type[port])) return _orb[port].zeroOffsetRawDegrees();
        return NAN;
    }
    void setZeroOffsetRaw(uint8_t port, float rawDeg) {
        if (port >= NUM_PORTS) return;
        if (_type[port] == EncType::MT6835) _mt[port].setZeroOffsetRawDegrees(rawDeg);
        else if (isOrbis(_type[port])) _orb[port].setZeroOffsetRawDegrees(rawDeg);
    }

    static const char* typeName(EncType t) {
        switch (t) {
            case EncType::MT6835: return "mt6835";
            case EncType::ORBIS: return "orbis";
            case EncType::ORBIS_MT: return "orbis_mt";
            default: return "none";
        }
    }
    // Returns false if the name is not one of none|mt6835|orbis|orbis_mt.
    static bool typeFromName(const String& name, EncType& out) {
        if (name == "none") out = EncType::NONE;
        else if (name == "mt6835") out = EncType::MT6835;
        else if (name == "orbis") out = EncType::ORBIS;
        else if (name == "orbis_mt") out = EncType::ORBIS_MT;
        else return false;
        return true;
    }

private:
    static const uint8_t SCK_PIN = 10, MOSI_PIN = 11, MISO_PIN = 12;

    static bool isOrbis(EncType t) { return t == EncType::ORBIS || t == EncType::ORBIS_MT; }

    Mt6835Encoder _mt[NUM_PORTS];
    OrbisEncoder _orb[NUM_PORTS];
    EncType _type[NUM_PORTS] = { EncType::NONE, EncType::NONE, EncType::NONE, EncType::NONE };
    bool _valid[NUM_PORTS] = { false, false, false, false };
    uint32_t _lastPollUs = 0;
};
