// SbusServoCalibration.ino
//
// SCPI-over-TCP bench tool for one SBUS-native servo + one MT6835
// magnetic encoder mounted on its output shaft. Sibling of
// ServoCalibration.ino (same encoder, same SCPI test surface -- SWEEP/
// SINE/CHIRP/DATA?/etc are all identical), but drives the servo over
// SBUS instead of a PWM pulse, specifically so the two can be compared
// on otherwise-identical rigs: if SBUS performs the same, the simpler
// wiring (no PULSE_MIN/MAX_US calibration, no PWM carrier tuning) wins.
//
// Uses the bolderflight/sbus library (https://github.com/bolderflight/sbus).
// RP2040/RP2350 is NOT one of its explicitly supported platforms -- see
// the long comment in HastaDrivers/src/SbusServo.h for exactly what that
// means and how it's worked around (checked both the library's and the
// Arduino core's actual source rather than guessing). The inversion
// mechanism itself (GPIO output-override) was confirmed working on real
// hardware via GpioInvertBringup.ino -- still worth a scope/logic
// analyzer check on the actual SBUS output once a real servo is on hand,
// to confirm valid framing end to end, not just the inversion.
//
// Hardware:
//   - SBUS: GPIO20 (TX) / GPIO21 (RX), tied together externally at the
//     SBUS connector (same two-separate-GPIOs-wired-together approach
//     the bolderflight examples use on other platforms -- no special
//     single-wire half-duplex peripheral mode needed). Drives SBUS
//     channel 0; every other channel is held at a fixed neutral value.
//   - MT6835 encoder: SPI1 remapped onto GPIO10 (SCK) / 11 (MOSI) / 12
//     (MISO) / 13 (nCS) -- identical wiring to ServoCalibration.ino,
//     same physical encoder/shaft if this is the same rig.
//   - WiFi: Pimoroni RM2 breakout on SP/CE, same CYW43 pin fix as
//     ServoSCPI/ServoCalibration.
//
// Wire protocol -- newline-terminated ASCII SCPI over TCP port 5025,
// identical to ServoCalibration.ino except CONFIG (see below):
//
//   *IDN?              -> identification string
//   POS <deg>          -> manually jog the servo to deg (0-180), if enabled
//   POS?               -> query last commanded position
//   ENABLE <0|1>       -> enable/disable servo output
//   ENABLE?            -> query enabled state
//   ANGLE?             -> live encoder reading, degrees (continuous/unwrapped)
//   ZERO               -> zero the encoder's internal zero register to the
//                         current shaft position
//   CONFIG             -> followed by a SECOND line: JSON config, e.g.
//                         {"chMin":0,"chMax":2047,"fast":false,
//                          "updateHz":100,"broadcast":true,"channel":0}
//                         chMin/chMax: raw SBUS channel value mapped to
//                         0/180deg. 0-2047 (the full 11-bit range) is
//                         confirmed empirically as this servo's real
//                         usable range (128deg) -- wider than the
//                         172-1811 "standard RC" convention (only
//                         104deg). NEVER set chMax to 2048+: SBUS
//                         channels are 11-bit fields on the wire, so
//                         2048 truncates to 0 and the servo snaps to
//                         zero instead of full-scale (confirmed on the
//                         bench) -- 2047 is the real ceiling.
//                         fast: false = standard SBUS (100000 baud),
//                         true = "Fast SBUS" (200000 baud) -- NOT the
//                         same thing as SBUS2 (that's telemetry, this is
//                         baud); confirm your servos actually support it
//                         before enabling.
//                         updateHz: how often a fresh SBUS frame is
//                         actually sent -- the SBUS analog of
//                         ServoCalibration's carrierHz (PWM has no
//                         update-rate equivalent, it's hardware-driven;
//                         SBUS needs the CPU to keep re-sending).
//                         broadcast: true (the default) drives all 16
//                         SBUS channels identically, since the servo's
//                         bound channel isn't known yet -- switch to
//                         false and set channel once it is, so this rig
//                         isn't also quietly commanding 15 other channels.
//                         channel: which channel carries the commanded
//                         position when broadcast is false; ignored
//                         otherwise.
//                         Only given fields are changed.
//   CONFIG?            -> query current config as JSON (same shape as above)
//   SWEEP / SINE / CHIRP / STATUS? / DATA?
//                      -> identical to ServoCalibration.ino -- see that
//                         file's header comment for the JSON schemas and
//                         the binary DATA? format.
//
// SWEEP/SINE/CHIRP run synchronously (block the SCPI connection for the
// run's duration), same as ServoCalibration.ino. Unlike PWM (a hardware
// peripheral that free-runs once configured), SBUS needs the CPU to
// explicitly re-send a frame periodically or the servo's signal-loss
// failsafe can kick in -- see SBUS_RETRANSMIT_INTERVAL_MS below.

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
#include <sbus.h>
#include <SbusServo.h>
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

SbusServo servo(/*tx*/20, /*rx*/21, /*channel*/0, /*chMin*/172, /*chMax*/1811);
    // broadcastAll defaults true -- drives all 16 channels identically
    // until the servo's actual bound channel is known. Switch via CONFIG
    // ("broadcast":false, "channel":N) once it is -- no reflash needed.
Mt6835Encoder encoder(/*sck*/10, /*mosi*/11, /*miso*/12, /*cs*/13);

bool enabled = false;
float commandedDeg = 90.0f;

// Retransmit rate -- the SBUS analog of ServoCalibration's carrierHz:
// how often a fresh frame actually gets pushed to the servo. Unlike PWM
// (hardware free-runs once configured), SBUS needs the CPU to explicitly
// re-send, or the servo can trip its signal-loss failsafe during a
// static settle/hold or whenever sampleHz is slower than this. Tunable
// via CONFIG's "updateHz" field; the constant below is just the default.
uint32_t sbusUpdateIntervalMs = 10; // 10ms == 100Hz default

// ---------------- sample capture ----------------

struct Sample {
    uint32_t tUs;
    float targetDeg;
    float encoderDeg;
};
static_assert(sizeof(Sample) == 12, "Sample must pack with no padding -- DATA? sends it raw over the wire");

const uint16_t MAX_SAMPLES = 15000; // ~180KB -- see ServoCalibration.ino; sized for a
                                     // 60s run at 200Hz (12000 samples) with headroom
const float MAX_DURATION_S = 120.0f;
const float MIN_SAMPLE_HZ = 1.0f;
const float MAX_SAMPLE_HZ = 500.0f;

Sample sampleBuf[MAX_SAMPLES];
uint16_t sampleCount = 0;

const uint32_t SETTLE_MS = 2000; // time to let the servo physically arrive before a run starts logging

// Commands the servo to deg and blocks for SETTLE_MS so it physically
// gets there before a run starts sampling, re-sending the SBUS frame
// periodically throughout the hold (see sbusUpdateIntervalMs) rather
// than a plain delay().
void moveToAndSettle(float deg) {
    commandedDeg = deg;
    servo.writeDeg(deg); // also sends one frame immediately
    uint32_t settleStartMs = millis();
    while (millis() - settleStartMs < SETTLE_MS) {
        delay(sbusUpdateIntervalMs);
        servo.retransmit();
    }
}

// Drives the servo from positionAt(t_s) and logs (t, target, encoder)
// samples at sampleHz until durationS elapses or the buffer fills.
// Also re-sends the last SBUS frame on its own periodic cadence whenever
// sampleHz is slower than sbusUpdateIntervalMs, so the servo doesn't see
// gaps long enough to trip a signal-loss failsafe.
template <typename PosFunc>
uint16_t runCapture(PosFunc positionAt, float durationS, float sampleHz) {
    sampleCount = 0;
    uint32_t sampleIntervalUs = (uint32_t)(1000000.0f / sampleHz);
    uint32_t sbusIntervalUs = sbusUpdateIntervalMs * 1000UL;
    uint32_t durationUs = (uint32_t)(durationS * 1000000.0f);
    uint32_t t0 = micros();
    uint32_t lastSampleUs = t0 - sampleIntervalUs; // force an immediate first sample
    uint32_t lastSbusTxUs = t0;

    while (true) {
        uint32_t now = micros();
        uint32_t elapsedUs = now - t0;
        if (elapsedUs >= durationUs) break;
        if (sampleCount >= MAX_SAMPLES) break;

        if (now - lastSampleUs >= sampleIntervalUs) {
            lastSampleUs = now;
            lastSbusTxUs = now;
            float t_s = elapsedUs / 1000000.0f;
            float target = positionAt(t_s);

            servo.writeDeg(target); // also sends the SBUS frame
            encoder.update();
            float enc = encoder.getDegrees();

            sampleBuf[sampleCount].tUs = elapsedUs;
            sampleBuf[sampleCount].targetDeg = target;
            sampleBuf[sampleCount].encoderDeg = enc;
            sampleCount++;
        } else if (now - lastSbusTxUs >= sbusIntervalUs) {
            lastSbusTxUs = now;
            servo.retransmit();
        }
    }
    return sampleCount;
}

// ---------------- SCPI command handlers ----------------

void Identify(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    interface.println(F("Bristol FARG,SbusServoCalibration,1,0.1"));
}

void SetPos(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    if (parameters.Size() < 1) {
        interface.println(F("ERR missing degrees"));
        return;
    }
    commandedDeg = String(parameters[0]).toFloat();
    if (enabled) servo.writeDeg(commandedDeg);
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
    if (enabled) servo.writeDeg(commandedDeg); // apply immediately, don't wait for the next POS
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
// file.
void SetConfig(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    String json = interface.readStringUntil('\n');
    json.trim();

    JsonDocument doc;
    if (deserializeJson(doc, json)) {
        interface.println(F("ERR bad JSON"));
        return;
    }

    int16_t chMin = doc["chMin"] | servo.chMin();
    int16_t chMax = doc["chMax"] | servo.chMax();
    bool fast = doc["fast"] | servo.fast();
    float updateHz = doc["updateHz"] | (1000.0f / sbusUpdateIntervalMs);
    bool broadcast = doc["broadcast"] | servo.broadcastAll();
    uint8_t channel = doc["channel"] | servo.channel();

    if (chMax <= chMin) {
        interface.println(F("ERR chMax must be > chMin"));
        return;
    }
    if (updateHz <= 0.0f) {
        interface.println(F("ERR updateHz must be > 0"));
        return;
    }
    if (channel > 15) {
        interface.println(F("ERR channel must be 0-15"));
        return;
    }

    servo.setChannelRange(chMin, chMax);
    servo.setFast(fast);
    servo.setBroadcastAll(broadcast);
    servo.setChannel(channel);
    sbusUpdateIntervalMs = (uint32_t)constrain(1000.0f / updateHz, 1.0f, 1000.0f);
    if (enabled) servo.writeDeg(commandedDeg); // re-apply under the new range/baud/channel

    interface.println(F("OK"));
}

void GetConfig(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    JsonDocument doc;
    doc["chMin"] = servo.chMin();
    doc["chMax"] = servo.chMax();
    doc["fast"] = servo.fast();
    doc["updateHz"] = 1000.0f / sbusUpdateIntervalMs;
    doc["broadcast"] = servo.broadcastAll();
    doc["channel"] = servo.channel();
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

    // A fixed-frequency sine is just a chirp with f0==f1 -- see LinearChirp.h.
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

    Serial.println(F("[boot] calling servo.begin()..."));
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
