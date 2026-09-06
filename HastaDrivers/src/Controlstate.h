#pragma once
#include <Arduino.h>
#include <pico/mutex.h>

// Shared state between the network/command side and the (future) real-time
// control loop. Every accessor takes/releases a mutex internally and copies
// whole structs in or out -- a caller never sees a struct that's half old
// and half new, and the lock is only ever held for a fast copy, so it's
// safe to call from either core without risking real jitter on a control
// tick. See ControlState.cpp.
//
// Right now everything (SCPI server + servo writes) runs on one core, so
// the mutex isn't strictly load-bearing yet -- but it costs nothing, and it
// means this class doesn't need to change at all once a real-time PID loop
// moves onto its own core later.

static const uint8_t NUM_SERVOS = 6;

enum class ExcitationType : uint8_t { SINE = 0, CHIRP = 1 };

struct TestConfig {
    ExcitationType type = ExcitationType::CHIRP;
    float f0Hz = 0.0f;
    float f1Hz = 20.0f;
    float periodS = 20.0f;
    float amplitudeDeg = 10.0f;
    float centerDeg = 90.0f;
};

struct ControlParams {
    bool enabled = false;
    float servoPosDeg[NUM_SERVOS] = { 90, 90, 90, 90, 90, 90 };
    TestConfig test;
    // PID gains (Kp/Ki/Kd) slot in here once the encoder-feedback control
    // loop exists -- deliberately left out for now, nothing uses them yet.
};

class ControlState {
public:
    // Call once from setup(), before either core touches the state.
    static void begin();

    static bool getEnabled();
    static void setEnabled(bool en);

    static float getServoPos(uint8_t channel);
    static void setServoPos(uint8_t channel, float deg);

    static TestConfig getTest();
    static void setTest(const TestConfig& t);

    // Whole-struct escape hatch, for a future control loop that wants
    // everything in a single lock acquisition rather than several small
    // ones.
    static ControlParams getAll();

private:
    static ControlParams _params;
    static mutex_t _mutex;
};