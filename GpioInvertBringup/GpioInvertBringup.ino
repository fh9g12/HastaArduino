// GpioInvertBringup.ino
//
// Verifies gpio_set_outover()'s INVERT override actually flips a pin's
// output polarity -- no scope needed. Isolates exactly the mechanism
// SbusServo.h relies on (see HastaDrivers/src/SbusServo.h) from the
// UART/SBUS complexity entirely: real SBUS traffic toggles far too fast
// (100000 baud) to see anything meaningful on an LED, so this drives the
// SAME plain digitalWrite() HIGH/LOW sequence out two pins at 1Hz --
// REF_PIN normally, INVERTED_PIN with the override applied -- and you
// just look at whether the two LEDs blink in sync or in anti-phase.
//
// Wiring: an LED + resistor (a few hundred ohms) from REF_PIN to GND,
// and another from INVERTED_PIN to GND. Uses the same pins the real
// SbusServoCalibration project uses for TX/RX, so a pass here also
// confirms those specific pins support the override, not just the
// mechanism in general.
//
// IMPORTANT: uses gpio_put(), not digitalWrite(). Traced this core's
// digitalWrite() (cores/rp2040/wiring_digital.cpp) and it calls
// gpio_set_function(pin, GPIO_FUNC_SIO) on EVERY call, not just once in
// pinMode() -- and gpio_set_function() explicitly clears the pin's
// input/output/irq override bits as a side effect (see the comment on it
// in pico-sdk's gpio.c). So a digitalWrite()-based version of this test
// silently wipes out gpio_set_outover()'s effect on every single call --
// first attempt at this test showed both LEDs always doing the same
// thing, which is exactly that bug, not proof the override doesn't work.
// gpio_put() is the lower-level pico-sdk primitive digitalWrite() itself
// wraps -- it only touches the SIO output register, not the function
// select/override registers, so it doesn't have this problem.
//
// (This is specific to plain digitalWrite()-style GPIO. The real
// SbusServo.h doesn't call digitalWrite() at all -- Serial1.write() goes
// through the UART peripheral's own FIFO without re-muxing the pin per
// byte, so it likely isn't affected by this same bug. This test still
// needs to pass, though, before trusting that assumption.)
//
// Expected result if the override works: the two LEDs blink in exact
// ANTI-phase (one on while the other's off).

#include <Arduino.h>
#include <hardware/gpio.h>

const uint8_t REF_PIN = 20;      // normal, un-inverted reference (same pin SBUS TX uses)
const uint8_t INVERTED_PIN = 21; // same logic, but with the invert override (same pin SBUS RX uses)

void setup() {
    Serial.begin(115200);
    uint32_t waitStartMs = millis();
    while (!Serial && millis() - waitStartMs < 3000) { delay(10); }

    // pinMode() (not digitalWrite()) is the right place for this one-time
    // gpio_set_function()+gpio_set_dir() setup -- it's only called once.
    pinMode(REF_PIN, OUTPUT);
    pinMode(INVERTED_PIN, OUTPUT);

    // Override applied AFTER pinMode() -- a pin-mux change resets a
    // previously-applied override, so this order matters.
    gpio_set_outover(INVERTED_PIN, GPIO_OVERRIDE_INVERT);

    Serial.println(F("[boot] REF_PIN and INVERTED_PIN configured -- watch the two LEDs."));
    Serial.println(F("[boot] Expect anti-phase blinking (one on while the other's off)."));
}

void loop() {
    gpio_put(REF_PIN, true);
    gpio_put(INVERTED_PIN, true); // should appear LOW on its LED if the override works
    Serial.println(F("REF=HIGH, INVERTED commanded HIGH (should read LOW on its LED)"));
    delay(1000);

    gpio_put(REF_PIN, false);
    gpio_put(INVERTED_PIN, false); // should appear HIGH on its LED if the override works
    Serial.println(F("REF=LOW, INVERTED commanded LOW (should read HIGH on its LED)"));
    delay(1000);
}
