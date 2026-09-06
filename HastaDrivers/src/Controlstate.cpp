#include "ControlState.h"

ControlParams ControlState::_params;
mutex_t ControlState::_mutex;

void ControlState::begin() {
    mutex_init(&_mutex);
}

bool ControlState::getEnabled() {
    mutex_enter_blocking(&_mutex);
    bool en = _params.enabled;
    mutex_exit(&_mutex);
    return en;
}

void ControlState::setEnabled(bool en) {
    mutex_enter_blocking(&_mutex);
    _params.enabled = en;
    mutex_exit(&_mutex);
}

float ControlState::getServoPos(uint8_t channel) {
    if (channel >= NUM_SERVOS) return 0.0f;
    mutex_enter_blocking(&_mutex);
    float deg = _params.servoPosDeg[channel];
    mutex_exit(&_mutex);
    return deg;
}

void ControlState::setServoPos(uint8_t channel, float deg) {
    if (channel >= NUM_SERVOS) return;
    mutex_enter_blocking(&_mutex);
    _params.servoPosDeg[channel] = deg;
    mutex_exit(&_mutex);
}

TestConfig ControlState::getTest() {
    mutex_enter_blocking(&_mutex);
    TestConfig t = _params.test;
    mutex_exit(&_mutex);
    return t;
}

void ControlState::setTest(const TestConfig& t) {
    mutex_enter_blocking(&_mutex);
    _params.test = t;
    mutex_exit(&_mutex);
}

ControlParams ControlState::getAll() {
    mutex_enter_blocking(&_mutex);
    ControlParams p = _params;
    mutex_exit(&_mutex);
    return p;
}