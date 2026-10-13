#pragma once
#include <Arduino.h>
#include <SbusServoBank.h>
#include <PidController.h>

// ---------------------------------------------------------------------
// TWEAK SERVO NAMES / SBUS CHANNEL IDS HERE -- this is the one place.
// `name` is cosmetic (Serial boot log only). `sbusChannel` (0-15) is what
// actually matters -- it must match whichever SBUS channel your receiver
// has each servo bound to. Reorder/rename/renumber freely; NUM_CHANNELS
// derives from this array's length, nothing else needs to change.
// ---------------------------------------------------------------------
struct ChannelDef {
    const char* name;
    uint8_t sbusChannel;
};

// One validated CHANCONFIG entry, applied together with the others in the
// same command (see SetChanConfig in HastaDAQ.ino).
struct ChanUpdate {
    int ch;
    float excGain, ctrlGain, trimDeg;
    int16_t chMin, chMax;
};

static const ChannelDef CHANNEL_DEFS[] = {
    {"RUDDER",  0},
    {"ELEV_R",  1},
    {"ELEV_L",  2},
    {"AIL_R",   3},
    {"AIL_L",   4},
};
static const uint8_t NUM_CHANNELS = sizeof(CHANNEL_DEFS) / sizeof(CHANNEL_DEFS[0]);

// Owns the SBUS output bank and every channel's mix state (trim/
// excitation-gain/control-gain -- see HastaDAQ.ino's signal-flow header
// comment for the combining formula). combine()/write() apply that
// formula and refresh the SBUS frame at a fixed rate, independent of how
// often it's called.
class ChannelMixer {
public:
    ChannelMixer() : _servos(SBUS_TX_PIN, SBUS_RX_PIN, sbusChannelNumbers(), NUM_CHANNELS) {
        for (uint8_t i = 0; i < NUM_CHANNELS; i++) {
            _excGain[i] = 0.0f;
            _ctrlGain[i] = 0.0f;
            _trimDeg[i] = 0.0f;
        }
    }

    // Elevators default into the control loop -- everything else starts
    // out excitation/trim-only. Call once from setup(), after begin().
    void applyDefaults() {
        for (uint8_t i = 0; i < NUM_CHANNELS; i++) {
            if (String(CHANNEL_DEFS[i].name).startsWith("ELEV")) _ctrlGain[i] = 1.0f;
        }
    }

    void begin() { _servos.begin(); }

    int channelIndexByName(const String& name) const {
        for (uint8_t i = 0; i < NUM_CHANNELS; i++) {
            if (name.equalsIgnoreCase(CHANNEL_DEFS[i].name)) return i;
        }
        return -1;
    }

    void setExcGain(uint8_t ch, float gain) { if (ch < NUM_CHANNELS) _excGain[ch] = constrain(gain, -1.0f, 1.0f); }
    void setCtrlGain(uint8_t ch, float gain) { if (ch < NUM_CHANNELS) _ctrlGain[ch] = constrain(gain, -1.0f, 1.0f); }
    void setTrimDeg(uint8_t ch, float deg) { if (ch < NUM_CHANNELS) _trimDeg[ch] = deg; }
    void setChannelRange(uint8_t ch, int16_t chMin, int16_t chMax) { _servos.setChannelRange(ch, chMin, chMax); }

    float excGain(uint8_t ch) const { return (ch < NUM_CHANNELS) ? _excGain[ch] : 0.0f; }
    float ctrlGain(uint8_t ch) const { return (ch < NUM_CHANNELS) ? _ctrlGain[ch] : 0.0f; }
    float trimDeg(uint8_t ch) const { return (ch < NUM_CHANNELS) ? _trimDeg[ch] : 0.0f; }
    int16_t chMin(uint8_t ch) const { return _servos.chMin(ch); }
    int16_t chMax(uint8_t ch) const { return _servos.chMax(ch); }
    float lastCommandedDeg(uint8_t ch) const { return _servos.lastCommandedDeg(ch); }

    // Applies trim+excitation*excGain+control*ctrlGain per channel and
    // refreshes the SBUS frame -- rate-limited internally (SBUS shouldn't
    // be refreshed faster than ~its own frame time allows), so it's safe
    // to call every loop() iteration.
    void update(float excitationValue, float controlOutputDeg) {
        uint32_t nowUs = micros();
        if (nowUs - _lastUpdateUs < SBUS_UPDATE_INTERVAL_US) return;
        _lastUpdateUs = nowUs;

        for (uint8_t i = 0; i < NUM_CHANNELS; i++) {
            float deg = _trimDeg[i] + _excGain[i] * excitationValue + _ctrlGain[i] * controlOutputDeg;
            _servos.writeDeg(i, deg);
        }
        _servos.retransmit();
    }

private:
    // Every angle in this class (trim, excitation, control output, logged
    // servoDeg) is centred on 0 and limited to +/-SbusServoBank::TRAVEL_DEG
    // (+/-48.06 deg = the servos' programmed 920..2120 us end-points).
    // Anything commanded beyond that is clamped, and the logged servoDeg
    // shows the clamped value actually sent.

    static const int8_t SBUS_TX_PIN = 20, SBUS_RX_PIN = 21;
    static const uint32_t SBUS_UPDATE_INTERVAL_US = 9000; // ~111Hz -- standard SBUS frame rate ballpark

    static const uint8_t* sbusChannelNumbers() {
        static uint8_t channels[NUM_CHANNELS];
        for (uint8_t i = 0; i < NUM_CHANNELS; i++) channels[i] = CHANNEL_DEFS[i].sbusChannel;
        return channels;
    }

    SbusServoBank _servos;
    float _excGain[NUM_CHANNELS];
    float _ctrlGain[NUM_CHANNELS];
    float _trimDeg[NUM_CHANNELS];
    uint32_t _lastUpdateUs = 0;
};
