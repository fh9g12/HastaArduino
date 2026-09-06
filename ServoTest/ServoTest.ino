// 6-servo chirp test, refactored to use the shared ServoBank/LinearChirp
// library (Visual Micro "Arduino Library Project", referenced from this
// sketch project) instead of duplicating the driver code in every sketch.
//
// Confirmed hardware behaviour this reproduces:
//   - PWM carrier: 600Hz confirmed working on a Futaba S-AG300, 700Hz
//     confirmed non-functional.
//   - Chirp: 0Hz -> 20Hz over 20s, repeating, +/-10 degrees around 90,
//     all six channels in unison.
//
// Wiring: same six GPIOs as before -- flag these against Pimoroni's
// pinout diagram before trusting them on a new board, this project has
// been bitten by hidden reserved pins more than once (Qwiic I2C on 4/5,
// LED on 25, CYW43 on 32/33/34/35, PSRAM CS on 47).

#include <ServoBank.h>
#include <LinearChirp.h>

const uint8_t SERVO_PINS[6] = { 6, 7, 20, 21, 22, 26 };

ServoBank servos(SERVO_PINS, 6, 600); // 600Hz carrier -- confirmed working ceiling
LinearChirp chirp(0.0f, 20.0f, 20.0f, 90.0f, 10.0f); // 0->20Hz/20s, +/-10 deg around 90

// Update the commanded position once per PWM carrier period -- updating
// faster than the carrier can actually emit new pulses just wastes cycles
// without changing what the servo sees.
const unsigned long UPDATE_INTERVAL_US = 1000000UL / 600UL;
unsigned long lastUpdateUs = 0;
unsigned long lastPrintMs = 0;

void setup() {
    Serial.begin(115200);
    while (!Serial) { delay(10); }

    servos.begin();

    Serial.print("[ServoBank] "); Serial.print(servos.numServos());
    Serial.print(" channels @ "); Serial.print(servos.pwmFreqHz()); Serial.println("Hz carrier");
    Serial.print("[Chirp] 0Hz -> 20Hz over "); Serial.print(chirp.periodS());
    Serial.println("s, repeating, +/-10 deg around 90");

    delay(1000);
}

void loop() {
    unsigned long nowUs = micros();

    if (nowUs - lastUpdateUs >= UPDATE_INTERVAL_US) {
        lastUpdateUs = nowUs;

        uint64_t periodUs = (uint64_t)(chirp.periodS() * 1000000.0f);
        float t_s = (float)((uint64_t)nowUs % periodUs) / 1000000.0f;

        servos.writeAllDeg(chirp.deg(t_s));

        unsigned long nowMs = millis();
        if (nowMs - lastPrintMs >= 1000) {
            lastPrintMs = nowMs;
            Serial.print("[Chirp] t="); Serial.print(t_s, 2);
            Serial.print("s  inst. freq="); Serial.print(chirp.instFreqHz(t_s), 2);
            Serial.println("Hz");
        }
    }

    // ... other non-blocking work (encoder polling, ADC, WiFi) goes here.
}