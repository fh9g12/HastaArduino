// EncoderBringup.ino
//
// Bare-minimum standalone sanity check for the MT6835 magnetic encoder --
// SPI1 remapped onto GPIO10 (SCK) / 11 (MOSI) / 12 (MISO) / 13 (nCS), on a
// Pimoroni Pico Plus 2 (RP2350). No WiFi, no servo, no external libraries
// at all (just Arduino core SPI), no Visual Studio/Visual Micro project --
// just this one file, meant to be opened and uploaded directly from the
// plain Arduino IDE.
//
// This talks to the encoder directly over SPI (the one "read angle"
// transaction we need) rather than going through SimpleFOC's driver --
// pulling in SimpleFOC's full motor-control framework for one register
// read made even this bring-up sketch slow to compile and was implicated
// in Visual Studio crashing during IntelliSense indexing. No library
// installs needed for this file at all.
//
// What to expect: each step below prints as it completes, so if it hangs
// you can tell exactly which call didn't return. Once past setup(), Angle
// should visibly track the shaft position if you turn it by hand -- full
// scale is 21-bit (0-2097151) per revolution, converted to degrees below.

#include <Arduino.h>
#include <SPI.h>

#define SENSOR_SCK  10
#define SENSOR_MOSI 11
#define SENSOR_MISO 12
#define SENSOR_nCS  13

const uint32_t COUNTS_PER_REV = 2097152UL; // 2^21 -- 21-bit angle resolution
SPISettings mt6835SpiSettings(1000000, MSBFIRST, SPI_MODE3);

unsigned long lastPrintMs = 0;
float lastRawDeg = 0.0f;
float continuousDeg = 0.0f;

float readRawDeg() {
    uint8_t data[6] = { 0b10100000, 0x03, 0, 0, 0, 0 }; // MT6835_OP_ANGLE | angle reg addr
    SPI1.beginTransaction(mt6835SpiSettings);
    digitalWrite(SENSOR_nCS, LOW);
    SPI1.transfer(data, 6);
    digitalWrite(SENSOR_nCS, HIGH);
    SPI1.endTransaction();

    uint32_t raw21 = ((uint32_t)data[2] << 13) | ((uint32_t)data[3] << 5) | (data[4] >> 3);
    return (float)raw21 / (float)COUNTS_PER_REV * 360.0f;
}

// Unwraps across the 0/360 point via shortest-path delta between
// consecutive readings -- same technique HastaDrivers' Mt6835Encoder uses.
void updateContinuousDeg() {
    float rawDeg = readRawDeg();
    float delta = rawDeg - lastRawDeg;
    if (delta > 180.0f) delta -= 360.0f;
    else if (delta < -180.0f) delta += 360.0f;
    continuousDeg += delta;
    lastRawDeg = rawDeg;
}

void setup() {
    Serial.begin(115200);
    unsigned long waitStartMs = millis();
    while (!Serial && millis() - waitStartMs < 3000) { delay(10); }

    Serial.println(F("[boot] Serial up"));

    pinMode(SENSOR_nCS, OUTPUT);
    digitalWrite(SENSOR_nCS, HIGH);
    Serial.println(F("[boot] nCS pin configured"));

    // Pin remap MUST happen before SPI1.begin().
    SPI1.setSCK(SENSOR_SCK);
    Serial.println(F("[boot] SPI1.setSCK done"));
    SPI1.setTX(SENSOR_MOSI);
    Serial.println(F("[boot] SPI1.setTX done"));
    SPI1.setRX(SENSOR_MISO);
    Serial.println(F("[boot] SPI1.setRX done"));

    SPI1.begin();
    Serial.println(F("[boot] SPI1.begin() done -- if you see this, setup() completed"));

    lastRawDeg = readRawDeg();
    continuousDeg = lastRawDeg;
}

void loop() {
    updateContinuousDeg();

    unsigned long now = millis();
    if (now - lastPrintMs >= 200) {
        lastPrintMs = now;
        Serial.print(F("Angle (deg, unwrapped): "));
        Serial.println(continuousDeg, 3);
    }
}
