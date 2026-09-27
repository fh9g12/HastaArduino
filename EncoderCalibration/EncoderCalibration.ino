// EncoderCalibration.ino
//
// SCPI-over-TCP bench tool for characterising the MT6835 magnetic
// encoder using a NEMA17 stepper (SY42STH47-1684B) + A4988 driver as a
// controlled constant-speed rotation source. Three distinct goals, per
// the chat that spawned this project:
//   1. Linearity characterisation: spin at a known constant speed, log
//      (t, commanded angle from step count, encoder angle) continuously
//      -- reveals the encoder's own per-revolution error, independent of
//      whether MT6835's internal auto-calibration is ever used.
//   2. MT6835 User Auto-Calibration: pull its CAL_EN pin high while
//      spinning at constant speed to trigger the chip's own internal
//      calibration (target ~0.07deg INL per MagnTek's datasheet).
//   3. Frequency response: command a sine/chirp POSITION trajectory
//      (real direction reversals, not just one-way constant speed) via
//      SINE/CHIRP below, to check the encoder isn't hiding lag/filtering
//      behind smooth constant-speed motion (see those commands' notes).
//

// (2) is NOT usable on this rig's actual hardware -- confirmed by
// reading the real MagnTek datasheet (Rev.1.3, section 9.2) once its
// permissions-only PDF lock was stripped: CAL_EN is a physical pin,
// pulled high while rotating at constant speed, with no SPI-command
// equivalent, and this specific breakout module doesn't expose CAL_EN
// (or Pin.10/PWM, the other status-monitor option) on its header --
// confirmed on the bench (see wiring/encoder-calibration-rig.yml).
// CALEN/CALFREQ/CALSTATUS? below are implemented and correct against the
// datasheet (kept as ready-to-use infrastructure for a future breakout
// that does expose CAL_EN) but are dead code on THIS board -- (1),
// the RUN-based linearity capture, is this rig's real calibration tool
// for now (see ../matlab/stepper/encoderLinearityTest.m).
//
// Confirmed procedure for (2), for reference: set AUTOCAL_FREQ[2:0]
// (CALFREQ, register 0x00E bits 6:4) to the bucket matching your actual
// constant rotation speed, start rotating, pull CAL_EN high (CALEN 1)
// and keep rotating at that speed for >64 revolutions, poll CALSTATUS?
// (0=none, 1=running, 2=failed, 3=success), then wait >6s before power-
// down on success to let the chip finish writing the result to EEPROM.
//
// Hardware:
//   - MT6835 encoder: SPI1 remapped onto GPIO10 (SCK) / 11 (MOSI) / 12
//     (MISO) / 13 (nCS), same as ServoCalibration/SbusServoCalibration.
//     CAL_EN wired to GPIO14 in firmware but NOT present on this
//     specific breakout -- see above.
//   - A4988 stepper driver: STEP on GPIO20, DIR on GPIO21. ENABLE on
//     GPIO19 (software-controlled -- see StepperDriver.h and setup()
//     below for why: leaving it hardwired-enabled through boot/WiFi
//     connect reliably prevented the motor from stepping on this rig).
//     Microstepping/RESET/SLEEP are still hardwired/jumpered on the
//     driver board itself -- see the wiring diagram.
//   - WiFi: Pimoroni RM2 breakout on SP/CE, same CYW43 pin fix as the
//     other projects in this repo.
//
// Wire protocol -- newline-terminated ASCII SCPI over TCP port 5025:
//
//   *IDN?              -> identification string
//   ANGLE?             -> live encoder reading, degrees (continuous/unwrapped)
//   ZERO               -> software zero offset at the current shaft position
//                         (instant, no wear, but only affects THIS
//                         host's ANGLE?/DATA? -- see HWZERO for the
//                         chip's own zero register)
//   HWZERO             -> confirmed MT6835 "Auto Setting Zero-Position"
//                         command (datasheet 7.6.7) -- writes current
//                         position into the chip's own ZERO_POS[11:0]
//                         register, so its ABZ/UVW/PWM outputs (not just
//                         this host's SPI reads) reflect the new zero.
//                         Volatile -- doesn't survive power-down unless
//                         you also call EEPROMSAVE.
//   EEPROMSAVE         -> persists the chip's current register map
//                         (including whatever HWZERO last set) to
//                         EEPROM (datasheet 7.6.6). NOT free -- EEPROM
//                         is rated ~1000 erase/program cycles, so only
//                         call this when you actually want it to
//                         survive a power cycle, not routinely. Wait
//                         >6s after "OK" before powering the chip down.
//   SPEED <degPerS>    -> free-run the stepper at a constant speed (signed;
//                         0 stops). Runs in the background via loop() --
//                         doesn't block, unlike RUN below. Useful for a
//                         manual CAL_EN sequence: start spinning, toggle
//                         CALEN, poll CALSTATUS?/ANGLE? as needed, stop
//                         when done.
//   SPEED?             -> query current speed
//   CALEN <0|1>        -> drive the encoder's CAL_EN pin (no-op on this
//                         board -- CAL_EN isn't wired, see above)
//   CALFREQ <0-7>      -> set the AUTOCAL_FREQ rotation-speed bucket
//                         (also dead on this board, same reason)
//   CALSTATUS?         -> raw calibration-status register value (0-3) --
//                         see the big comment above for the confirmed meaning
//   RUN                -> followed by a SECOND line: JSON run definition,
//                         e.g. {"speedDegPerS":90,"durationS":10,"sampleHz":100}
//                         Blocks for the run's duration (same convention as
//                         ServoCalibration's SWEEP/SINE/CHIRP -- see that
//                         project's header comment for the two-line-JSON
//                         rationale), logging (t, commanded, encoder) the
//                         whole time, then replies "OK <n_samples>".
//   SINE               -> followed by a SECOND line: JSON test definition,
//                         e.g. {"freqHz":1,"center":0,"amplitude":10,
//                         "cycles":5,"sampleHz":200}. "center" defaults to
//                         the stepper's CURRENT position (not a fixed
//                         value -- see RunSine). Drives real direction
//                         reversals via StepperDriver::trackTo() (a
//                         stepper can't jump to a position like a servo
//                         can) -- this is the "does the encoder filter/
//                         lag on direction changes" test. Moves to its
//                         t=0 position and settles first, same as SWEEP.
//                         REJECTS (ERR, doesn't silently clamp) any
//                         freqHz/amplitude combo whose peak speed
//                         (amplitude*2*pi*freqHz) exceeds
//                         MAX_VALIDATED_SPEED_DEG_PER_S below -- see that
//                         constant's comment for why (a real incident,
//                         not theoretical caution).
//   CHIRP              -> followed by a SECOND line: JSON test definition,
//                         e.g. {"f0":0.1,"f1":1,"periodS":60,"center":0,
//                         "amplitude":10,"cycles":1,"sampleHz":200}. Same
//                         "center defaults to current position", settle-
//                         first, and peak-speed-rejection behaviour as
//                         SINE (peak speed uses whichever of f0/f1 is
//                         faster).
//   STATUS?            -> "DONE <n_samples>" for the last completed run
//   DATA?              -> dumps the last run's captured time series as
//                         binary: one ASCII header line "BIN <n> <bytes>",
//                         then n*bytes raw bytes, each sample packed as
//                         {uint32 t_us; float target_deg; float encoder_deg}
//                         little-endian -- identical wire format to
//                         ServoCalibration/SbusServoCalibration's DATA?.

#include <WiFi.h>
#include <pico/cyw43_driver.h>
#include <math.h>

#define VREKRER_SCPI_PARSER_NO_IMPL
// 8-bit hash (the library's default) is only 256 possible values --
// with 13 commands registered here (RUN/SINE/CHIRP/CALFREQ pushed this
// over some prior sketches' count), DATA? started colliding with
// another command's hash and got silently routed to ITS handler
// instead (confirmed: DATA? was replying "OK", not a BIN header --
// Vrekrer_scpi_parser.h's own PrintDebugInfo() calls this a "hash
// crash"). Matching is by hash only, not a string re-check, so a
// collision routes to the WRONG handler rather than erroring. Widening
// to 16 bits (safe here -- this library's whole implementation lives in
// the header, no separately-compiled .cpp to go out of sync with) makes
// collisions astronomically unlikely at this command count.
#define SCPI_HASH_TYPE uint16_t
#include <Vrekrer_scpi_parser.h>
#include <ArduinoJson.h>
#include <StepperDriver.h>
#include <Mt6835Encoder.h>
#include <LinearChirp.h>
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

const float FULL_STEP_DEG = 1.8f;   // SY42STH47-1684B
const float MICROSTEP_DIV = 8.0f;   // matches the MS1/MS2/MS3 jumpers in the wiring diagram
StepperDriver stepper(/*step*/20, /*dir*/21, FULL_STEP_DEG / MICROSTEP_DIV);
const uint8_t A4988_ENABLE_PIN = 19; // see StepperDriver.h class comment

Mt6835Encoder encoder(/*sck*/10, /*mosi*/11, /*miso*/12, /*cs*/13);
const uint8_t CAL_EN_PIN = 14; // optional -- see the file header

// ---------------- sample capture ----------------

struct Sample {
    uint32_t tUs;
    float targetDeg;
    float encoderDeg;
};
static_assert(sizeof(Sample) == 12, "Sample must pack with no padding -- DATA? sends it raw over the wire");

const uint16_t MAX_SAMPLES = 20000; // ~240KB -- sized for longer runs than the
                                     // servo projects (multi-revolution linearity/
                                     // auto-cal captures), still a modest fraction
                                     // of the RP2350's RAM
const float MAX_DURATION_S = 300.0f; // generous -- auto-cal duration isn't confirmed
const float MIN_SAMPLE_HZ = 1.0f;
const float MAX_SAMPLE_HZ = 500.0f;

Sample sampleBuf[MAX_SAMPLES];
uint16_t sampleCount = 0;

// Drives the stepper at its currently-set speed and logs (t, commanded,
// encoder) samples at sampleHz until durationS elapses or the buffer
// fills. Keeps stepping every loop iteration regardless of sample
// cadence -- sampleHz controls logging rate, not rotation smoothness.
uint16_t runCapture(float durationS, float sampleHz) {
    sampleCount = 0;
    uint32_t sampleIntervalUs = (uint32_t)(1000000.0f / sampleHz);
    uint32_t durationUs = (uint32_t)(durationS * 1000000.0f);
    uint32_t t0 = micros();
    uint32_t lastSampleUs = t0 - sampleIntervalUs; // force an immediate first sample

    while (true) {
        stepper.update();

        uint32_t now = micros();
        uint32_t elapsedUs = now - t0;
        if (elapsedUs >= durationUs) break;
        if (sampleCount >= MAX_SAMPLES) break;

        if (now - lastSampleUs >= sampleIntervalUs) {
            lastSampleUs = now;
            encoder.update();

            sampleBuf[sampleCount].tUs = elapsedUs;
            sampleBuf[sampleCount].targetDeg = stepper.cumulativeDeg();
            sampleBuf[sampleCount].encoderDeg = encoder.getDegrees();
            sampleCount++;
        }
    }
    stepper.stop();
    return sampleCount;
}

// Speed used to physically seek to a SINE/CHIRP run's t=0 position
// before logging starts -- matches the constant-speed value already
// validated on this bench (stepperSpinTest.m), not a guess.
const float SEEK_SPEED_DEG_PER_S = 90.0f;
const uint32_t SEEK_TIMEOUT_MS = 30000; // safety bound -- shouldn't ever legitimately take this long

// HARD ceiling on any commanded stepper velocity (SINE/CHIRP peak speed,
// and trackTo()'s own pacing cap) -- pinned to the ONE speed actually
// validated on this bench, not derived from a test's own (unvalidated)
// parameters. A previous version scaled the trackTo() cap off the
// requested test's peak velocity, which provided no real protection --
// a 10Hz/90deg chirp asked for ~5655deg/s (942RPM, ~25,000 microsteps/s
// at 1/8 microstep), ~60x anything ever tested, stalled the motor, and
// took the motor PSU's current draw to zero (A4988 thermal shutdown or
// worse). Raise this only after deliberately, incrementally validating
// a higher constant SPEED on the bench first -- don't guess upward.
const float MAX_VALIDATED_SPEED_DEG_PER_S = 90.0f;

// Physically drives the stepper to targetDeg (via trackTo(), capped at
// the validated seek speed) before a SINE/CHIRP run starts logging --
// same purpose as ServoCalibration's moveToAndSettle(), but a stepper
// has to actually travel there step by step rather than jump instantly.
void moveToAndSettle(float targetDeg) {
    uint32_t startMs = millis();
    while (fabsf(targetDeg - stepper.cumulativeDeg()) > stepper.degPerStep() * 1.5f) {
        stepper.trackTo(targetDeg, SEEK_SPEED_DEG_PER_S);
        if (millis() - startMs > SEEK_TIMEOUT_MS) break; // shouldn't happen -- safety only
    }
}

// Drives the stepper along positionAt(t_s) via trackTo() (paced to
// trackMaxSpeedDegPerS) and logs (t, commanded, encoder) samples at
// sampleHz until durationS elapses or the buffer fills. targetDeg
// logged is the IDEAL commanded trajectory (positionAt(t_s)), not the
// stepper's own realised position -- same "target = the clean input
// signal" convention as ServoCalibration/SbusServoCalibration's
// SINE/CHIRP, so the FFT/Bode analysis in ../matlab/common sees a
// well-defined reference. This means the resulting response reflects
// the COMBINED stepper+encoder system, not the encoder alone -- there's
// no independent higher-bandwidth reference on this rig to separate
// them (see the file header).
template <typename PosFunc>
uint16_t runTrackedCapture(PosFunc positionAt, float trackMaxSpeedDegPerS, float durationS, float sampleHz) {
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

        float t_s = elapsedUs / 1000000.0f;
        float target = positionAt(t_s);
        stepper.trackTo(target, trackMaxSpeedDegPerS);

        if (now - lastSampleUs >= sampleIntervalUs) {
            lastSampleUs = now;
            encoder.update();

            sampleBuf[sampleCount].tUs = elapsedUs;
            sampleBuf[sampleCount].targetDeg = target;
            sampleBuf[sampleCount].encoderDeg = encoder.getDegrees();
            sampleCount++;
        }
    }
    return sampleCount;
}

// ---------------- SCPI command handlers ----------------

void Identify(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    interface.println(F("Bristol FARG,EncoderCalibration,1,0.1"));
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

// Hardware zero -- see Mt6835Encoder.h::zeroOnChip() for what this
// actually changes vs plain ZERO above. Volatile only (see EEPROMSAVE
// below to persist it).
void HwZeroEncoder(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    encoder.update();
    if (encoder.zeroOnChip()) {
        interface.println(F("OK"));
    } else {
        interface.println(F("ERR chip did not acknowledge"));
    }
}

// Persists the chip's current register map (including whatever HWZERO
// last set) to EEPROM -- see Mt6835Encoder.h::programEeprom() for the
// EEPROM wear-cycle caution. Deliberately a SEPARATE command from
// HWZERO, not automatic, so a zero never silently costs an EEPROM write
// unless you actually want it to survive a power cycle.
void SaveToEeprom(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    if (encoder.programEeprom()) {
        interface.println(F("OK -- wait >6s before power-down"));
    } else {
        interface.println(F("ERR chip did not acknowledge"));
    }
}

void SetSpeed(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    if (parameters.Size() < 1) {
        interface.println(F("ERR missing degPerS"));
        return;
    }
    stepper.setSpeedDegPerS(String(parameters[0]).toFloat());
    interface.println(F("OK"));
}

void GetSpeed(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    interface.println(stepper.speedDegPerS(), 2);
}

void SetCalEn(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    if (parameters.Size() < 1) {
        interface.println(F("ERR missing 0|1"));
        return;
    }
    encoder.setCalibrationEnabled(String(parameters[0]).toInt() != 0);
    interface.println(F("OK"));
}

// Sets the AUTOCAL_FREQ[2:0] rotation-speed bucket (0-7 -- see
// Mt6835Encoder.h::setAutoCalFreq() for the RPM table). Call before
// CALEN 1, matching whatever constant speed you're about to command via
// SPEED, per the datasheet's confirmed User Auto-Calibration procedure.
void SetCalFreq(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    if (parameters.Size() < 1) {
        interface.println(F("ERR missing bucket (0-7)"));
        return;
    }
    encoder.setAutoCalFreq((uint8_t)String(parameters[0]).toInt());
    interface.println(F("OK"));
}

void GetCalStatus(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    interface.println(encoder.getCalibrationStatus());
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

    float speedDegPerS = doc["speedDegPerS"] | 90.0f;
    float durationS = doc["durationS"] | 10.0f;
    float sampleHz = constrain((float)(doc["sampleHz"] | 100.0f), MIN_SAMPLE_HZ, MAX_SAMPLE_HZ);

    if (durationS <= 0.0f || durationS > MAX_DURATION_S) {
        interface.println(F("ERR duration out of range (0, 300] s"));
        return;
    }

    stepper.setSpeedDegPerS(speedDegPerS);
    uint16_t n = runCapture(durationS, sampleHz);
    interface.print(F("OK "));
    interface.println(n);
}

// SINE/CHIRP read their JSON payload as a second raw line, same
// convention as RUN above. Both default "center" to the stepper's
// CURRENT position (not a fixed value like the servo rigs' 90deg) --
// this rig's position is unbounded/continuous, so there's no natural
// fixed center, and defaulting to "wherever it already is" avoids an
// unnecessary long seek to some arbitrary absolute angle.
void RunSine(SCPI_C commands, SCPI_P parameters, Stream& interface) {
    String json = interface.readStringUntil('\n');
    json.trim();

    JsonDocument doc;
    if (deserializeJson(doc, json)) {
        interface.println(F("ERR bad JSON"));
        return;
    }

    float freqHz = doc["freqHz"] | 1.0f;
    float center = doc["center"] | stepper.cumulativeDeg();
    float amplitude = doc["amplitude"] | 10.0f; // keeps default peak speed (62.8deg/s) safely
                                                 // under MAX_VALIDATED_SPEED_DEG_PER_S
    float cycles = doc["cycles"] | 5.0f;
    float sampleHz = constrain((float)(doc["sampleHz"] | 200.0f), MIN_SAMPLE_HZ, MAX_SAMPLE_HZ);

    if (freqHz <= 0.0f) {
        interface.println(F("ERR freqHz must be > 0"));
        return;
    }

    // A fixed-frequency sine is a chirp with f0==f1 -- same trick
    // ServoCalibration's RunSine uses, see there for why.
    LinearChirp sine(freqHz, freqHz, 1.0f / freqHz, center, amplitude);
    float durationS = cycles / freqHz;
    if (durationS <= 0.0f || durationS > MAX_DURATION_S) {
        interface.println(F("ERR duration out of range (0, 300] s"));
        return;
    }

    // REJECT, don't silently clamp -- see MAX_VALIDATED_SPEED_DEG_PER_S
    // above for why a silent cap isn't good enough here.
    float peakSpeedDegPerS = amplitude * 2.0f * PI * freqHz;
    if (peakSpeedDegPerS > MAX_VALIDATED_SPEED_DEG_PER_S) {
        float maxAmplitudeAtThisFreq = MAX_VALIDATED_SPEED_DEG_PER_S / (2.0f * PI * freqHz);
        interface.print(F("ERR peak speed "));
        interface.print(peakSpeedDegPerS, 1);
        interface.print(F("deg/s exceeds validated ceiling "));
        interface.print(MAX_VALIDATED_SPEED_DEG_PER_S, 1);
        interface.print(F("deg/s -- reduce amplitude to <= "));
        interface.print(maxAmplitudeAtThisFreq, 2);
        interface.println(F("deg, or lower freqHz"));
        return;
    }

    moveToAndSettle(sine.deg(0.0f)); // == center
    uint16_t n = runTrackedCapture([&](float t_s) { return sine.deg(t_s); },
        MAX_VALIDATED_SPEED_DEG_PER_S, durationS, sampleHz);
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

    float f0 = doc["f0"] | 0.1f;
    float f1 = doc["f1"] | 1.0f; // was 10Hz -- see MAX_VALIDATED_SPEED_DEG_PER_S above for why
    float periodS = doc["periodS"] | 60.0f;
    float center = doc["center"] | stepper.cumulativeDeg();
    float amplitude = doc["amplitude"] | 10.0f; // keeps default peak speed (62.8deg/s) safely
                                                 // under MAX_VALIDATED_SPEED_DEG_PER_S
    float cycles = doc["cycles"] | 1.0f;
    float sampleHz = constrain((float)(doc["sampleHz"] | 200.0f), MIN_SAMPLE_HZ, MAX_SAMPLE_HZ);

    if (periodS <= 0.0f) {
        interface.println(F("ERR periodS must be > 0"));
        return;
    }

    LinearChirp chirp(f0, f1, periodS, center, amplitude);
    float durationS = periodS * cycles;
    if (durationS <= 0.0f || durationS > MAX_DURATION_S) {
        interface.println(F("ERR duration out of range (0, 300] s"));
        return;
    }

    // REJECT, don't silently clamp -- see MAX_VALIDATED_SPEED_DEG_PER_S
    // above for why a silent cap isn't good enough here. Peak velocity
    // happens at whichever end of the sweep (f0 or f1) is faster.
    float peakSpeedDegPerS = amplitude * 2.0f * PI * fmaxf(fabsf(f0), fabsf(f1));
    if (peakSpeedDegPerS > MAX_VALIDATED_SPEED_DEG_PER_S) {
        float maxAmplitudeAtThisFreq = MAX_VALIDATED_SPEED_DEG_PER_S / (2.0f * PI * fmaxf(fabsf(f0), fabsf(f1)));
        interface.print(F("ERR peak speed "));
        interface.print(peakSpeedDegPerS, 1);
        interface.print(F("deg/s exceeds validated ceiling "));
        interface.print(MAX_VALIDATED_SPEED_DEG_PER_S, 1);
        interface.print(F("deg/s -- reduce amplitude to <= "));
        interface.print(maxAmplitudeAtThisFreq, 2);
        interface.println(F("deg, or lower f1"));
        return;
    }

    moveToAndSettle(chirp.deg(0.0f)); // == center

    // LinearChirp's phase formula is only valid for t_s in [0, periodS) --
    // wrap elapsed time back into that range every cycle (see LinearChirp.h).
    uint16_t n = runTrackedCapture([&](float tAbs) { return chirp.deg(fmodf(tAbs, periodS)); },
        MAX_VALIDATED_SPEED_DEG_PER_S, durationS, sampleHz);
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

    stepper.begin();
    stepper.setEnablePin(A4988_ENABLE_PIN); // drives ENABLE high (disabled) immediately
    Serial.println(F("[boot] stepper.begin() done"));
    encoder.begin();
    encoder.setCalEnPin(CAL_EN_PIN);
    Serial.println(F("[boot] encoder.begin() done"));

    connectWiFi();

    stepper.setEnabled(true); // only enable once boot/WiFi connect is fully done -- see StepperDriver.h
    Serial.println(F("[boot] stepper enabled"));

    scpi.RegisterCommand("*IDN?", &Identify);
    scpi.RegisterCommand("ANGLE?", &GetAngle);
    scpi.RegisterCommand("ZERO", &ZeroEncoder);
    scpi.RegisterCommand("HWZERO", &HwZeroEncoder);
    scpi.RegisterCommand("EEPROMSAVE", &SaveToEeprom);
    scpi.RegisterCommand("SPEED", &SetSpeed);
    scpi.RegisterCommand("SPEED?", &GetSpeed);
    scpi.RegisterCommand("CALEN", &SetCalEn);
    scpi.RegisterCommand("CALFREQ", &SetCalFreq);
    scpi.RegisterCommand("CALSTATUS?", &GetCalStatus);
    scpi.RegisterCommand("RUN", &RunCapture);
    scpi.RegisterCommand("SINE", &RunSine);
    scpi.RegisterCommand("CHIRP", &RunChirp);
    scpi.RegisterCommand("STATUS?", &GetStatus);
    scpi.RegisterCommand("DATA?", &GetData);

    scpiServer.begin();
    Serial.print(F("[SCPI] Listening on port ")); Serial.println(SCPI_PORT);
}

void loop() {
    stepper.update(); // free-running rotation from SPEED, independent of RUN's own capture loop

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
