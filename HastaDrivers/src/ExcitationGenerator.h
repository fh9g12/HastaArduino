#pragma once
#include <Arduino.h>
#include <math.h>
#include "LinearChirp.h"
#include "OneMinusCosine.h"

// Shared waveform generator for a rig's excitation signal -- sine / 1-cosine
// doublet / chirp, with an optional cycle count (auto-stop) and an
// optional START DELAY (delayS).
//
// Deliberately splits "configured to run" into two separate concepts,
// not one enabled flag, because a single flag can't express "wait for a
// trigger, then start N seconds later":
//   - armed (sticky, user-set): "the next trigger event should start
//     this". Set via setArmed() -- stays armed across multiple triggers
//     until explicitly changed, same as a capture's durationS/sampleHz
//     persist across multiple ARM/FIRE cycles.
//   - active (transient, auto-managed): "is this waveform CURRENTLY
//     producing nonzero output right now". Set true by triggerStart()
//     (only if armed), cleared automatically once cycles() periods have
//     elapsed (or never, if cycles()==0 -- runs until the next trigger
//     re-syncs it or setArmed(false) disarms it).
//
// So the workflow this enables: setArmed(true) + configure params once;
// every subsequent trigger (external pin, SCPI FIRE, RUN's internal
// fire) calls triggerStart(now), which waits delayS seconds then begins
// oscillating -- exactly "wait for a trigger, start N seconds later".
class ExcitationGenerator {
public:
    enum class Type : uint8_t { SINE = 0, COSINE = 1, CHIRP = 2 };

    void setType(Type type) { _type = type; }
    Type type() const { return _type; }

    void setFreqHz(float freqHz) { _freqHz = freqHz; }       // SINE
    float freqHz() const { return _freqHz; }
    void setChirpRange(float f0, float f1) { _f0 = f0; _f1 = f1; } // CHIRP
    float f0() const { return _f0; }
    float f1() const { return _f1; }
    void setPeriodS(float periodS) { _periodS = periodS; }   // COSINE, CHIRP
    float periodS() const { return _periodS; }
    void setAmplitudeDeg(float amplitudeDeg) { _amplitudeDeg = amplitudeDeg; }
    float amplitudeDeg() const { return _amplitudeDeg; }
    void setCycles(float cycles) { _cycles = cycles; }        // 0 = run until the next trigger/disarm
    float cycles() const { return _cycles; }
    void setDelayS(float delayS) { _delayS = delayS; }
    float delayS() const { return _delayS; }

    void setArmed(bool armed) { _armed = armed; if (!armed) _active = false; }
    bool armed() const { return _armed; }
    bool active() const { return _active; }

    // Called by the trigger pathway (see HastaDAQ.ino's doTrigger()) --
    // no-op if not armed. If armed, (re)starts the waveform referenced
    // to nowUs: outputs 0 for the first delayS() seconds, then begins.
    void triggerStart(uint32_t nowUs) {
        if (!_armed) { _active = false; return; }
        _active = true;
        _startUs = nowUs + (uint32_t)(_delayS * 1000000.0f);
    }

    // Call every loop iteration -- returns the current commanded degrees
    // (0 if not active, or still within the start delay).
    float update(uint32_t nowUs) {
        if (!_active) return 0.0f;
        if (nowUs < _startUs) return 0.0f; // still waiting out the start delay

        float tS = (nowUs - _startUs) / 1000000.0f;
        float periodS;
        float value;
        switch (_type) {
            case Type::COSINE: {
                periodS = _periodS;
                OneMinusCosine wave(periodS, 0.0f, _amplitudeDeg);
                value = wave.deg(fmodf(tS, periodS));
                break;
            }
            case Type::CHIRP: {
                periodS = _periodS;
                LinearChirp wave(_f0, _f1, periodS, 0.0f, _amplitudeDeg);
                value = wave.deg(fmodf(tS, periodS));
                break;
            }
            case Type::SINE:
            default: {
                periodS = 1.0f / _freqHz;
                LinearChirp wave(_freqHz, _freqHz, periodS, 0.0f, _amplitudeDeg);
                value = wave.deg(fmodf(tS, periodS));
                break;
            }
        }

        if (_cycles > 0.0f && tS >= periodS * _cycles) {
            _active = false; // auto-stop once the configured cycle count elapses
            return 0.0f;
        }
        return value;
    }

private:
    Type _type = Type::SINE;
    float _freqHz = 1.0f;
    float _f0 = 1.0f, _f1 = 1.0f;
    float _periodS = 1.0f;
    float _amplitudeDeg = 5.0f;
    float _cycles = 1.0f;
    float _delayS = 0.0f;
    bool _armed = false;
    bool _active = false;
    uint32_t _startUs = 0;
};
