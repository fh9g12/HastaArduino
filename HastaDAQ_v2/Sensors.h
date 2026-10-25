#pragma once
#include <Arduino.h>
#include "EncoderPorts.h"
#include <Adafruit_ADS122C04.h>
#include <Adafruit_ICM20649.h>
#include <Adafruit_Sensor.h>

// Owns and caches all of HastaDAQ v2's sensors: the four SPI encoder ports
// (EncoderPorts.h -- ENC1 is the pitch encoder the control loop uses), both
// ADS122C04 ADCs, and the ICM20649 IMU. update() refreshes
// every cached value from whatever's newly ready -- never blocks waiting
// for data, matching HastaDAQ.ino's non-blocking loop() (see that file's
// architecture note).
//
// ADC CONFIG -- CONFIRMED half-bridge strain gauges (2x 350ohm gauges +
// 2x 350ohm completion resistors per channel), same ratiometric approach
// as StrainGaugeCalibration.ino/wiring/strain-gauge-rig.yml: bridge
// excitation is the SAME 3.3V rail that powers both ADS122C04s (v2: on the
// separate strain-gauge board, kicad/gaugeboard/, reached by a 4-wire I2C
// loom; one SHARED pair of 350R completion resistors feeds A1 of both ADCs), so VREF_SUPPLY (AVDD-referenced) is directly ratiometric
// against it with no extra reference wiring needed -- unlike that earlier
// rig, nothing here is on a separate VBUS/5V rail, so there's no
// REFP/REFN tap-off-the-bridge dance required. See kicad/gaugeboard/.
class SensorHub {
public:
    void begin() {
        encoders.begin();
        for (uint8_t i = 0; i < EncoderPorts::NUM_PORTS; i++) {
            Serial.printf("[boot] ENC%u: %s\n", (unsigned)(i + 1), EncoderPorts::typeName(encoders.type(i)));
        }

        imuOk = imu.begin_I2C();
        Serial.println(imuOk ? F("[boot] ICM20649 found") : F("[boot] ICM20649 NOT found -- check wiring/address"));

        ads1Ok = beginAds(ads1, ADS1_I2C_ADDR, "#1");
        ads2Ok = beginAds(ads2, ADS2_I2C_ADDR, "#2");
        if (!ads2Ok) scanI2CBus();
    }

    // Call every loop() iteration.
    void update() {
        encoders.update();
        updateAdc(ads1, ads1Ok, latestAdc1Mv);
        updateAdc(ads2, ads2Ok, latestAdc2Mv);
        if (imuOk) {
            sensors_event_t accel, gyro, temp;
            imu.getEvent(&accel, &gyro, &temp);
            latestAccelX = accel.acceleration.x;
            latestAccelY = accel.acceleration.y;
            latestAccelZ = accel.acceleration.z;
            latestGyroX = gyro.gyro.x;
            latestGyroY = gyro.gyro.y;
            latestGyroZ = gyro.gyro.z;
        }
    }

    // The control encoder (ENC1): 0 deg if that port is not fitted.
    float encoderDeg() const { return encoders.active(0) ? encoders.angleDeg(0) : 0.0f; }
    // Any port (0-based); NaN when the port is not configured.
    float encoderDegPort(uint8_t port) const { return encoders.angleDeg(port); }
    EncoderPorts& encoderPorts() { return encoders; }
    const EncoderPorts& encoderPorts() const { return encoders; }
    // Saved-zero support: see Mt6835Encoder.h / OrbisEncoder.h. update() has
    // run this loop, so the raw reading is fresh.
    void zeroEncoder(uint8_t port = 0) { encoders.zero(port); }
    float encoderZeroOffsetRawDeg(uint8_t port = 0) const { return encoders.zeroOffsetRaw(port); }
    void setEncoderZeroOffsetRawDeg(float zeroRawDeg, uint8_t port = 0) { encoders.setZeroOffsetRaw(port, zeroRawDeg); }

    float adc1Mv() const { return latestAdc1Mv; }
    float adc2Mv() const { return latestAdc2Mv; }
    float accelX() const { return latestAccelX; }
    float accelY() const { return latestAccelY; }
    float accelZ() const { return latestAccelZ; }
    float gyroX() const { return latestGyroX; }
    float gyroY() const { return latestGyroY; }
    float gyroZ() const { return latestGyroZ; }

private:
    static const uint8_t ADS1_I2C_ADDR = 0x40; // default, unmodified board
    static const uint8_t ADS2_I2C_ADDR = 0x41; // UNCONFIRMED guess -- the boot scan below is the fallback

    bool beginAds(Adafruit_ADS122C04& ads, uint8_t addr, const char* label) {
        if (!ads.begin(addr)) {
            Serial.print(F("[boot] ADS122C04 "));
            Serial.print(label);
            Serial.println(F(" NOT found -- check wiring/address"));
            return false;
        }
        ads.setMux(ADS122C04_MUX_AIN0_AIN1); // AINP=bridge OUT+, AINN=bridge OUT-
        ads.setGain(ADS122C04_GAIN_128);
        ads.enablePGA(true);
        ads.setVoltageReference(ADS122C04_VREF_SUPPLY); // ratiometric against the shared 3.3V rail -- see class comment
        ads.setReferenceVoltage(3.3f);
        ads.setContinuousMode(true);
        ads.setTurboMode(true);
        ads.setDataRate(ADS122C04_RATE_90SPS); // 180 SPS actual in turbo -- see StrainGaugeCalibration.ino for why
        ads.startSync();
        Serial.print(F("[boot] ADS122C04 "));
        Serial.print(label);
        Serial.println(F(" found"));
        return true;
    }

    void updateAdc(Adafruit_ADS122C04& ads, bool ok, float& latestMv) {
        if (!ok || !ads.isDataReady()) return;
        int32_t raw = ads.readData();
        if (raw != (int32_t)0xEE000000) latestMv = ads.convertToVoltage(raw) * 1000.0f;
    }

    // Prints every responding I2C address -- fallback if the second
    // ADS122C04 doesn't answer at ADS2_I2C_ADDR, since that address is an
    // unconfirmed guess.
    void scanI2CBus() {
        Serial.println(F("[boot] ADS #2 not found at guessed address -- I2C scan:"));
        for (uint8_t addr = 1; addr < 127; addr++) {
            Wire.beginTransmission(addr);
            if (Wire.endTransmission() == 0) {
                Serial.print(F("  found device at 0x"));
                Serial.println(addr, HEX);
            }
        }
    }

    EncoderPorts encoders;
    Adafruit_ADS122C04 ads1, ads2;
    Adafruit_ICM20649 imu;
    bool ads1Ok = false, ads2Ok = false, imuOk = false;

    float latestAdc1Mv = 0.0f, latestAdc2Mv = 0.0f;
    float latestAccelX = 0.0f, latestAccelY = 0.0f, latestAccelZ = 0.0f;
    float latestGyroX = 0.0f, latestGyroY = 0.0f, latestGyroZ = 0.0f;
};
