// HastaDAQ_v2.ino
//
// HastaDAQ v2 -- firmware for the REV A main board (kicad/hastadaq/) plus its
// strain-gauge board (kicad/gaugeboard/); see docs/README.md.
// Flight-test SCPI instrument: 5 SBUS control surfaces, up to four SPI
// encoders (MT6835 / RLS Orbis) with ENC1 as the pitch encoder for
// closed-loop trim-hold, 2x ADS122C04 half-bridge strain-gauge ADCs, and an
// ICM20649 IMU -- all on one Pico Plus 2 (+ RM2 breakout), controlled and
// logged over WiFi/SCPI.
//
// This is a COPY of HastaDAQ/HastaDAQ.ino, kept as its own project so the
// original board and firmware stay untouched. DIFFERENCES FROM v1:
//   - Four SPI encoder ports ENC1..ENC4 on one shared SPI1 bus, each an
//     MT6835, an RLS Orbis, or empty (EncoderPorts.h; ENCCONFIG, ENCODERS?).
//     ENC1 is still the control encoder.
//   - Soft-stop input (SoftStop.h): a normally-closed loop to GND. Loop open
//     or cable cut = STOP = the excitation is halted and disarmed (trim and
//     control keep running). SOFTSTOP?, SOFTSTOPCONFIG, and ABORT for the
//     same thing from software.
//   - Trigger lines go through an opto input (GP14) and an open-collector
//     output (GP15), both inverting; TriggerIO does the inversion, so
//     TRIGCONFIG and the pulse polarity still mean what the CABLE does.
//   - DATA?/UDP samples gain three appended floats (ENC2..ENC4 angles, NaN
//     if not fitted): 80 bytes per sample with 5 channels, vs 68.
//   - *IDN? reports HastaDAQ-v2.
//   NOT compiled-for-hardware-tested yet: the Orbis SPI mode, the soft-stop
//   and the inverted trigger paths need a bench check on the new board.
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
// docs/README.md), this sketch is fully non-blocking/event-driven: loop()
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
//                     or an ARRAY of those objects: all are validated, then
//                     applied together (surfaces move in the same SBUS
//                     frame). Use the array form to move surfaces in sync.
//   CHANCONFIG? <ch or name> -> JSON reply with that channel's config
//   EXCITE         -> JSON: {"type":"sine"|"cosine"|"chirp"|"step"|"random"|"stepseq","freqHz":..
//                     (sine),"f0":..,"f1":.. (chirp),"periodS":..
//                     (cosine/chirp),"amplitudeDeg":..,"cycles":.. (0 =
//                     run until disarmed),"delayS":.. (wait this long
//                     after a trigger before actually starting). "cosine"
//                     is the 1-cosine pulse (0 -> amplitudeDeg -> 0 over
//                     periodS); "step" holds amplitudeDeg from delayS until
//                     disarmed (periodS and cycles are ignored), so a step
//                     test is timed on the board, not by a host command.
//                     "random" plays back durationS seconds of the stored
//                     von Karman turbulence record from startOffsetS,
//                     scaled by amplitudeDeg and tapered at both ends
//                     (startOffsetS + durationS must fit the record, 59.98 s,
//                     else ERR). "stepseq" is -amplitudeDeg for delayS (move
//                     there and settle), then alternating +/-amplitudeDeg
//                     for dwells[i]*periodS each ("dwells":[3,2,1,1], up to
//                     16), then back to 0 -- the stepped chirp,
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
//   ENCODER? [port] -> encoder angle in degrees, plain number (latest
//                     cached reading, no capture needed). port is 1-4
//                     (ENC1..ENC4), default 1; "nan" if that port is empty.
//   ENCODERS?      -> JSON: {"ports":[{"port":1,"type":"mt6835","valid":true,
//                     "deg":..,"warning":false,"fails":0},...]}
//   ENCCONFIG      -> JSON: {"port":1-4,"type":"none"|"mt6835"|"orbis"|
//                     "orbis_mt"} -- what is plugged into a port ("orbis_mt"
//                     = multi-turn part). ENC1 cannot be changed while the
//                     control loop is enabled. The boot default is
//                     ENC_DEFAULT_TYPES in EncoderPorts.h.
//   ZERO [port]    -> software-zero that encoder at its current position
//                     (RAM only, lost on reboot). Refused with ERR for ENC1
//                     while the control loop is enabled.
//   ZEROOFFSET? [port] -> the raw (absolute, 0-360 deg) angle that reads as
//                     0 right now. Read it once after ZERO and save it.
//   ZEROOFFSET <deg>[,<port>] -> re-apply a saved zero instead of re-zeroing
//                     (valid while the encoder hasn't moved; same ERR rule).
//   SOFTSTOP?      -> JSON: {"enabled":..,"stopped":..,"pinHigh":..,
//                     "stopCount":..} -- stopped = the loop is open (or the
//                     input is still settling after boot) and enabled.
//   SOFTSTOPCONFIG -> JSON: {"enabled":true|false} -- false is a bench mode
//                     for a rig with no stop loop fitted (input ignored).
//   ABORT          -> halt and disarm the excitation now (same effect as the
//                     soft-stop). Control loop, SBUS and captures keep running.
//   SYS?           -> JSON link health: {"uptimeS","resetReason","wifiConnected",
//                     "rssi","freeHeap","connects","disconnects","wifiDrops",
//                     "maxLoopMs"} -- maxLoopMs is the longest loop() since
//                     the last SYS?. A new SCPI connection always replaces
//                     the current one; each is given TCP keepalive.
//   TRIGCONFIG     -> JSON: {"outPulseMs":..,"inEdge":"rising"|"falling"}
//                     -- inEdge and the output pulse are the CABLE signal
//                     (rising = cable goes high); the board's inversion is
//                     handled in TriggerIO.
//   TRIGCONFIG?    -> JSON reply
//   UDPCONFIG      -> JSON: {"ip":"a.b.c.d","port":..,"rateHz":..,
//                     "enabled":true|false} -- continuous streaming,
//                     independent of RUN/ARM/DATA?, same per-sample
//                     binary layout as DATA? (tUs is time-since-boot).
//   UDPCONFIG?     -> JSON reply
//
// ---------------------------------------------------------------------
// Hardware: REV A boards, see kicad/hastadaq/ + kicad/gaugeboard/ (schematics) and docs/README.md.
//   - Encoder ports ENC1..ENC4: SPI1 SCK GP10, MOSI GP11, MISO GP12, CS
//     GP13 / GP9 / GP8 / GP7 (see EncoderPorts.h).
//   - SBUS: TX/RX on GPIO20/21 (see ChannelMixer.h).
//   - I2C0 (GP4/GP5, default Wire pins) goes to the IMU header and to a
//     4-wire loom (GND, +5V, SDA, SCL) to the separate strain-gauge board,
//     which holds both ADS122C04s on its own 3.3 V regulator (the ADS
//     breakouts supply the pull-ups). Second ADS122C04's address is UNCONFIRMED -- Sensors.h
//     falls back to a boot-time I2C scan if it doesn't answer at the
//     guessed 0x41.
//   - Trigger IN: GP14 (opto, board pulls it up, falls when the cable goes
//     high). Trigger OUT: GP15 (open-collector NPN, GPIO high = line low).
//   - SBUS IN: GP1 (UART0 RX, Serial1) from an RC receiver, for a pass-through
//     mode. The pin and the board are ready; the pass-through firmware itself is
//     NOT written yet (SBUS is 100 kbaud 8E2, inverted: Serial1.setInvertRX(true)).
//   - Soft stop: GP16 (closed loop = low = run; external 10k pull-up to 3V3
//     and a 5.1 V zener on the board).
//   - WiFi: Pimoroni RM2 breakout on SP/CE (GP32-GP36), same CYW43 pin
//     fix as every other rig in this repo. A Pico 2 W also works: build with
//     -DHASTADAQ_ONBOARD_WIFI (see the WiFi radio note below).

#include <Adafruit_ADS122C04.h>
#include <WiFi.h>
#include <pico/cyw43_driver.h>
#include <math.h>

#define VREKRER_SCPI_PARSER_NO_IMPL
// Widen both the hash AND the command-count ceiling from the library's
// defaults (uint8_t hash / 20 commands) -- this sketch registers ~16
// commands, and EncoderCalibration.ino hit a REAL silent-hash-collision
// bug at just 13 with the default 8-bit hash (see docs/README.md).
#define SCPI_HASH_TYPE uint16_t
#define SCPI_MAX_COMMANDS 32
#include <Vrekrer_scpi_parser.h>
#include <ArduinoJson.h>
#include <ExcitationGenerator.h>
#include <PidController.h>
#include <TriggerIO.h>
#include <SoftStop.h>
#include "ChannelMixer.h"
#include "Sensors.h"
#include "CaptureManager.h"
#include "secrets.h"

// --- WiFi radio ---
// Default: Pico Plus 2 with the Pimoroni RM2 breakout cabled to its SP/CE
// connector -- the CYW43 pins must be redirected there (confirmed working on
// the original board). For a Pico 2 W (radio on the board) build with
//   -DHASTADAQ_ONBOARD_WIFI
// and the "Raspberry Pi Pico 2W" board target (rpipico2w): the override is
// compiled out so the core's on-board pin defaults apply. Nothing else in this
// sketch is board-specific (every GPIO used is a plain header GPIO on both).
#ifndef HASTADAQ_ONBOARD_WIFI
uint CYW43_PINS_SPCE[CYW43_PIN_INDEX_WL_COUNT] = {
    32, // REG_ON
    35, // DATA_OUT
    35, // DATA_IN
    35, // HOST_WAKE
    34, // CLOCK
    33, // CS
};
#endif

const uint16_t SCPI_PORT = 5025;
WiFiServer scpiServer(SCPI_PORT);
WiFiClient scpiClient;

SCPI_Parser scpi;

const uint8_t TRIGGER_IN_PIN = 14;
const uint8_t TRIGGER_OUT_PIN = 15;
const uint8_t SOFTSTOP_PIN = 16;

SensorHub sensors;
ChannelMixer channelMixer;
ExcitationGenerator exciter;
PidController elevatorPid;
CaptureManager capture;
UdpStreamer udpStreamer;
TriggerIO triggerIO;
SoftStop softStop;

bool ctrlEnabled = false;

// ---- link diagnostics, reported by SYS? and the Serial log ----
uint32_t connectCount = 0;      // SCPI clients accepted
uint32_t disconnectCount = 0;   // ... and lost or replaced
uint32_t wifiDrops = 0;         // times the WiFi link was seen to go down
uint32_t maxLoopUs = 0;         // longest loop() since SYS? was last read
bool clientWasConnected = false;
const char* resetReasonName = "unknown";

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
    for (uint8_t k = 0; k < NUM_EXTRA_ENCODERS; k++) s.encExtraDeg[k] = sensors.encoderDegPort(k + 1); // ENC2..ENC4
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
    interface.println(F("Bristol FARG,HastaDAQ-v2,2,0.1"));
}

// Accepts either a numeric channel index or one of CHANNEL_DEFS' names
// (e.g. "ELEV_L") -- see ChannelMixer.h. Returns -1 if neither resolves.
int resolveChannelIndex(JsonVariantConst v) {
    if (v.isNull()) return -1;
    if (v.is<const char*>()) return channelMixer.channelIndexByName(String(v.as<const char*>()));
    return v.as<int>();
}

// (ChanUpdate lives in ChannelMixer.h: Arduino generates function prototypes
// above any struct defined in the .ino itself, which breaks signatures using it.)

// Parses one channel object into an update (fields not given keep the
// channel's current value). Returns an error message, or nullptr if OK.
// Nothing is applied here.
const __FlashStringHelper* parseChanUpdate(JsonVariantConst cfg, ChanUpdate& u) {
    int ch = resolveChannelIndex(cfg["channel"]);
    if (ch < 0 || ch >= NUM_CHANNELS) {
        return F("ERR unknown channel (index 0-4 or a CHANNEL_DEFS name)");
    }
    u.ch = ch;
    u.excGain = cfg["excGain"] | channelMixer.excGain(ch);
    u.ctrlGain = cfg["ctrlGain"] | channelMixer.ctrlGain(ch);
    u.trimDeg = cfg["trimDeg"] | channelMixer.trimDeg(ch);
    u.chMin = cfg["chMin"] | channelMixer.chMin(ch);
    u.chMax = cfg["chMax"] | channelMixer.chMax(ch);
    if (u.chMax <= u.chMin) return F("ERR chMax must be > chMin");
    return nullptr;
}

// Takes either ONE channel object or an ARRAY of them. Every entry is
// checked first and then all are applied together, so several surfaces
// start moving in the same SBUS frame (and a bad entry changes nothing).
void SetChanConfig(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    String json = interface.readStringUntil('\n');
    json.trim();

    JsonDocument doc;
    if (deserializeJson(doc, json)) {
        interface.println(F("ERR bad JSON"));
        return;
    }

    ChanUpdate updates[NUM_CHANNELS];
    size_t count = 0;
    if (doc.is<JsonArray>()) {
        for (JsonVariantConst item : doc.as<JsonArrayConst>()) {
            if (count >= NUM_CHANNELS) {
                interface.println(F("ERR too many channels in one CHANCONFIG"));
                return;
            }
            const __FlashStringHelper* err = parseChanUpdate(item, updates[count]);
            if (err) { interface.println(err); return; }
            count++;
        }
    } else {
        const __FlashStringHelper* err = parseChanUpdate(doc.as<JsonVariantConst>(), updates[0]);
        if (err) { interface.println(err); return; }
        count = 1;
    }

    for (size_t i = 0; i < count; i++) {
        const ChanUpdate& u = updates[i];
        channelMixer.setExcGain(u.ch, u.excGain);
        channelMixer.setCtrlGain(u.ch, u.ctrlGain);
        channelMixer.setTrimDeg(u.ch, u.trimDeg);
        channelMixer.setChannelRange(u.ch, u.chMin, u.chMax); // clamped to 64..1984 (920..2120 us)
    }

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

    const char* typeCstr = doc["type"] | exciter.typeName();
    String type(typeCstr);
    ExcitationGenerator::Type newType;
    if (type == "sine") newType = ExcitationGenerator::Type::SINE;
    else if (type == "cosine") newType = ExcitationGenerator::Type::COSINE;
    else if (type == "chirp") newType = ExcitationGenerator::Type::CHIRP;
    else if (type == "step") newType = ExcitationGenerator::Type::STEP;
    else if (type == "random") newType = ExcitationGenerator::Type::RANDOM;
    else if (type == "stepseq") newType = ExcitationGenerator::Type::STEPSEQ;
    else {
        interface.println(F("ERR type must be sine|cosine|chirp|step|random|stepseq"));
        return;
    }

    // everything that can be rejected is checked before anything is applied
    float startOffsetS = doc["startOffsetS"] | exciter.startOffsetS();
    float durationS = doc["durationS"] | exciter.durationS();
    if (newType == ExcitationGenerator::Type::RANDOM && !ExcitationGenerator::randomFits(startOffsetS, durationS)) {
        interface.println(F("ERR random needs startOffsetS >= 0, durationS > 0 and startOffsetS + durationS within the stored record"));
        return;
    }
    float dwells[ExcitationGenerator::MAX_DWELLS];
    int nDwells = -1; // -1 = dwells not given, keep the current ones
    if (doc["dwells"].is<JsonArray>()) {
        JsonArray arr = doc["dwells"].as<JsonArray>();
        nDwells = (int)arr.size();
        if (nDwells < 1 || nDwells > ExcitationGenerator::MAX_DWELLS) {
            interface.println(F("ERR dwells needs 1 to 16 values"));
            return;
        }
        for (int i = 0; i < nDwells; ++i) {
            dwells[i] = arr[i].as<float>();
            if (!(dwells[i] > 0.0f)) {
                interface.println(F("ERR dwells must be positive"));
                return;
            }
        }
    }

    exciter.setType(newType);
    exciter.setStartOffsetS(startOffsetS);
    exciter.setDurationS(durationS);
    if (nDwells > 0) exciter.setDwells(dwells, nDwells);

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
    doc["type"] = exciter.typeName();
    doc["freqHz"] = exciter.freqHz();
    doc["f0"] = exciter.f0();
    doc["f1"] = exciter.f1();
    doc["periodS"] = exciter.periodS();
    doc["amplitudeDeg"] = exciter.amplitudeDeg();
    doc["cycles"] = exciter.cycles();
    doc["delayS"] = exciter.delayS();
    doc["startOffsetS"] = exciter.startOffsetS();
    doc["durationS"] = exciter.durationS();
    JsonArray dw = doc["dwells"].to<JsonArray>();
    for (int i = 0; i < exciter.nDwells(); ++i) dw.add(exciter.dwell(i));
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

// Optional port argument (1-4 = ENC1..ENC4) at parameters[index]; default
// ENC1. Returns the 0-based port, or -1 after printing an ERR.
int parsePortParam(SCPI_P parameters, size_t index, Stream& interface) {
    if ((int)parameters.Size() <= (int)index) return 0;
    int p = String(parameters[index]).toInt();
    if (p < 1 || p > (int)EncoderPorts::NUM_PORTS) {
        interface.println(F("ERR port must be 1-4 (ENC1..ENC4)"));
        return -1;
    }
    return p - 1;
}

// Latest cached encoder angle (refreshed every loop() by sensors.update()),
// so this never blocks or touches the SPI bus itself.
void GetEncoder(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    int port = parsePortParam(parameters, 0, interface);
    if (port < 0) return;
    interface.println(sensors.encoderDegPort(port), 3); // "nan" if the port is empty
}

void GetEncoders(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    const EncoderPorts& ports = sensors.encoderPorts();
    JsonDocument doc;
    JsonArray arr = doc["ports"].to<JsonArray>();
    for (uint8_t i = 0; i < EncoderPorts::NUM_PORTS; i++) {
        JsonObject o = arr.add<JsonObject>();
        o["port"] = i + 1;
        o["type"] = EncoderPorts::typeName(ports.type(i));
        o["valid"] = ports.valid(i);
        if (ports.active(i)) {
            o["deg"] = ports.angleDeg(i);
            o["warning"] = ports.warning(i);
            o["fails"] = ports.failCount(i);
        }
    }
    serializeJson(doc, interface);
    interface.println();
}

void SetEncConfig(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    String json = interface.readStringUntil('\n');
    json.trim();

    JsonDocument doc;
    if (deserializeJson(doc, json)) {
        interface.println(F("ERR bad JSON"));
        return;
    }
    int port = doc["port"] | 0;
    if (port < 1 || port > (int)EncoderPorts::NUM_PORTS) {
        interface.println(F("ERR port must be 1-4 (ENC1..ENC4)"));
        return;
    }
    EncType type;
    if (!EncoderPorts::typeFromName(String(doc["type"] | ""), type)) {
        interface.println(F("ERR type must be none|mt6835|orbis|orbis_mt"));
        return;
    }
    if (port == 1 && ctrlEnabled) {
        interface.println(F("ERR control loop uses ENC1 -- CTRLCONFIG enabled:false first"));
        return;
    }
    if (sensors.encoderPorts().configure(port - 1, type)) interface.println(F("OK"));
    else interface.println(F("ERR configured, but no valid reading yet -- check wiring / part type"));
}

// Software zero only (RAM offset, lost on reboot). Zeroing the CONTROL
// encoder (ENC1) under an enabled control loop would step the PID's error by
// the old angle, so refuse -- the caller must disable control first.
void ZeroEncoderCmd(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    int port = parsePortParam(parameters, 0, interface);
    if (port < 0) return;
    if (port == 0 && ctrlEnabled) {
        interface.println(F("ERR control loop enabled -- CTRLCONFIG enabled:false first"));
        return;
    }
    if (!sensors.encoderPorts().active(port)) {
        interface.println(F("ERR that port has no encoder configured (ENCCONFIG)"));
        return;
    }
    sensors.zeroEncoder(port);
    interface.println(F("OK"));
}

const char* resetReasonToString(RP2040::resetReason_t reason) {
    switch (reason) {
        case RP2040::PWRON_RESET:    return "power-on";
        case RP2040::RUN_PIN_RESET:  return "run-pin";
        case RP2040::SOFT_RESET:     return "soft";
        case RP2040::WDT_RESET:      return "watchdog";
        case RP2040::DEBUG_RESET:    return "debug";
        case RP2040::GLITCH_RESET:   return "glitch";
        case RP2040::BROWNOUT_RESET: return "brownout";
        default:                     return "unknown";
    }
}

// Link health, for working out why a connection went quiet: uptime (a reset
// shows as a small number), why the chip last reset, WiFi state and signal,
// how many clients have come and gone, and the longest loop() since last
// asked (a stalled loop shows as a large number).
void GetSys(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    JsonDocument doc;
    doc["uptimeS"] = millis() / 1000.0;
    doc["resetReason"] = resetReasonName;
    doc["wifiConnected"] = (WiFi.status() == WL_CONNECTED);
    doc["rssi"] = WiFi.RSSI();
    doc["freeHeap"] = rp2040.getFreeHeap();
    doc["connects"] = connectCount;
    doc["disconnects"] = disconnectCount;
    doc["wifiDrops"] = wifiDrops;
    doc["maxLoopMs"] = maxLoopUs / 1000.0;
    maxLoopUs = 0; // report the worst case since last asked
    serializeJson(doc, interface);
    interface.println();
}

// The raw (absolute, 0-360) encoder angle that currently reads as 0 deg.
// Read it once after ZERO and keep it; ZEROOFFSET puts it back later.
void GetZeroOffset(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    int port = parsePortParam(parameters, 0, interface);
    if (port < 0) return;
    interface.println(sensors.encoderZeroOffsetRawDeg(port), 6);
}

// Re-applies a saved zero: ZEROOFFSET <raw deg>. Same rule as ZERO --
// refused while the control loop is enabled (it would step the PID error).
void SetZeroOffset(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    if (parameters.Size() < 1) {
        interface.println(F("ERR missing offset (degrees)"));
        return;
    }
    char* end = nullptr;
    float offsetDeg = strtof(parameters[0], &end);
    if (end == parameters[0] || !isfinite(offsetDeg)) {
        interface.println(F("ERR offset must be a number (degrees)"));
        return;
    }
    int port = parsePortParam(parameters, 1, interface); // ZEROOFFSET <deg>[,<port>]
    if (port < 0) return;
    if (port == 0 && ctrlEnabled) {
        interface.println(F("ERR control loop enabled -- CTRLCONFIG enabled:false first"));
        return;
    }
    if (!sensors.encoderPorts().active(port)) {
        interface.println(F("ERR that port has no encoder configured (ENCCONFIG)"));
        return;
    }
    sensors.setEncoderZeroOffsetRawDeg(offsetDeg, port);
    interface.println(F("OK"));
}

// ---- soft stop / abort ----

void GetSoftStop(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    JsonDocument doc;
    doc["enabled"] = softStop.enabled();
    doc["stopped"] = softStop.stopped();
    doc["pinHigh"] = softStop.level(); // true = loop open
    doc["stopCount"] = softStop.stopCount();
    serializeJson(doc, interface);
    interface.println();
}

void SetSoftStopConfig(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    String json = interface.readStringUntil('\n');
    json.trim();

    JsonDocument doc;
    if (deserializeJson(doc, json)) {
        interface.println(F("ERR bad JSON"));
        return;
    }
    softStop.setEnabled(doc["enabled"] | softStop.enabled());
    interface.println(F("OK"));
}

// Software equivalent of the soft-stop: halt and disarm the excitation. The
// control loop, SBUS output and any running capture are left alone.
void AbortCmd(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    exciter.setArmed(false);
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
#ifndef HASTADAQ_ONBOARD_WIFI
    cyw43_set_pins_wl(CYW43_PINS_SPCE); // must be first -- before any WiFi/hw touch
#endif

    // Trigger and soft-stop pins next, before the (bounded) Serial wait: the
    // open-collector trigger output floats high until begin() drives it, so
    // do that as early as possible. In: opto, inverted, external pull-up.
    // Out: NPN, inverted.
    triggerIO.begin(TRIGGER_IN_PIN, TRIGGER_OUT_PIN, /*inInverted*/ true, /*outInverted*/ true, /*externalPullUp*/ true);
    softStop.begin(SOFTSTOP_PIN);

    Serial.begin(115200);
    uint32_t serialWaitStartMs = millis();
    while (!Serial && millis() - serialWaitStartMs < 3000) { delay(10); } // bounded -- see other .ino files in this repo for why

    Wire.begin();
    sensors.begin();
    channelMixer.begin();
    channelMixer.applyDefaults();

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
    scpi.RegisterCommand("ZEROOFFSET?", &GetZeroOffset);
    scpi.RegisterCommand("ZEROOFFSET", &SetZeroOffset);
    scpi.RegisterCommand("SYS?", &GetSys);
    scpi.RegisterCommand("TRIGCONFIG", &SetTrigConfig);
    scpi.RegisterCommand("TRIGCONFIG?", &GetTrigConfig);
    scpi.RegisterCommand("UDPCONFIG", &SetUdpConfig);
    scpi.RegisterCommand("UDPCONFIG?", &GetUdpConfig);
    scpi.RegisterCommand("ENCODERS?", &GetEncoders);
    scpi.RegisterCommand("ENCCONFIG", &SetEncConfig);
    scpi.RegisterCommand("SOFTSTOP?", &GetSoftStop);
    scpi.RegisterCommand("SOFTSTOPCONFIG", &SetSoftStopConfig);
    scpi.RegisterCommand("ABORT", &AbortCmd);

    resetReasonName = resetReasonToString(rp2040.getResetReason());
    Serial.printf("[boot] last reset: %s\n", resetReasonName);

    scpiServer.begin();
    Serial.print(F("[SCPI] Listening on port ")); Serial.println(SCPI_PORT);
}

void loop() {
    uint32_t loopStartUs = micros();

    // SCPI service -- never blocks (see architecture note at top of file).
    //
    // A new connection ALWAYS replaces the current one (last connection
    // wins), so a client whose old socket is half-dead can still get back
    // in; a second MATLAB session would therefore take the link over.
    WiFiClient incoming = scpiServer.accept();
    if (incoming) {
        if (clientWasConnected) {
            disconnectCount++;
            Serial.printf("[%lu ms] [SCPI] new client replaces the previous one\n", (unsigned long)millis());
        }
        scpiClient.stop();
        scpiClient = incoming;
        scpiClient.setNoDelay(true);    // send replies at once: no Nagle holding small writes
        scpiClient.keepAlive(5, 2, 3);  // probe an idle link every 5 s; a dead peer is noticed in ~11 s
        connectCount++;
        clientWasConnected = true;
        Serial.printf("[%lu ms] [SCPI] Client connected (#%lu)\n",
            (unsigned long)millis(), (unsigned long)connectCount);
    }
    bool clientUp = scpiClient && scpiClient.connected();
    if (clientWasConnected && !clientUp) {
        clientWasConnected = false;
        disconnectCount++;
        Serial.printf("[%lu ms] [SCPI] Client disconnected\n", (unsigned long)millis());
    }
    if (clientUp && scpiClient.available()) {
        scpi.ProcessInput(scpiClient, "\n");
    }

    // WiFi link watch (log only -- re-joining would block this loop, and
    // with it the SBUS output).
    static uint32_t lastWifiCheckMs = 0;
    static bool wifiWasUp = true;
    if (millis() - lastWifiCheckMs >= 1000) {
        lastWifiCheckMs = millis();
        bool wifiUp = (WiFi.status() == WL_CONNECTED);
        if (wifiWasUp && !wifiUp) {
            wifiDrops++;
            Serial.printf("[%lu ms] [WiFi] link LOST\n", (unsigned long)millis());
        } else if (!wifiWasUp && wifiUp) {
            Serial.printf("[%lu ms] [WiFi] link restored, RSSI=%d\n",
                (unsigned long)millis(), (int)WiFi.RSSI());
        }
        wifiWasUp = wifiUp;
    }

    // Soft stop: while the loop is open (or cut), halt and keep the
    // excitation disarmed, so even an EXCITE armed:true or an external trigger
    // cannot start a manoeuvre. Trim and the control loop keep running.
    softStop.update();
    if (softStop.consumeStopEvent()) {
        Serial.printf("[%lu ms] [SOFTSTOP] loop opened -- stop\n", (unsigned long)millis());
    }
    if (softStop.stopped() && (exciter.armed() || exciter.active())) {
        exciter.setArmed(false);
        Serial.printf("[%lu ms] [SOFTSTOP] excitation halted and disarmed\n", (unsigned long)millis());
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

    uint32_t loopUs = micros() - loopStartUs;
    if (loopUs > maxLoopUs) maxLoopUs = loopUs;
}
