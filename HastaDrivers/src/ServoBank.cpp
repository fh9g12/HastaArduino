#include "ServoBank.h"

ServoBank::ServoBank(const uint8_t* pins, uint8_t numServos, uint32_t pwmFreqHz,
                      uint16_t pulseMinUs, uint16_t pulseMaxUs)
    : _pins(pins), _numServos(numServos), _pwmFreqHz(pwmFreqHz),
    _pulseMinUs(pulseMinUs), _pulseMaxUs(pulseMaxUs) {
}

void ServoBank::begin() {
    analogWriteFreq(_pwmFreqHz);
    analogWriteResolution(16); // matches PWM_RANGE = 65535

    for (uint8_t i = 0; i < _numServos; i++) {
        pinMode(_pins[i], OUTPUT);
        writeDeg(i, 90.0f); // center on startup
    }
}

void ServoBank::writeDeg(uint8_t channel, float deg) {
    if (channel >= _numServos) return;

    deg = constrain(deg, 0.0f, 180.0f);
    uint32_t pulse_us = _pulseMinUs + (uint32_t)((deg / 180.0f) * (_pulseMaxUs - _pulseMinUs));
    uint32_t period_us = 1000000UL / _pwmFreqHz;
    uint32_t duty = (uint32_t)(((uint64_t)pulse_us * PWM_RANGE) / period_us);

    analogWrite(_pins[channel], duty);
}

void ServoBank::writeAllDeg(float deg) {
    for (uint8_t i = 0; i < _numServos; i++) {
        writeDeg(i, deg);
    }
}

void ServoBank::setPwmFreqHz(uint32_t hz) {
    _pwmFreqHz = hz;
    analogWriteFreq(hz);
}

void ServoBank::setPulseRangeUs(uint16_t minUs, uint16_t maxUs) {
    _pulseMinUs = minUs;
    _pulseMaxUs = maxUs;
}
