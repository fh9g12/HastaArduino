// ServoCalibration.ino
//
// SCPI-over-TCP bench tool for one servo + one MT6835 magnetic encoder
// mounted on its output shaft. Purpose: characterise the real pulse-width
// <-> shaft-angle relationship (ServoBank's pulse range and PWM carrier
// are both runtime-tunable via CONFIG below specifically so this can be
// found empirically -- see ServoBank.h for why the defaults are a guess,
// not a measured value), and check the servo's dynamic behaviour
// (max-range sweep, sine tracking, chirp response).
//
// Hardware:
//   - Servo PWM: GPIO20 (ServoBank, single channel).
//   - MT6835 encoder: SPI1 remapped onto GPIO10 (SCK) / 11 (MOSI) / 12
//     (MISO) / 13 (nCS) -- see Mt6835Encoder.h
//     in HastaDrivers. No external library needed -- Mt6835Encoder.h talks
//     SPI directly (just the one "read angle" transaction this project
//     needs), rather than depending on SimpleFOC's full motor-control
//     framework for a single register read.
//   - WiFi: Pimoroni RM2 breakout on SP/CE, same CYW43 pin fix as ServoSCPI.
//
// Wire protocol -- newline-terminated ASCII SCPI over TCP port 5025, same
// conventions as ServoSCPI.ino (see that file for the two-line JSON
// rationale -- Vrekrer_scpi_parser tokenizes on commas, so JSON payloads
// are read as a second raw line rather than as a command parameter):
//
//   *IDN?              -> identification string
//   POS <deg>          -> manually jog the servo to deg (0-180), if enabled
//   POS?               -> query last commanded position
//   ENABLE <0|1>       -> enable/disable servo output
//   ENABLE?            -> query enabled state
//   ANGLE?             -> live encoder reading, degrees (continuous/unwrapped)
//   ZERO               -> zero the encoder's internal zero register to the
//                         current shaft position (do this once after
//                         mounting the encoder, before trusting ANGLE?)
//   CONFIG             -> followed by a SECOND line: JSON config, e.g.
//                         {"carrierHz":600,"pulseMinUs":100,"pulseMaxUs":3000}
//                         Only given fields are changed; omitted ones keep
//                         their current value. JSON (not separate flat
//                         SET commands per field) both matches the
//                         two-line convention already used by
//                         SWEEP/SINE/CHIRP below, and keeps this within
//                         Vrekrer_scpi_parser's default 15-token budget --
//                         a real SCPI-style CONFIG:PULSE:MIN/MAX hierarchy
//                         would need custom SCPI_MAX_TOKENS, which isn't
//                         safe to change sketch-side alone (see the
//                         comment on RegisterCommand calls in setup()).
//   CONFIG?            -> query current config as JSON (same shape as above)
//   SWEEP              -> followed by a SECOND line: JSON test definition,
//                         e.g. {"startDeg":0,"endDeg":180,"halfPeriodS":5,
//                         "cycles":1,"sampleHz":100}
//                         Triangle-wave ramp between startDeg and endDeg --
//                         the max-range calibration sweep. Moves to
//                         startDeg and pauses to let it physically get
//                         there before logging starts (see SETTLE_MS),
//                         then blocks for the run's duration and replies
//                         "OK <n_samples>".
//   SINE               -> followed by a SECOND line: JSON test definition,
//                         e.g. {"freqHz":1,"center":90,"amplitude":20,
//                         "cycles":5,"sampleHz":200}. Also moves to its
//                         t=0 position (center) and settles first.
//   CHIRP              -> followed by a SECOND line: JSON test definition,
//                         e.g. {"f0":0,"f1":20,"periodS":20,"center":90,
//                         "amplitude":10,"cycles":1,"sampleHz":200}. Also
//                         moves to its t=0 position (center) and settles
//                         first.
//   STATUS?            -> "DONE <n_samples>" for the last completed run
//   DATA?              -> dumps the last run's captured time series as
//                         binary: one ASCII header line "BIN <n> <bytes>"
//                         (n = sample count, bytes = bytes per sample --
//                         currently 12), immediately followed by n*bytes
//                         raw bytes, each sample packed as
//                         {uint32 t_us; float target_deg; float encoder_deg;}
//                         little-endian (native RP2040/x86 byte order --
//                         no swap needed against a PC). CSV was the slow
//                         part of a run, not the network -- formatting and
//                         sending thousands of ASCII float lines one
//                         print() at a time, versus one write() of a
//                         packed array here.
//
// SWEEP/SINE/CHIRP all run synchronously (block the SCPI connection for
// the test's duration) rather than as a background loop -- this is a bench
// calibration tool used one run at a time, not a networked multi-client
// instrument, so the extra complexity of an async/interruptible test
// runner isn't worth it. Same reasoning as the two-line JSON convention
// above: keep the wire protocol and the implementation as simple as the
// job actually requires.

#include <WiFi.h>
#include <pico/cyw43_driver.h>
#include <math.h>

#define VREKRER_SCPI_PARSER_NO_IMPL
// Widen the command-matching hash from the library's default 8 bits --
// see EncoderCalibration.ino for the confirmed real bug this caused
// there (DATA? silently routed to a different command's handler once
// enough commands were registered for an 8-bit hash to collide).
// Preventive here: this sketch registers a similar number of commands.
#define SCPI_HASH_TYPE uint16_t
#include <Vrekrer_scpi_parser.h>
#include <ArduinoJson.h>
#include <ServoBank.h>
#include <LinearChirp.h>
#include <SweepWave.h>
#include <Mt6835Encoder.h>
#include "secrets.h"

// --- CYW43 (RM2 breakout on SP/CE) pin fix -- confirmed working ---
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

const uint8_t SERVO_PIN = 20;
ServoBank servo(&SERVO_PIN, 1, 600); // single channel, 600Hz carrier default -- retunable via CONFIG

Mt6835Encoder encoder(/*sck*/10, /*mosi*/11, /*miso*/12, /*cs*/13);

bool enabled = false;
float commandedDeg = 90.0f;

// ---------------- sample capture ----------------

struct Sample {
    uint32_t tUs;
    float targetDeg;
    float encoderDeg;
};
static_assert(sizeof(Sample) == 12, "Sample must pack with no padding -- DATA? sends it raw over the wire");

const uint16_t MAX_SAMPLES = 15000; // ~180KB -- still comfortably fits (measured ~24% RAM
                                     // use at the old 4000 cap, on a 512KB part); sized for
                                     // a 60s run at 200Hz (12000 samples) with headroom,
                                     // not just the shorter/slower calibration sweeps
const float MAX_DURATION_S = 120.0f;
const float MIN_SAMPLE_HZ = 1.0f;
const float MAX_SAMPLE_HZ = 500.0f;

Sample sampleBuf[MAX_SAMPLES];
uint16_t sampleCount = 0;

const uint32_t SETTLE_MS = 2000; // time to let the servo physically arrive before a run starts logging

// Commands the servo to deg and blocks for SETTLE_MS so it physically
// gets there before a run starts sampling -- otherwise the first chunk of
// every logged run is contaminated by the servo's travel time from
// wherever it happened to be sitting beforehand, rather than actual
// tracking behaviour at the test's own frequency/rate.
void moveToAndSettle(float deg) {
    commandedDeg = deg;
    servo.writeDeg(0, deg);
    delay(SETTLE_MS);
}

// Drives the servo from positionAt(t_s) and logs (t, target, encoder)
// samples at sampleHz until durationS elapses or the buffer fills.
// t_s passed to positionAt is elapsed time since this run started, in
// seconds -- generators that need it wrapped to a period (chirp) do that
// themselves at the call site.
template <typename PosFunc>
uint16_t runCapture(PosFunc positionAt, float durationS, float sampleHz) {
    sampleCount = 0;
    uint32_t sampleIntervalUs = (uint32_t)(1000000.0f / sampleHz);
    uint32_t durationUs = (uint32_t)(durationS * 1000000.0f);
    uint32_t t0 = micros();
    uint32_t lastSampleUs = t0 - sampleIntervalUs; // force an immediate first sample

    while (true) {
        uint32_t now = micros();
        uint32_t elapsedUs = now - t0;
        if (elapsedUs >= durationUs) break;
        if (sampleCount >= MAX_SAMPLES) break;

        if (now - lastSampleUs >= sampleIntervalUs) {
            lastSampleUs = now;
            float t_s = elapsedUs / 1000000.0f;
            float target = positionAt(t_s);

            servo.writeDeg(0, target);
            encoder.update();
            float enc = encoder.getDegrees();

            sampleBuf[sampleCount].tUs = elapsedUs;
            sampleBuf[sampleCount].targetDeg = target;
            sampleBuf[sampleCount].encoderDeg = enc;
            sampleCount++;
        }
    }
    return sampleCount;
}

// ---------------- SCPI command handlers ----------------

void Identify(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    interface.println(F("Bristol FARG,ServoCalibration,1,0.1"));
}

void SetPos(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    if (parameters.Size() < 1) {
        interface.println(F("ERR missing degrees"));
        return;
    }
    commandedDeg = String(parameters[0]).toFloat();
    if (enabled) servo.writeDeg(0, commandedDeg);
    interface.println(F("OK"));
}

void GetPos(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    interface.println(commandedDeg, 2);
}

void SetEnabled(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    if (parameters.Size() < 1) {
        interface.println(F("ERR missing 0|1"));
        return;
    }
    enabled = String(parameters[0]).toInt() != 0;
    if (enabled) servo.writeDeg(0, commandedDeg); // apply immediately, don't wait for the next POS
    interface.println(F("OK"));
}

void GetEnabled(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    interface.println(enabled ? F("1") : F("0"));
}

void GetAngle(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    encoder.update();
    interface.println(encoder.getDegrees(), 3);
}

void ZeroEncoder(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    encoder.update();
    encoder.zeroAtCurrentPosition();
    interface.println(F("OK"));
}

// CONFIG reads its JSON payload as a second raw line, same convention as
// SWEEP/SINE/CHIRP below -- see the wire-protocol note at the top of the
// file. Only fields present in the JSON are changed; anything omitted
// keeps its current value (same "start from current" pattern as
// ServoSCPI's TEST command).
void SetConfig(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    String json = interface.readStringUntil('\n');
    json.trim();

    JsonDocument doc;
    if (deserializeJson(doc, json)) {
        interface.println(F("ERR bad JSON"));
        return;
    }

    uint32_t carrierHz = doc["carrierHz"] | servo.pwmFreqHz();
    uint16_t pulseMinUs = doc["pulseMinUs"] | servo.pulseMinUs();
    uint16_t pulseMaxUs = doc["pulseMaxUs"] | servo.pulseMaxUs();

    if (carrierHz == 0) {
        interface.println(F("ERR carrierHz must be > 0"));
        return;
    }
    if (pulseMaxUs <= pulseMinUs) {
        interface.println(F("ERR pulseMaxUs must be > pulseMinUs"));
        return;
    }

    servo.setPwmFreqHz(carrierHz);
    servo.setPulseRangeUs(pulseMinUs, pulseMaxUs);
    if (enabled) servo.writeDeg(0, commandedDeg); // re-apply -- a carrier change glitches the current pulse otherwise

    interface.println(F("OK"));
}

void GetConfig(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    JsonDocument doc;
    doc["carrierHz"] = servo.pwmFreqHz();
    doc["pulseMinUs"] = servo.pulseMinUs();
    doc["pulseMaxUs"] = servo.pulseMaxUs();
    serializeJson(doc, interface);
    interface.println();
}

// SWEEP/SINE/CHIRP all read their JSON payload as a second raw line
// straight off the socket -- see the wire-protocol note at the top of the
// file for why (same convention as ServoSCPI's TEST command).

void RunSweep(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    String json = interface.readStringUntil('\n');
    json.trim();

    JsonDocument doc;
    if (deserializeJson(doc, json)) {
        interface.println(F("ERR bad JSON"));
        return;
    }
    if (!enabled) {
        interface.println(F("ERR ENABLE 1 first"));
        return;
    }

    float startDeg = doc["startDeg"] | 0.0f;
    float endDeg = doc["endDeg"] | 180.0f;
    float halfPeriodS = doc["halfPeriodS"] | 5.0f;
    float cycles = doc["cycles"] | 1.0f;
    float sampleHz = constrain((float)(doc["sampleHz"] | 100.0f), MIN_SAMPLE_HZ, MAX_SAMPLE_HZ);

    if (halfPeriodS <= 0.0f) {
        interface.println(F("ERR halfPeriodS must be > 0"));
        return;
    }

    SweepWave sweep(startDeg, endDeg, halfPeriodS);
    float durationS = sweep.periodS() * cycles;
    if (durationS <= 0.0f || durationS > MAX_DURATION_S) {
        interface.println(F("ERR duration out of range (0, 120] s"));
        return;
    }

    moveToAndSettle(sweep.deg(0.0f)); // == startDeg -- get there before logging starts
    uint16_t n = runCapture([&](float t_s) { return sweep.deg(t_s); }, durationS, sampleHz);
    commandedDeg = sweep.deg(durationS);
    interface.print(F("OK "));
    interface.println(n);
}

void RunSine(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    String json = interface.readStringUntil('\n');
    json.trim();

    JsonDocument doc;
    if (deserializeJson(doc, json)) {
        interface.println(F("ERR bad JSON"));
        return;
    }
    if (!enabled) {
        interface.println(F("ERR ENABLE 1 first"));
        return;
    }

    float freqHz = doc["freqHz"] | 1.0f;
    float center = doc["center"] | 90.0f;
    float amplitude = doc["amplitude"] | 20.0f;
    float cycles = doc["cycles"] | 5.0f;
    float sampleHz = constrain((float)(doc["sampleHz"] | 200.0f), MIN_SAMPLE_HZ, MAX_SAMPLE_HZ);

    if (freqHz <= 0.0f) {
        interface.println(F("ERR freqHz must be > 0"));
        return;
    }

    // A fixed-frequency sine is just a chirp with f0==f1 -- LinearChirp's
    // rate collapses to 0, leaving phase(t) = 2*pi*freqHz*t. Reuses the
    // shared generator instead of a second near-identical class.
    LinearChirp sine(freqHz, freqHz, 1.0f / freqHz, center, amplitude);
    float durationS = cycles / freqHz;
    if (durationS <= 0.0f || durationS > MAX_DURATION_S) {
        interface.println(F("ERR duration out of range (0, 120] s"));
        return;
    }

    moveToAndSettle(sine.deg(0.0f)); // == center -- get there before logging starts
    uint16_t n = runCapture([&](float t_s) { return sine.deg(t_s); }, durationS, sampleHz);
    commandedDeg = sine.deg(durationS);
    interface.print(F("OK "));
    interface.println(n);
}

void RunChirp(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    String json = interface.readStringUntil('\n');
    json.trim();

    JsonDocument doc;
    if (deserializeJson(doc, json)) {
        interface.println(F("ERR bad JSON"));
        return;
    }
    if (!enabled) {
        interface.println(F("ERR ENABLE 1 first"));
        return;
    }

    float f0 = doc["f0"] | 0.0f;
    float f1 = doc["f1"] | 20.0f;
    float periodS = doc["periodS"] | 20.0f;
    float center = doc["center"] | 90.0f;
    float amplitude = doc["amplitude"] | 10.0f;
    float cycles = doc["cycles"] | 1.0f;
    float sampleHz = constrain((float)(doc["sampleHz"] | 200.0f), MIN_SAMPLE_HZ, MAX_SAMPLE_HZ);

    if (periodS <= 0.0f) {
        interface.println(F("ERR periodS must be > 0"));
        return;
    }

    LinearChirp chirp(f0, f1, periodS, center, amplitude);
    float durationS = periodS * cycles;
    if (durationS <= 0.0f || durationS > MAX_DURATION_S) {
        interface.println(F("ERR duration out of range (0, 120] s"));
        return;
    }

    moveToAndSettle(chirp.deg(0.0f)); // == center -- get there before logging starts

    // LinearChirp's phase formula is only valid for t_s in [0, periodS) --
    // wrap elapsed time back into that range every cycle (see LinearChirp.h).
    uint16_t n = runCapture([&](float tAbs) { return chirp.deg(fmodf(tAbs, periodS)); }, durationS, sampleHz);
    commandedDeg = chirp.deg(fmodf(durationS, periodS));
    interface.print(F("OK "));
    interface.println(n);
}

void GetStatus(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    interface.print(F("DONE "));
    interface.println(sampleCount);
}

// Binary, not CSV -- formatting+sending thousands of ASCII float lines one
// print() call at a time was the slow part, not the network itself. Header
// is a single ASCII line so it's easy to read with readline()-style APIs;
// the payload is the raw Sample array, exactly as it sits in RAM (packing
// is nailed down by the static_assert above), sent in one write() rather
// than one call per field per sample.
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
    // Bounded, not indefinite: Serial is only for debug logging here, and
    // the board's actual job (WiFi + SCPI server) has to come up whether or
    // not anyone ever opens a terminal on it. An unbounded wait here would
    // mean a serial monitor that opens the port without asserting DTR (or
    // simply nobody watching) leaves the whole instrument dead forever.
    uint32_t serialWaitStartMs = millis();
    while (!Serial && millis() - serialWaitStartMs < 3000) { delay(10); }

    servo.begin();
    Serial.println(F("[boot] servo.begin() done"));
    encoder.begin();
    Serial.println(F("[boot] encoder.begin() done"));

    connectWiFi();

    scpi.RegisterCommand("*IDN?", &Identify);
    scpi.RegisterCommand("POS", &SetPos);
    scpi.RegisterCommand("POS?", &GetPos);
    scpi.RegisterCommand("ENABLE", &SetEnabled);
    scpi.RegisterCommand("ENABLE?", &GetEnabled);
    scpi.RegisterCommand("ANGLE?", &GetAngle);
    scpi.RegisterCommand("ZERO", &ZeroEncoder);
    scpi.RegisterCommand("CONFIG", &SetConfig);
    scpi.RegisterCommand("CONFIG?", &GetConfig);
    scpi.RegisterCommand("SWEEP", &RunSweep);
    scpi.RegisterCommand("SINE", &RunSine);
    scpi.RegisterCommand("CHIRP", &RunChirp);
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
