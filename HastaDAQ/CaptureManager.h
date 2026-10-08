#pragma once
#include <Arduino.h>
#include <WiFiUdp.h>
#include "ChannelMixer.h" // for NUM_CHANNELS

// Binary sample format shared by DATA? (bounded capture) and the
// continuous UDP stream -- see HastaDAQ.ino's wire-protocol header
// comment for field-by-field documentation. tUs means different things
// in each context (elapsed-since-capture-start for DATA?, elapsed-
// since-boot for UDP) -- see updateCapture()/updateUdpStream() below.
struct HastaDaqSample {
    uint32_t tUs;
    float adc1Mv;
    float adc2Mv;
    float encoderDeg;
    float accelX, accelY, accelZ;
    float gyroX, gyroY, gyroZ;
    float excitationDeg;
    float controlOutputDeg;
    float servoDeg[NUM_CHANNELS];
};
static_assert(sizeof(HastaDaqSample) == 4 * (4 + 3 + 3 + 2) + 4 * NUM_CHANNELS,
    "HastaDaqSample must pack with no padding -- DATA?/UDP send it raw over the wire");

const uint16_t MAX_SAMPLES = 3000; // ~200KB at NUM_CHANNELS=5 -- 15s at 200Hz / 30s at 100Hz
const float MAX_CAPTURE_DURATION_S = 120.0f;
const float MIN_SAMPLE_HZ = 1.0f;
const float MAX_SAMPLE_HZ = 200.0f;

// Bounded local-buffer capture: ARM (configure, wait for a trigger) / FIRE
// (start now) / STATUS?-DATA? (retrieve) -- see HastaDAQ.ino's ARM vs RUN
// vs FIRE header comment for the full triggering semantics. Doesn't know
// or care what a "trigger" is (SCPI FIRE, external pin, whatever) --
// callers just call fire() and get back whether it actually did anything.
class CaptureManager {
public:
    enum class State : uint8_t { IDLE, ARMED, CAPTURING };

    // Returns false (and changes nothing) if durationS/sampleHz are out
    // of range -- caller should report that as an SCPI error.
    bool arm(float durationS, float sampleHz) {
        if (durationS <= 0.0f || durationS > MAX_CAPTURE_DURATION_S) return false;
        _durationS = durationS;
        _sampleHz = constrain(sampleHz, MIN_SAMPLE_HZ, MAX_SAMPLE_HZ);
        _state = State::ARMED;
        return true;
    }

    // Returns true if this call actually started a capture (only
    // possible from ARMED) -- false is a legitimate "nothing armed,
    // ignored" result, not an error.
    bool fire() {
        if (_state != State::ARMED) return false;
        _startUs = micros();
        _lastSampleUs = _startUs - (uint32_t)(1000000.0f / _sampleHz); // force an immediate first sample
        _count = 0;
        _state = State::CAPTURING;
        return true;
    }

    State state() const { return _state; }
    uint16_t sampleCount() const { return _count; }
    float durationS() const { return _durationS; }
    float elapsedS() const { return (micros() - _startUs) / 1000000.0f; }
    const HastaDaqSample* buffer() const { return _buf; }

    // Call every loop() iteration with a freshly-filled "live" sample --
    // logs a COPY of it (with tUs overwritten to elapsed-since-start)
    // into the capture buffer if currently CAPTURING and a new sample is
    // due. Takes liveSample by const& and only copies it on the (much
    // rarer) branch that actually stores a sample, not on every call.
    void updateCapture(const HastaDaqSample& liveSample) {
        if (_state != State::CAPTURING) return;

        uint32_t nowUs = micros();
        uint32_t elapsedUs = nowUs - _startUs;
        if (elapsedUs >= (uint32_t)(_durationS * 1000000.0f) || _count >= MAX_SAMPLES) {
            _state = State::IDLE;
            return;
        }

        uint32_t intervalUs = (uint32_t)(1000000.0f / _sampleHz);
        if (nowUs - _lastSampleUs >= intervalUs) {
            _lastSampleUs = nowUs;
            _buf[_count] = liveSample;
            _buf[_count].tUs = elapsedUs;
            _count++;
        }
    }

private:
    HastaDaqSample _buf[MAX_SAMPLES];
    uint16_t _count = 0;
    State _state = State::IDLE;
    float _durationS = 10.0f;
    float _sampleHz = 100.0f;
    uint32_t _startUs = 0;
    uint32_t _lastSampleUs = 0;
};

// Continuous UDP telemetry -- independent of CaptureManager (can stream
// while idle, armed, or capturing). Same per-sample binary layout, but
// tUs is elapsed-since-boot (there's no "start" reference the way a
// bounded capture has one).
class UdpStreamer {
public:
    void configureDest(IPAddress ip, uint16_t port) { _ip = ip; _port = port; }
    void setRateHz(float hz) { _rateHz = hz; }
    void setEnabled(bool enabled) { _enabled = enabled; }

    IPAddress ip() const { return _ip; }
    uint16_t port() const { return _port; }
    float rateHz() const { return _rateHz; }
    bool enabled() const { return _enabled; }

    // Call every loop() iteration with a freshly-filled live sample.
    void update(const HastaDaqSample& liveSample) {
        if (!_enabled || _port == 0) return;
        uint32_t nowUs = micros();
        uint32_t intervalUs = (uint32_t)(1000000.0f / _rateHz);
        if (nowUs - _lastSendUs < intervalUs) return;
        _lastSendUs = nowUs;

        HastaDaqSample toSend = liveSample;
        toSend.tUs = nowUs;
        _udp.beginPacket(_ip, _port);
        _udp.write(reinterpret_cast<const uint8_t*>(&toSend), sizeof(HastaDaqSample));
        _udp.endPacket();
    }

private:
    WiFiUDP _udp;
    IPAddress _ip;
    uint16_t _port = 0;
    float _rateHz = 50.0f;
    bool _enabled = false;
    uint32_t _lastSendUs = 0;
};
