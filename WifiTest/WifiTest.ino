// Connect to WiFi via a Pimoroni RM2 Wireless & Bluetooth Breakout plugged
// into the Pico Plus 2's SP/CE connector.
//
// ── Arduino IDE board selection (read this before flashing) ──────────────
// 1. Board selection -- the plain "Pimoroni PicoPlus2" board definition
//    never compiles in the WiFi/CYW43 driver stack at all (no
//    PICO_CYW43_SUPPORTED flag), so you must change the board selection to
//    get any WiFi code to build:
//
//        Tools > Board > "Pimoroni PicoPlus2W"
//
//    ...even though the physical board in your hands is the plain (non-W)
//    Pico Plus 2. This only changes GPIO25 (stops being a plain LED pin,
//    becomes virtualized as LED_BUILTIN) -- every other pin you're using
//    elsewhere (SPI1 10/11/12/13 for the MT6835 encoder, I2C0 4/5 for the
//    ADS122C04, servo pins 6/7/20/21/22/26) is untouched.
//
// 2. CONFIRMED BY TEST: selecting that board alone is not enough. The
//    all-zero MAC readback proved the driver was never actually reaching
//    the chip -- i.e. it's using the wrong default GPIOs internally, not
//    Pimoroni's real SP/CE wiring.
//
// 3. Real pin mapping -- straight from Pimoroni's own OFFICIAL EXAMPLE for
//    this exact hardware combo (pimoroni-pico-rp2350/examples/pico_plus_2/
//    breakouts/rm2-breakout-catfacts.py, MicroPython):
//        network.WLAN(network.STA_IF, pin_on=32, pin_out=35, pin_in=35,
//                      pin_wake=35, pin_clock=34, pin_cs=33)
//    So: REG_ON=32 (its own separate pin, NOT shared with the data line --
//    an earlier attempt here had this backwards), DATA line (out/in/wake,
//    all the same physical half-duplex pin)=35, CLOCK=34, CS=33.
//
//    This is forced with cyw43_set_pins_wl() at the very top of setup(),
//    BEFORE anything else touches the WiFi hardware -- the SDK asserts
//    the PIO bus isn't claimed yet when you call it, so it has to run
//    first, full stop.
//
// No manual GPIO wiring is needed for the RM2 itself: SP/CE is a defined
// 8-pin JST-SH connector, so plugging in the cable *is* the wiring step.
// ───────────────────────────────────────────────────────────────────────

#include <WiFi.h>
#include <pico/cyw43_driver.h>   // for cyw43_set_pins_wl() / cyw43_pin_index_t
// #include <pico/cyw43_arch.h>   // uncomment along with the trace_flags line
                                   // below for raw SPI-bus-level cyw43 tracing

// WIFI_SSID / WIFI_PASS come from secrets.h -- gitignored, not committed.
// First time setting this up: copy secrets.h.example to secrets.h and fill
// in your real network name/password there.
#include "secrets.h"

// Real SP/CE pin mapping for the Pico Plus 2 (see header comment point 3).
// Array order is fixed by cyw43_pin_index_t: REG_ON, DATA_OUT, DATA_IN,
// HOST_WAKE, CLOCK, CS.
// Straight from Pimoroni's own official example for this exact hardware
// (pimoroni-pico-rp2350/examples/pico_plus_2/breakouts/rm2-breakout-catfacts.py):
//   network.WLAN(network.STA_IF, pin_on=32, pin_out=35, pin_in=35,
//                pin_wake=35, pin_clock=34, pin_cs=33)
// REG_ON (power-enable) really is its own separate pin (32) -- it is NOT
// shared with the data line. The data line (out/in/wake all the same
// physical half-duplex pin) is 35, not 32 -- the previous attempt had
// these two swapped, which is exactly why it still read back all-zero.
uint CYW43_PINS_SPCE[CYW43_PIN_INDEX_WL_COUNT] = {
    32, // REG_ON    -- pin_on
    35, // DATA_OUT  -- pin_out
    35, // DATA_IN   -- pin_in
    35, // HOST_WAKE -- pin_wake
    34, // CLOCK     -- pin_clock
    33, // CS        -- pin_cs
};

const unsigned long CONNECT_TIMEOUT_MS = 20000;
const unsigned long RETRY_INTERVAL_MS = 5000;

// Human-readable decode of wl_status_t -- see cores/rp2040/wl_definitions.h.
// The one that actually answers "does it see the board": WL_NO_MODULE (255).
// Everything else (IDLE/NO_SSID_AVAIL/CONNECT_FAILED/DISCONNECTED/...) means
// the driver IS talking to real CYW43 hardware -- it's just not associated
// yet, for some other reason (bad password, AP out of range, etc).
const char* wifiStatusName(uint8_t s) {
    switch (s) {
    case WL_NO_MODULE:      return "WL_NO_MODULE (255 -- driver never found/initialised the chip)";
    case WL_IDLE_STATUS:    return "WL_IDLE_STATUS (chip present, not yet trying to associate)";
    case WL_NO_SSID_AVAIL:  return "WL_NO_SSID_AVAIL (chip present, can't see that SSID at all)";
    case WL_SCAN_COMPLETED: return "WL_SCAN_COMPLETED";
    case WL_CONNECTED:      return "WL_CONNECTED";
    case WL_CONNECT_FAILED: return "WL_CONNECT_FAILED (chip present, association/auth rejected -- check password)";
    case WL_CONNECTION_LOST:return "WL_CONNECTION_LOST";
    case WL_DISCONNECTED:   return "WL_DISCONNECTED (chip present, not associated)";
    default:                return "unknown code";
    }
}

// The real presence check. WiFi.macAddress() only returns a genuine,
// non-zero Infineon/Cypress MAC if the driver actually completed a working
// SPI handshake + firmware upload with the physical chip -- exactly the
// same "did the pins/wiring actually reach silicon" question the MT6835
// bring-up needed, just answered a different way since there's no simple
// register you can bit-bang on a CYW43's proprietary gSPI bus.
bool checkWifiModulePresent() {
    uint8_t mac[6];
    WiFi.macAddress(mac);

    bool allZero = true, allFF = true;
    for (int i = 0; i < 6; i++) {
        if (mac[i] != 0x00) { allZero = false; }
        if (mac[i] != 0xFF) { allFF = false; }
    }

    Serial.print("[WiFi] MAC address: ");
    for (int i = 0; i < 6; i++) {
        if (mac[i] < 0x10) { Serial.print("0"); }
        Serial.print(mac[i], HEX);
        if (i < 5) { Serial.print(":"); }
    }
    Serial.println();

    if (allZero || allFF) {
        Serial.println("[WiFi] MAC is all-zero/all-FF -- driver never got a real reply from the "
            "chip. That points to the pin-mapping question flagged above (wrong "
            "GPIOs for this board's SP/CE wiring), not a credentials problem.");
        return false;
    }

    Serial.println("[WiFi] Non-trivial MAC read back -- the driver IS talking to real CYW43 "
        "hardware on whatever pins it's using. Any connect failure from here is "
        "AP-side (SSID/password/range), not a \"can't see the board\" problem.");
    return true;
}

void connectWiFi() {
    Serial.print("[WiFi] Connecting to \"");
    Serial.print(WIFI_SSID);
    Serial.println("\"...");

    WiFi.mode(WIFI_STA);
    WiFi.begin(WIFI_SSID, WIFI_PASS);

    unsigned long startMs = millis();
    unsigned long lastStatusPrintMs = 0;
    while (WiFi.status() != WL_CONNECTED) {
        if (millis() - startMs > CONNECT_TIMEOUT_MS) {
            Serial.println();
            Serial.println("[WiFi] FAILED to connect within timeout.");
            Serial.print("[WiFi] Last status: ");
            Serial.println(wifiStatusName(WiFi.status()));
            return; // loop() will keep retrying every RETRY_INTERVAL_MS
        }
        // Print the actual status code once/sec instead of just dots -- if
        // this is stuck at the SAME non-WL_NO_MODULE code the whole time,
        // the module is present and it's an AP-side problem; if setup()
        // never even reaches this loop (hangs earlier, no serial output at
        // all after "Connecting to..."), that's the pin-mismatch failure
        // mode instead -- see point 3 in the header comment.
        if (millis() - lastStatusPrintMs >= 1000) {
            lastStatusPrintMs = millis();
            Serial.print("[WiFi] status: ");
            Serial.println(wifiStatusName(WiFi.status()));
        }
        delay(50);
    }

    Serial.println();
    Serial.println("[WiFi] Connected!");
    Serial.print("[WiFi] IP address: ");
    Serial.println(WiFi.localIP());
    Serial.print("[WiFi] RSSI: ");
    Serial.print(WiFi.RSSI());
    Serial.println(" dBm");
}

void setup() {
    Serial.begin(115200);
    while (!Serial) { delay(10); }

    // MUST happen before anything else touches WiFi/cyw43 -- the SDK
    // refuses this once the PIO bus is already claimed.
    int rc = cyw43_set_pins_wl(CYW43_PINS_SPCE);
    Serial.print("[WiFi] cyw43_set_pins_wl() -> ");
    Serial.println(rc); // 0 (PICO_OK) = accepted the pin array as valid

    // Uncomment for raw SPI-bus-level tracing of every cyw43 transaction
    // (needs Tools > Debug Port set to see the output):
    // cyw43_state.trace_flags = 0xffff;

    checkWifiModulePresent();
    connectWiFi();
}

unsigned long lastCheckMs = 0;

void loop() {
    // Non-blocking reconnect watchdog: only acts once every RETRY_INTERVAL_MS,
    // so this can sit alongside the encoder/ADC/servo loops from the rest of
    // the project without stealing their time.
    if (millis() - lastCheckMs >= RETRY_INTERVAL_MS) {
        lastCheckMs = millis();
        if (WiFi.status() != WL_CONNECTED) {
            Serial.println("[WiFi] Link down, retrying...");
            WiFi.disconnect();
            connectWiFi();
        }
    }

    // ... other non-blocking work (encoder polling, ADC, servos) goes here.
}