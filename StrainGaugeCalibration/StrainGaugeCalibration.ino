// StrainGaugeCalibration.ino
//
// SCPI-over-TCP bench tool for the half-bridge strain gauge rig -- same
// hardware/config as StrainGaugeBringup.ino (see that file for the full
// wiring/reference rationale: half bridge on VBUS/5V excitation, ADS122C04
// external reference tapping the bridge's own OUT- node), just exposed
// over WiFi/SCPI instead of the USB Serial monitor, matching the
// ServoCalibration/SbusServoCalibration/EncoderCalibration pattern
// elsewhere in this repo (RUN + DATA? binary capture).
//
// Hardware: see StrainGaugeBringup.ino's header comment / wiring/strain-gauge-rig.yml.
//   - ADS122C04: Qwiic (I2C + 3.3V AVDD), bridge excitation on Pico
//     VBUS (5V), external reference tapping the bridge's OUT- node.
//   - WiFi: Pimoroni RM2 (built into the Pico Plus 2 W), same CYW43 pin
//     fix as the other projects in this repo.
//
// Wire protocol -- newline-terminated ASCII SCPI over TCP port 5025,
// same two-line-JSON convention as ServoCalibration.ino (see that
// file's header for the rationale):
//
//   *IDN?              -> identification string
//   BRIDGE?            -> live reading, one line: "<bridge_mV> <ratio_mV_per_V>"
//   RUN                -> followed by a SECOND line: JSON run definition,
//                         e.g. {"durationS":10}. Blocks for the run's
//                         duration, logging every new ADC conversion
//                         (native rate -- see DATA_RATE/TURBO_MODE below,
//                         not independently configurable per run since
//                         the ADS122C04 only offers a small fixed set of
//                         data rates), then replies "OK <n_samples>".
//   STATUS?            -> "DONE <n_samples>" for the last completed run
//   DATA?              -> dumps the last run's captured time series as
//                         binary: one ASCII header line "BIN <n> <bytes>",
//                         then n*bytes raw bytes, each sample packed as
//                         {uint32 t_us; float bridge_mV; float ratio_mV_per_V}
//                         little-endian -- same framing convention as
//                         every other rig's DATA? in this repo, just a
//                         single-channel payload instead of target+encoder.

#include <WiFi.h>
#include <pico/cyw43_driver.h>

#define VREKRER_SCPI_PARSER_NO_IMPL
// Widen the command-matching hash from the library's default 8 bits --
// see EncoderCalibration.ino for the confirmed real bug this caused
// there (a command silently routed to a different command's handler
// once enough commands were registered for an 8-bit hash to collide).
#define SCPI_HASH_TYPE uint16_t
#include <Vrekrer_scpi_parser.h>
#include <ArduinoJson.h>
#include <Adafruit_ADS122C04.h>
#include "secrets.h"

// --- CYW43 (RM2, built into the Pico Plus 2 W) pin fix -- confirmed working ---
uint CYW43_PINS_SPCE[CYW43_PIN_INDEX_WL_COUNT] = {
    32, // REG_ON
    35, // DATA_OUT
    35, // DATA_IN
    35, // HOST_WAKE
    34, // CLOCK
    33, // CS
};

const uint16_t SCPI_PORT = 5025;
WiFiServer scpiServer(SCPI_PORT);
WiFiClient scpiClient;

SCPI_Parser scpi;

Adafruit_ADS122C04 ads;

// --- ADS122C04 configuration -- see StrainGaugeBringup.ino for the full
// rationale behind each of these; unchanged here. ---
const float EXCITATION_VOLTS = 5.0f;                    // real bridge excitation (Pico VBUS)
const float ADC_REFERENCE_VOLTS = EXCITATION_VOLTS / 2.0f; // REFP taps bridge OUT- (fixed V_ex/2 tap), REFN=GND
const ads122c04_gain_t GAIN = ADS122C04_GAIN_128;
const bool TURBO_MODE = true;
const ads122c04_rate_t DATA_RATE = ADS122C04_RATE_90SPS; // 90 normal / 180 turbo

// ---------------- sample capture ----------------

struct Sample {
    uint32_t tUs;
    float bridgeMv;
    float ratioMvPerV;
};
static_assert(sizeof(Sample) == 12, "Sample must pack with no padding -- DATA? sends it raw over the wire");

const uint16_t MAX_SAMPLES = 5000; // ~28s at 180SPS -- comfortably above the 10s this was asked for
const float MAX_DURATION_S = 60.0f;

Sample sampleBuf[MAX_SAMPLES];
uint16_t sampleCount = 0;

// Reads one ADC conversion into (bridgeMv, ratioMvPerV). Returns false
// (and doesn't touch the outputs) if there's a communication error --
// same 0xEE000000 sentinel the Adafruit library itself uses.
bool readBridge(float& bridgeMv, float& ratioMvPerV) {
    int32_t raw = ads.readData();
    if (raw == (int32_t)0xEE000000) return false;
    float voltage = ads.convertToVoltage(raw);
    bridgeMv = voltage * 1000.0f;
    ratioMvPerV = (voltage / EXCITATION_VOLTS) * 1000.0f;
    return true;
}

// Logs every new ADC conversion (native rate -- see DATA_RATE/TURBO_MODE
// above) until durationS elapses or the buffer fills.
uint16_t runCapture(float durationS) {
    sampleCount = 0;
    uint32_t durationUs = (uint32_t)(durationS * 1000000.0f);
    uint32_t t0 = micros();

    while (true) {
        uint32_t elapsedUs = micros() - t0;
        if (elapsedUs >= durationUs) break;
        if (sampleCount >= MAX_SAMPLES) break;

        if (!ads.isDataReady()) continue;

        float bridgeMv, ratioMvPerV;
        if (!readBridge(bridgeMv, ratioMvPerV)) continue; // skip a comms glitch, keep the run going

        sampleBuf[sampleCount].tUs = elapsedUs;
        sampleBuf[sampleCount].bridgeMv = bridgeMv;
        sampleBuf[sampleCount].ratioMvPerV = ratioMvPerV;
        sampleCount++;
    }
    return sampleCount;
}

// ---------------- SCPI command handlers ----------------

void Identify(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    interface.println(F("Bristol FARG,StrainGaugeCalibration,1,0.1"));
}

void GetBridge(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    float bridgeMv, ratioMvPerV;
    if (!readBridge(bridgeMv, ratioMvPerV)) {
        interface.println(F("ERR ADC read error"));
        return;
    }
    interface.print(bridgeMv, 4);
    interface.print(' ');
    interface.println(ratioMvPerV, 5);
}

// RUN reads its JSON payload as a second raw line straight off the
// socket -- see the wire-protocol note at the top of the file.
void RunCapture(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    String json = interface.readStringUntil('\n');
    json.trim();

    JsonDocument doc;
    if (deserializeJson(doc, json)) {
        interface.println(F("ERR bad JSON"));
        return;
    }

    float durationS = doc["durationS"] | 10.0f;
    if (durationS <= 0.0f || durationS > MAX_DURATION_S) {
        interface.println(F("ERR duration out of range (0, 60] s"));
        return;
    }

    uint16_t n = runCapture(durationS);
    interface.print(F("OK "));
    interface.println(n);
}

void GetStatus(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    interface.print(F("DONE "));
    interface.println(sampleCount);
}

// Binary, not CSV -- see ServoCalibration.ino for the full rationale.
void GetData(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    interface.print(F("BIN "));
    interface.print(sampleCount);
    interface.print(' ');
    interface.println(sizeof(Sample));
    interface.write(reinterpret_cast<const uint8_t*>(sampleBuf), (size_t)sampleCount * sizeof(Sample));
}

// ---------------- setup / loop ----------------

void connectWiFi() {
    Serial.print(F("[WiFi] Connecting to ")); Serial.println(WIFI_SSID);
    WiFi.begin(WIFI_SSID, WIFI_PASS);
    while (WiFi.status() != WL_CONNECTED) {
        delay(500);
        Serial.print(".");
    }
    Serial.println();
    Serial.print(F("[WiFi] Connected, IP=")); Serial.println(WiFi.localIP());
}

void setup() {
    cyw43_set_pins_wl(CYW43_PINS_SPCE); // must be first -- before any WiFi/hw touch

    Serial.begin(115200);
    // Bounded, not indefinite -- see ServoCalibration.ino for why.
    uint32_t serialWaitStartMs = millis();
    while (!Serial && millis() - serialWaitStartMs < 3000) { delay(10); }

    if (!ads.begin()) {
        Serial.println(F("[boot] ADS122C04 not found -- check wiring/I2C address."));
        while (1) { delay(10); }
    }
    ads.setMux(ADS122C04_MUX_AIN0_AIN1); // AINP=A0=bridge OUT+, AINN=A1=bridge OUT-
    ads.setGain(GAIN);
    ads.enablePGA(true); // required for gain >1 in differential mode -- see library source
    ads.setVoltageReference(ADS122C04_VREF_EXTERNAL); // REFP=bridge OUT-, REFN=GND -- see StrainGaugeBringup.ino
    ads.setReferenceVoltage(ADC_REFERENCE_VOLTS);
    ads.setContinuousMode(true);
    ads.setTurboMode(TURBO_MODE);
    ads.setDataRate(DATA_RATE);
    ads.startSync();
    Serial.println(F("[boot] ads.begin() done"));

    connectWiFi();

    scpi.RegisterCommand("*IDN?", &Identify);
    scpi.RegisterCommand("BRIDGE?", &GetBridge);
    scpi.RegisterCommand("RUN", &RunCapture);
    scpi.RegisterCommand("STATUS?", &GetStatus);
    scpi.RegisterCommand("DATA?", &GetData);

    scpiServer.begin();
    Serial.print(F("[SCPI] Listening on port ")); Serial.println(SCPI_PORT);
}

void loop() {
    if (!scpiClient || !scpiClient.connected()) {
        WiFiClient incoming = scpiServer.accept();
        if (incoming) {
            scpiClient = incoming;
            Serial.println(F("[SCPI] Client connected"));
        }
    }

    if (scpiClient && scpiClient.connected() && scpiClient.available()) {
        scpi.ProcessInput(scpiClient, "\n");
    }
}
