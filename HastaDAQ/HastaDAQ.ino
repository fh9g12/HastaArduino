// HastaDAQ.ino
//
// Flight-test SCPI instrument: 5 SBUS control surfaces, an MT6835
// pitch encoder for closed-loop trim-hold, 2x
// ADS122C04 half-bridge strain-gauge ADCs, and an ICM20649 IMU -- all on
// one Pico Plus 2 (+ RM2 breakout), controlled and logged over WiFi/SCPI.
//
// This file is deliberately just the assembly/SCPI layer -- each real
// piece of logic lives in its own header, read THAT file for the detail:
//   - ChannelMixer.h   -- servo names/SBUS channel IDs (edit CHANNEL_DEFS
//                         there, that's the one place), per-channel trim/
//                         excitation-gain/control-gain mixing, SBUS output.
//   - Sensors.h        -- encoder + both ADS122C04s (confirmed half-bridge
//                         config) + ICM20649, all cached/refreshed non-blocking.
//   - CaptureManager.h -- HastaDaqSample struct (the DATA?/UDP wire
//                         format), bounded-capture state machine, and
//                         continuous UDP streaming.
//   - ExcitationGenerator.h (HastaDrivers) -- sine/cosine/chirp generator
//                         with the armed/active split that makes a
//                         delayed, trigger-synchronised start possible.
//   - PidController.h (HastaDrivers) -- the elevator control loop.
//   - TriggerIO.h (HastaDrivers) -- external trigger-in / trigger-out pins.
//
// ---------------------------------------------------------------------
// SIGNAL FLOW -- every servo channel, every SBUS frame:
//
//   commandedDeg[ch] = trimDeg[ch]
//                    + excGain[ch]  * excitationValue(t)
//                    + ctrlGain[ch] * controlOutput
//
// One shared excitation waveform and one shared PID loop (error =
// encoder angle - target), each mixed in per-channel by a gain in
// [-1, +1] -- 0 excludes a channel, matched signs give symmetric
// excitation, opposite signs differential. This is why "trim to an
// angle, then chirp the elevator" is one continuous action: the PID's
// target IS the trim angle, and the chirp rides on top of whatever it's
// already holding.
//
// The control loop runs every loop() iteration using its own real
// elapsed dt (PidController::update(measurement) tracks this
// internally) -- no separate configurable rate. Tune response purely via
// Kp/Ki/Kd.
//
// ---------------------------------------------------------------------
// TRIGGERING -- ARM vs RUN vs FIRE vs the external trigger pin
//
// RUN = ARM (configure a bounded capture: durationS/sampleHz) followed
// immediately by an internal trigger. ARM configures the SAME capture
// but waits for a trigger instead -- either SCPI FIRE or a real edge on
// the trigger-in pin -- for synchronising with other equipment.
//
// Every trigger, from any source, pulses the trigger-out pin AND (if
// EXCITE has armed the waveform -- see ExcitationGenerator.h) starts the
// excitation, delayed by EXCITE's delayS if set: e.g. "log a few
// seconds of quiet baseline after the trigger, then chirp" is
// {"durationS":10,...} on ARM plus {"delayS":3,...,"armed":true} on
// EXCITE. If EXCITE was never armed, a trigger just starts a "static"
// capture (sensors logged, no forced surface motion).
//
// The control loop and SBUS output keep running continuously throughout
// -- capturing/triggering NEVER blocks them (see architecture note).
//
// ---------------------------------------------------------------------
// ARCHITECTURE NOTE -- unlike every earlier rig in this repo (see
// README.md), this sketch is fully non-blocking/event-driven: loop()
// services SCPI, polls the trigger pin, refreshes sensors, advances
// excitation/control/capture/UDP state, and refreshes SBUS every
// iteration, unconditionally. RUN/ARM/FIRE just flip state a state
// machine acts on -- required here because SBUS output and the control
// loop are flying real control surfaces and must never stop, even
// mid-capture.
//
// ---------------------------------------------------------------------
// Wire protocol -- newline-terminated ASCII SCPI over TCP port 5025.
// JSON-bodied commands read their payload as a SECOND raw line (see any
// other rig's header comment in this repo for the two-line-JSON
// rationale). Setters apply only the JSON fields you send, keeping
// everything else at its current value.
//
//   *IDN?
//   CHANCONFIG     -> JSON: {"channel":0-4 OR a name from CHANNEL_DEFS
//                     (e.g. "ELEV_L"), "excGain":-1..1,"ctrlGain":-1..1,
//                     "trimDeg":..,"chMin":..,"chMax":..}
//   CHANCONFIG? <ch or name> -> JSON reply with that channel's config
//   EXCITE         -> JSON: {"type":"sine"|"cosine"|"chirp","freqHz":..
//                     (sine),"f0":..,"f1":.. (chirp),"periodS":..
//                     (cosine/chirp),"amplitudeDeg":..,"cycles":.. (0 =
//                     run until disarmed),"delayS":.. (wait this long
//                     after a trigger before actually starting),
//                     "armed":true|false (should the NEXT trigger start
//                     this -- see TRIGGERING above, NOT "is it running
//                     right now", that's EXCITE?'s read-only "active")}
//   EXCITE?        -> JSON reply (includes read-only "active")
//   CTRLCONFIG     -> JSON: {"kp":..,"ki":..,"kd":..,"targetDeg":..,
//                     "outLimitDeg":..,"enabled":true|false}
//   CTRLCONFIG?    -> JSON reply
//   RUN            -> JSON: {"durationS":..,"sampleHz":..} -- ARM then
//                     immediately trigger. Non-blocking -- replies "OK"
//                     right away, poll STATUS?/DATA? for the result.
//   ARM            -> same JSON as RUN, waits for a trigger instead.
//   FIRE           -> software trigger (no params).
//   STATUS?        -> "ARMED" | "CAPTURING <elapsedS>/<durationS>" |
//                     "DONE <n_samples>"
//   DATA?          -> binary dump of the last completed capture: one
//                     ASCII header line "BIN <n> <bytes>", then n*bytes
//                     raw HastaDaqSample records (see CaptureManager.h),
//                     little-endian.
//   ENCODER?       -> current encoder angle in degrees, plain number
//                     (latest cached reading, no capture needed).
//   ZERO           -> software-zero the encoder at its current position
//                     (RAM only, lost on reboot). Refused with ERR while
//                     the control loop is enabled.
//   TRIGCONFIG     -> JSON: {"outPulseMs":..,"inEdge":"rising"|"falling"}
//   TRIGCONFIG?    -> JSON reply
//   UDPCONFIG      -> JSON: {"ip":"a.b.c.d","port":..,"rateHz":..,
//                     "enabled":true|false} -- continuous streaming,
//                     independent of RUN/ARM/DATA?, same per-sample
//                     binary layout as DATA? (tUs is time-since-boot).
//   UDPCONFIG?     -> JSON reply
//
// ---------------------------------------------------------------------
// Hardware: see wiring/hastadaq-rig.yml for the full wiring diagram.
//   - MT6835 encoder: SPI1 on GPIO10/11/12/13 (see Sensors.h).
//   - SBUS: TX/RX on GPIO20/21 (see ChannelMixer.h).
//   - I2C/Qwiic (IMU + both ADS122C04s, daisy-chained): default Wire
//     pins. Second ADS122C04's address is UNCONFIRMED -- Sensors.h
//     falls back to a boot-time I2C scan if it doesn't answer at the
//     guessed 0x41 (see that file for why the address isn't confirmed).
//   - Trigger IN: GPIO14. Trigger OUT: GPIO15.
//   - WiFi: Pimoroni RM2 breakout on SP/CE, same CYW43 pin
//     fix as every other rig in this repo.

#include <Adafruit_ADS122C04.h>
#include <WiFi.h>
#include <pico/cyw43_driver.h>
#include <math.h>

#define VREKRER_SCPI_PARSER_NO_IMPL
// Widen both the hash AND the command-count ceiling from the library's
// defaults (uint8_t hash / 20 commands) -- this sketch registers ~16
// commands, and EncoderCalibration.ino hit a REAL silent-hash-collision
// bug at just 13 with the default 8-bit hash (see README.md).
#define SCPI_HASH_TYPE uint16_t
#define SCPI_MAX_COMMANDS 32
#include <Vrekrer_scpi_parser.h>
#include <ArduinoJson.h>
#include <ExcitationGenerator.h>
#include <PidController.h>
#include <TriggerIO.h>
#include "ChannelMixer.h"
#include "Sensors.h"
#include "CaptureManager.h"
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

const uint8_t TRIGGER_IN_PIN = 14;
const uint8_t TRIGGER_OUT_PIN = 15;

SensorHub sensors;
ChannelMixer channelMixer;
ExcitationGenerator exciter;
PidController elevatorPid;
CaptureManager capture;
UdpStreamer udpStreamer;
TriggerIO triggerIO;

bool ctrlEnabled = false;

HastaDaqSample buildLiveSample(float excitationValue, float controlOutputDeg) {
    HastaDaqSample s;
    s.tUs = 0; // overwritten by CaptureManager/UdpStreamer, whichever consumes it
    s.adc1Mv = sensors.adc1Mv();
    s.adc2Mv = sensors.adc2Mv();
    s.encoderDeg = sensors.encoderDeg();
    s.accelX = sensors.accelX(); s.accelY = sensors.accelY(); s.accelZ = sensors.accelZ();
    s.gyroX = sensors.gyroX(); s.gyroY = sensors.gyroY(); s.gyroZ = sensors.gyroZ();
    s.excitationDeg = excitationValue;
    s.controlOutputDeg = controlOutputDeg;
    for (uint8_t i = 0; i < NUM_CHANNELS; i++) s.servoDeg[i] = channelMixer.lastCommandedDeg(i);
    return s;
}

// The single "go" event -- SCPI RUN, SCPI FIRE, and the external trigger
// pin all funnel through here. Returns false if nothing was armed.
bool doTrigger() {
    if (!capture.fire()) return false;
    uint32_t nowUs = micros();
    triggerIO.pulseOut();
    exciter.triggerStart(nowUs); // no-op if EXCITE hasn't armed it -- see ExcitationGenerator.h
    return true;
}

// ---------------- SCPI command handlers ----------------

void Identify(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    interface.println(F("Bristol FARG,HastaDAQ,1,0.1"));
}

// Accepts either a numeric channel index or one of CHANNEL_DEFS' names
// (e.g. "ELEV_L") -- see ChannelMixer.h. Returns -1 if neither resolves.
int resolveChannelIndex(JsonVariantConst v) {
    if (v.isNull()) return -1;
    if (v.is<const char*>()) return channelMixer.channelIndexByName(String(v.as<const char*>()));
    return v.as<int>();
}

void SetChanConfig(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    String json = interface.readStringUntil('\n');
    json.trim();

    JsonDocument doc;
    if (deserializeJson(doc, json)) {
        interface.println(F("ERR bad JSON"));
        return;
    }

    int ch = resolveChannelIndex(doc["channel"]);
    if (ch < 0 || ch >= NUM_CHANNELS) {
        interface.println(F("ERR unknown channel (index 0-4 or a CHANNEL_DEFS name)"));
        return;
    }

    channelMixer.setExcGain(ch, doc["excGain"] | channelMixer.excGain(ch));
    channelMixer.setCtrlGain(ch, doc["ctrlGain"] | channelMixer.ctrlGain(ch));
    channelMixer.setTrimDeg(ch, doc["trimDeg"] | channelMixer.trimDeg(ch));
    int16_t chMin = doc["chMin"] | channelMixer.chMin(ch);
    int16_t chMax = doc["chMax"] | channelMixer.chMax(ch);
    if (chMax <= chMin) {
        interface.println(F("ERR chMax must be > chMin"));
        return;
    }
    channelMixer.setChannelRange(ch, chMin, chMax); // clamped to 64..1984 (920..2120 us)

    interface.println(F("OK"));
}

void GetChanConfig(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    if (parameters.Size() < 1) {
        interface.println(F("ERR missing channel"));
        return;
    }
    String param = String(parameters[0]);
    int ch = param.toInt();
    if (ch == 0 && param != "0") ch = channelMixer.channelIndexByName(param);
    if (ch < 0 || ch >= NUM_CHANNELS) {
        interface.println(F("ERR unknown channel (index 0-4 or a CHANNEL_DEFS name)"));
        return;
    }

    JsonDocument doc;
    doc["channel"] = ch;
    doc["name"] = CHANNEL_DEFS[ch].name;
    doc["excGain"] = channelMixer.excGain(ch);
    doc["ctrlGain"] = channelMixer.ctrlGain(ch);
    doc["trimDeg"] = channelMixer.trimDeg(ch);
    doc["chMin"] = channelMixer.chMin(ch);
    doc["chMax"] = channelMixer.chMax(ch);
    serializeJson(doc, interface);
    interface.println();
}

void SetExcite(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    String json = interface.readStringUntil('\n');
    json.trim();

    JsonDocument doc;
    if (deserializeJson(doc, json)) {
        interface.println(F("ERR bad JSON"));
        return;
    }

    const char* typeCstr = doc["type"] | (exciter.type() == ExcitationGenerator::Type::SINE ? "sine"
                                           : exciter.type() == ExcitationGenerator::Type::COSINE ? "cosine" : "chirp");
    String type(typeCstr);
    if (type == "sine") exciter.setType(ExcitationGenerator::Type::SINE);
    else if (type == "cosine") exciter.setType(ExcitationGenerator::Type::COSINE);
    else if (type == "chirp") exciter.setType(ExcitationGenerator::Type::CHIRP);
    else {
        interface.println(F("ERR type must be sine|cosine|chirp"));
        return;
    }

    exciter.setFreqHz(doc["freqHz"] | exciter.freqHz());
    exciter.setChirpRange(doc["f0"] | exciter.f0(), doc["f1"] | exciter.f1());
    exciter.setPeriodS(doc["periodS"] | exciter.periodS());
    exciter.setAmplitudeDeg(doc["amplitudeDeg"] | exciter.amplitudeDeg());
    exciter.setCycles(doc["cycles"] | exciter.cycles());
    exciter.setDelayS(doc["delayS"] | exciter.delayS());
    exciter.setArmed(doc["armed"] | exciter.armed());

    interface.println(F("OK"));
}

void GetExcite(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    JsonDocument doc;
    doc["type"] = exciter.type() == ExcitationGenerator::Type::SINE ? "sine"
                : exciter.type() == ExcitationGenerator::Type::COSINE ? "cosine" : "chirp";
    doc["freqHz"] = exciter.freqHz();
    doc["f0"] = exciter.f0();
    doc["f1"] = exciter.f1();
    doc["periodS"] = exciter.periodS();
    doc["amplitudeDeg"] = exciter.amplitudeDeg();
    doc["cycles"] = exciter.cycles();
    doc["delayS"] = exciter.delayS();
    doc["armed"] = exciter.armed();
    doc["active"] = exciter.active(); // read-only -- is it actually oscillating right now
    serializeJson(doc, interface);
    interface.println();
}

void SetCtrlConfig(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    String json = interface.readStringUntil('\n');
    json.trim();

    JsonDocument doc;
    if (deserializeJson(doc, json)) {
        interface.println(F("ERR bad JSON"));
        return;
    }

    float kp = doc["kp"] | elevatorPid.kp();
    float ki = doc["ki"] | elevatorPid.ki();
    float kd = doc["kd"] | elevatorPid.kd();
    elevatorPid.setGains(kp, ki, kd);
    elevatorPid.setTarget(doc["targetDeg"] | elevatorPid.target());
    elevatorPid.setOutputLimit(doc["outLimitDeg"] | elevatorPid.outputLimit());

    bool enable = doc["enabled"] | ctrlEnabled;
    if (enable && !ctrlEnabled) elevatorPid.reset(); // clear stale integral/dt on the off->on transition
    ctrlEnabled = enable;

    interface.println(F("OK"));
}

void GetCtrlConfig(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    JsonDocument doc;
    doc["kp"] = elevatorPid.kp();
    doc["ki"] = elevatorPid.ki();
    doc["kd"] = elevatorPid.kd();
    doc["targetDeg"] = elevatorPid.target();
    doc["outLimitDeg"] = elevatorPid.outputLimit();
    doc["enabled"] = ctrlEnabled;
    serializeJson(doc, interface);
    interface.println();
}

void RunCapture(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    String json = interface.readStringUntil('\n');
    json.trim();

    JsonDocument doc;
    if (deserializeJson(doc, json)) {
        interface.println(F("ERR bad JSON"));
        return;
    }

    float durationS = doc["durationS"] | 10.0f;
    float sampleHz = doc["sampleHz"] | 100.0f;
    if (!capture.arm(durationS, sampleHz)) {
        interface.println(F("ERR durationS/sampleHz out of range"));
        return;
    }
    doTrigger();
    interface.println(F("OK"));
}

void ArmCaptureCmd(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    String json = interface.readStringUntil('\n');
    json.trim();

    JsonDocument doc;
    if (deserializeJson(doc, json)) {
        interface.println(F("ERR bad JSON"));
        return;
    }

    float durationS = doc["durationS"] | 10.0f;
    float sampleHz = doc["sampleHz"] | 100.0f;
    if (!capture.arm(durationS, sampleHz)) {
        interface.println(F("ERR durationS/sampleHz out of range"));
        return;
    }
    interface.println(F("OK"));
}

void FireCmd(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    if (doTrigger()) interface.println(F("OK"));
    else interface.println(F("ERR nothing armed -- send ARM first"));
}

void GetStatus(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    switch (capture.state()) {
        case CaptureManager::State::ARMED:
            interface.println(F("ARMED"));
            break;
        case CaptureManager::State::CAPTURING:
            interface.print(F("CAPTURING "));
            interface.print(capture.elapsedS(), 2);
            interface.print('/');
            interface.println(capture.durationS(), 2);
            break;
        case CaptureManager::State::IDLE:
        default:
            interface.print(F("DONE "));
            interface.println(capture.sampleCount());
            break;
    }
}

void GetData(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    interface.print(F("BIN "));
    interface.print(capture.sampleCount());
    interface.print(' ');
    interface.println(sizeof(HastaDaqSample));
    interface.write(reinterpret_cast<const uint8_t*>(capture.buffer()), (size_t)capture.sampleCount() * sizeof(HastaDaqSample));
}

// Latest cached encoder angle (refreshed every loop() by sensors.update()),
// so this never blocks or touches the SPI bus itself.
void GetEncoder(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    interface.println(sensors.encoderDeg(), 3);
}

// Software zero only (RAM offset, lost on reboot). Zeroing under an
// enabled control loop would step the PID's error by the old angle, so
// refuse -- the caller must disable control first.
void ZeroEncoderCmd(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    if (ctrlEnabled) {
        interface.println(F("ERR control loop enabled -- CTRLCONFIG enabled:false first"));
        return;
    }
    sensors.zeroEncoder();
    interface.println(F("OK"));
}

void SetTrigConfig(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    String json = interface.readStringUntil('\n');
    json.trim();

    JsonDocument doc;
    if (deserializeJson(doc, json)) {
        interface.println(F("ERR bad JSON"));
        return;
    }

    triggerIO.setOutPulseMs(doc["outPulseMs"] | triggerIO.outPulseMs());

    const char* edgeCstr = doc["inEdge"] | (triggerIO.inEdge() == RISING ? "rising" : "falling");
    String edge(edgeCstr);
    triggerIO.setInEdge(edge == "falling" ? FALLING : RISING);

    interface.println(F("OK"));
}

void GetTrigConfig(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    JsonDocument doc;
    doc["outPulseMs"] = triggerIO.outPulseMs();
    doc["inEdge"] = (triggerIO.inEdge() == RISING) ? "rising" : "falling";
    serializeJson(doc, interface);
    interface.println();
}

void SetUdpConfig(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    String json = interface.readStringUntil('\n');
    json.trim();

    JsonDocument doc;
    if (deserializeJson(doc, json)) {
        interface.println(F("ERR bad JSON"));
        return;
    }

    IPAddress ip = udpStreamer.ip();
    if (doc["ip"].is<const char*>()) {
        if (!ip.fromString(doc["ip"].as<const char*>())) {
            interface.println(F("ERR bad ip"));
            return;
        }
    }
    uint16_t port = doc["port"] | udpStreamer.port();
    udpStreamer.configureDest(ip, port);
    udpStreamer.setRateHz(doc["rateHz"] | udpStreamer.rateHz());
    udpStreamer.setEnabled(doc["enabled"] | udpStreamer.enabled());

    interface.println(F("OK"));
}

void GetUdpConfig(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    JsonDocument doc;
    doc["ip"] = udpStreamer.ip().toString();
    doc["port"] = udpStreamer.port();
    doc["rateHz"] = udpStreamer.rateHz();
    doc["enabled"] = udpStreamer.enabled();
    serializeJson(doc, interface);
    interface.println();
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
    uint32_t serialWaitStartMs = millis();
    while (!Serial && millis() - serialWaitStartMs < 3000) { delay(10); } // bounded -- see other .ino files in this repo for why

    Wire.begin();
    sensors.begin();
    channelMixer.begin();
    channelMixer.applyDefaults();
    triggerIO.begin(TRIGGER_IN_PIN, TRIGGER_OUT_PIN);

    connectWiFi();

    scpi.RegisterCommand("*IDN?", &Identify);
    scpi.RegisterCommand("CHANCONFIG", &SetChanConfig);
    scpi.RegisterCommand("CHANCONFIG?", &GetChanConfig);
    scpi.RegisterCommand("EXCITE", &SetExcite);
    scpi.RegisterCommand("EXCITE?", &GetExcite);
    scpi.RegisterCommand("CTRLCONFIG", &SetCtrlConfig);
    scpi.RegisterCommand("CTRLCONFIG?", &GetCtrlConfig);
    scpi.RegisterCommand("RUN", &RunCapture);
    scpi.RegisterCommand("ARM", &ArmCaptureCmd);
    scpi.RegisterCommand("FIRE", &FireCmd);
    scpi.RegisterCommand("STATUS?", &GetStatus);
    scpi.RegisterCommand("DATA?", &GetData);
    scpi.RegisterCommand("ENCODER?", &GetEncoder);
    scpi.RegisterCommand("ZERO", &ZeroEncoderCmd);
    scpi.RegisterCommand("TRIGCONFIG", &SetTrigConfig);
    scpi.RegisterCommand("TRIGCONFIG?", &GetTrigConfig);
    scpi.RegisterCommand("UDPCONFIG", &SetUdpConfig);
    scpi.RegisterCommand("UDPCONFIG?", &GetUdpConfig);

    scpiServer.begin();
    Serial.print(F("[SCPI] Listening on port ")); Serial.println(SCPI_PORT);
}

void loop() {
    // SCPI service -- never blocks (see architecture note at top of file).
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

    if (triggerIO.pollPending()) doTrigger();

    sensors.update();

    uint32_t nowUs = micros();
    float excitationValue = exciter.update(nowUs);
    float controlOutputDeg = ctrlEnabled ? elevatorPid.update(sensors.encoderDeg()) : 0.0f;
    channelMixer.update(excitationValue, controlOutputDeg);

    HastaDaqSample live = buildLiveSample(excitationValue, controlOutputDeg);
    capture.updateCapture(live);
    udpStreamer.update(live);
    triggerIO.update();
}
