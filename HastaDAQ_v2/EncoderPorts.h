#pragma once
#include <Arduino.h>
#include <SPI.h>
#include <math.h>
#include <Mt6835Encoder.h>
#include <OrbisEncoder.h>
#include <Rm08Ssi.h>

// The five encoder ports of the HastaDAQ v2 board.
//
//   ENC1..ENC3 (ports 1-3): SPI ports on ONE shared SPI1 bus (SCK GP10, MOSI GP11, MISO GP12) with one
//   chip-select per port (GP13, GP9, GP8). Each holds an MT6835, an RLS Orbis (single- or multi-turn), or
//   nothing. The owner's rig: ENC1 and ENC2 MT6835, ENC3 Orbis.
//
//   ENC4, ENC5 (ports 4-5): the two SSI ports (headers SSI1, SSI2), each for an RLS RM08 (12-bit SSI) used
//   through an inline LDB02. ONE shared clock (GP17) and one data line each (GP18, GP19), read together by a PIO
//   state machine (Rm08Ssi.h). They cannot share MISO: an SSI data output is always driven.
//
// A port only accepts the types its connector can carry: ENC1-3 none|mt6835|orbis|orbis_mt, ENC4-5 none|rm08
// (typeAllowed()). The type is set per port, either in ENC_DEFAULT_TYPES below or at run time with the ENCCONFIG
// SCPI command.
//
// Why one SPI bus is fine: both SPI parts release MISO when their CS is high (MagnTek MT6835 data sheet "MISO
// stays Hi-Z when not outputting"; RLS Orbis BRD01 "NCS high -> MISO high-Z"), and each driver applies its own
// SPISettings (MT6835 mode 3, Orbis mode 1 -- see OrbisEncoder.h for that being inferred) on every transaction.
// NOT yet measured with two real devices on the bus.
//
// Polling: update() reads every active port at most once per ENC_POLL_US, not on every loop() pass, so a fast
// loop doesn't spend its time on encoders. SPI reads are blocking but short (MT6835 ~50 us, Orbis ~40 us at
// 1 MHz). The SSI ports never block: the PIO state machine runs the frame and update() just collects it, so the
// RM08s are refreshed every poll (1 kHz), well above the 100 Hz needed.
//
// Un-configured (NONE) SPI ports are never read -- a floating MISO would only return garbage -- and report NaN
// degrees so logs make the gap obvious. An unplugged SSI port reads all ones (pull-up), which the RM08 frame check
// rejects, so it reports valid=false and NaN until a good frame arrives.

enum class EncType : uint8_t { NONE = 0, MT6835 = 1, ORBIS = 2, ORBIS_MT = 3, RM08 = 4 };

// ---- EDIT THIS TO MATCH WHAT IS PLUGGED IN (or send ENCCONFIG after boot) ----
// ENC1 is the pitch encoder the elevator control loop uses. SPI ports default to empty except ENC1; the SSI ports
// default to RM08 because an unplugged RM08 line is rejected by its frame check (no garbage is ever reported).
static const EncType ENC_DEFAULT_TYPES[5] = {
    EncType::MT6835, // ENC1 (SPI)
    EncType::NONE,   // ENC2 (SPI)
    EncType::NONE,   // ENC3 (SPI)
    EncType::RM08,   // ENC4 = SSI1
    EncType::RM08,   // ENC5 = SSI2
};

// chip-select GPIOs per SPI port, from the schematic: ENC1..ENC3 = GP13, GP9, GP8
static const uint8_t ENC_CS_PINS[3] = { 13, 9, 8 };
// SSI pins: shared clock, DATA1; DATA2 must be the next GPIO (the PIO samples both with one IN instruction)
static const uint8_t SSI_CLK_PIN = 17, SSI_DATA1_PIN = 18;
static const uint32_t SSI_CLOCK_HZ = 500000; // same as the owner's known-good ESP32 sketch; the RM08 allows up to 4 MHz
static const uint32_t ENC_POLL_US = 1000;    // read each active port at most every 1 ms

class EncoderPorts {
public:
    static const uint8_t NUM_SPI_PORTS = 3;
    static const uint8_t NUM_SSI_PORTS = 2;
    static const uint8_t NUM_PORTS = NUM_SPI_PORTS + NUM_SSI_PORTS;

    EncoderPorts()
        : _mt{ Mt6835Encoder(SCK_PIN, MOSI_PIN, MISO_PIN, ENC_CS_PINS[0]),
               Mt6835Encoder(SCK_PIN, MOSI_PIN, MISO_PIN, ENC_CS_PINS[1]),
               Mt6835Encoder(SCK_PIN, MOSI_PIN, MISO_PIN, ENC_CS_PINS[2]) },
          _orb{ OrbisEncoder(ENC_CS_PINS[0]), OrbisEncoder(ENC_CS_PINS[1]),
                OrbisEncoder(ENC_CS_PINS[2]) } {
    }

    // Call once from setup(): drives every SPI CS high, starts SPI1 on the shared pins, then brings up each port
    // that ENC_DEFAULT_TYPES says is fitted.
    void begin() {
        for (uint8_t i = 0; i < NUM_SPI_PORTS; i++) {
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

    static bool isSsiPort(uint8_t port) { return port >= NUM_SPI_PORTS && port < NUM_PORTS; }

    // Which types a port's connector can carry (see the top of this file).
    static bool typeAllowed(uint8_t port, EncType type) {
        if (port >= NUM_PORTS) return false;
        if (type == EncType::NONE) return true;
        if (isSsiPort(port)) return type == EncType::RM08;
        return type == EncType::MT6835 || type == EncType::ORBIS || type == EncType::ORBIS_MT;
    }

    // Sets what is on a port (0-based index) and initialises it. Returns false for a bad port, a type the port
    // cannot carry, or if the device does not give a valid reading straight away (an Orbis reading an invalid
    // frame -- wrong mode, nothing connected, an error flag -- or an RM08 line with nothing on it): the port is
    // then still left configured and will start reporting once it reads valid.
    bool configure(uint8_t port, EncType type) {
        if (!typeAllowed(port, type)) return false;
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
            case EncType::RM08:
                if (!_ssi.begin(SSI_CLK_PIN, SSI_DATA1_PIN, SSI_CLOCK_HZ)) return false; // no free PIO state machine
                _valid[port] = _ssi.valid(port - NUM_SPI_PORTS);
                return _valid[port];
        }
        return false;
    }

    // Call every loop() iteration.
    void update() {
        const uint32_t now = micros();
        if (now - _lastPollUs < ENC_POLL_US) return;
        _lastPollUs = now;
        for (uint8_t i = 0; i < NUM_SPI_PORTS; i++) {
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
        if (_type[3] == EncType::RM08 || _type[4] == EncType::RM08) {
            _ssi.update(); // collects the last frame and starts the next; never blocks
            for (uint8_t i = NUM_SPI_PORTS; i < NUM_PORTS; i++) {
                if (_type[i] == EncType::RM08) _valid[i] = _ssi.valid(i - NUM_SPI_PORTS);
            }
        }
    }

    EncType type(uint8_t port) const { return port < NUM_PORTS ? _type[port] : EncType::NONE; }
    bool active(uint8_t port) const { return type(port) != EncType::NONE; }
    // False while an Orbis or RM08 reports an error / no valid frame; always true for an MT6835.
    bool valid(uint8_t port) const { return port < NUM_PORTS && active(port) && _valid[port]; }
    bool warning(uint8_t port) const {
        return port < NUM_PORTS && isOrbis(_type[port]) && _orb[port].warning();
    }
    uint32_t failCount(uint8_t port) const {
        if (port >= NUM_PORTS) return 0;
        if (isOrbis(_type[port])) return _orb[port].failCount();
        if (_type[port] == EncType::RM08) return _ssi.failCount(port - NUM_SPI_PORTS);
        return 0;
    }

    // Continuous angle (deg, relative to the port's zero); NaN if the port is NONE (or an RM08 that has never
    // given a good frame).
    float angleDeg(uint8_t port) const {
        if (port >= NUM_PORTS) return NAN;
        switch (_type[port]) {
            case EncType::MT6835: return _mt[port].getDegrees();
            case EncType::ORBIS:
            case EncType::ORBIS_MT: return _orb[port].getDegrees();
            case EncType::RM08: return _ssi.getDegrees(port - NUM_SPI_PORTS);
            default: return NAN;
        }
    }

    void zero(uint8_t port) {
        if (port >= NUM_PORTS) return;
        if (_type[port] == EncType::MT6835) _mt[port].zeroAtCurrentPosition();
        else if (isOrbis(_type[port])) _orb[port].zeroAtCurrentPosition();
        else if (_type[port] == EncType::RM08) _ssi.zeroAtCurrentPosition(port - NUM_SPI_PORTS);
    }
    float zeroOffsetRaw(uint8_t port) const {
        if (port >= NUM_PORTS) return NAN;
        if (_type[port] == EncType::MT6835) return _mt[port].zeroOffsetRawDegrees();
        if (isOrbis(_type[port])) return _orb[port].zeroOffsetRawDegrees();
        if (_type[port] == EncType::RM08) return _ssi.zeroOffsetRawDegrees(port - NUM_SPI_PORTS);
        return NAN;
    }
    void setZeroOffsetRaw(uint8_t port, float rawDeg) {
        if (port >= NUM_PORTS) return;
        if (_type[port] == EncType::MT6835) _mt[port].setZeroOffsetRawDegrees(rawDeg);
        else if (isOrbis(_type[port])) _orb[port].setZeroOffsetRawDegrees(rawDeg);
        else if (_type[port] == EncType::RM08) _ssi.setZeroOffsetRawDegrees(port - NUM_SPI_PORTS, rawDeg);
    }

    static const char* typeName(EncType t) {
        switch (t) {
            case EncType::MT6835: return "mt6835";
            case EncType::ORBIS: return "orbis";
            case EncType::ORBIS_MT: return "orbis_mt";
            case EncType::RM08: return "rm08";
            default: return "none";
        }
    }
    // Returns false if the name is not one of none|mt6835|orbis|orbis_mt|rm08.
    static bool typeFromName(const String& name, EncType& out) {
        if (name == "none") out = EncType::NONE;
        else if (name == "mt6835") out = EncType::MT6835;
        else if (name == "orbis") out = EncType::ORBIS;
        else if (name == "orbis_mt") out = EncType::ORBIS_MT;
        else if (name == "rm08") out = EncType::RM08;
        else return false;
        return true;
    }

private:
    static const uint8_t SCK_PIN = 10, MOSI_PIN = 11, MISO_PIN = 12;

    static bool isOrbis(EncType t) { return t == EncType::ORBIS || t == EncType::ORBIS_MT; }

    Mt6835Encoder _mt[NUM_SPI_PORTS];
    OrbisEncoder _orb[NUM_SPI_PORTS];
    Rm08Ssi _ssi; // both SSI ports, one PIO state machine
    EncType _type[NUM_PORTS] = { EncType::NONE, EncType::NONE, EncType::NONE, EncType::NONE, EncType::NONE };
    bool _valid[NUM_PORTS] = { false, false, false, false, false };
    uint32_t _lastPollUs = 0;
};
