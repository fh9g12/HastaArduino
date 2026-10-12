# HastaArduino

Bench-instrumentation firmware + MATLAB tooling for characterising servo/stepper/encoder/strain-gauge hardware, built around one board: the **Pimoroni Pico Plus 2** (RP2350B, no on-board radio) with a **Pimoroni RM2 WiFi/BT breakout plugged into its SP/CE connector**. Every active rig follows the same shape — an Arduino sketch exposes an SCPI-over-TCP instrument interface, a MATLAB script drives it and pulls back binary sample data, plots follow.

This file is for a future agent (human or Claude) picking this repo up cold. It describes architecture and conventions, not project-by-project detail — read the `.ino` header comments for that; they're kept current on purpose.

## Repo layout

```
HastaDrivers/         Shared driver library (Visual Micro "shared items" project — see below)
<ProjectName>/         One folder per Arduino sketch, folder name == .ino name (hard Arduino requirement)
matlab/common/        Shared MATLAB helpers (TCP connect, binary parsers, FFT/Bode plotting)
matlab/<rig>/          Per-rig MATLAB test scripts (sbus, stepper, straingauge, hastadaq)
wiring/                WireViz-generated wiring diagrams (.yml source + rendered .png/.svg/.html/.bom.tsv)
kicad/hastadaq/        KiCad 10 schematic for HastaDAQ (PCB-ready path) -- see "Schematics (KiCad)" below
arduino-deps.txt       Pinned board core + library versions (source of truth, not Library Manager's idea of "latest")
setup-arduino-deps.ps1 Installs exactly what arduino-deps.txt pins, via arduino-cli
HastaArduino.slnx      Visual Studio solution (Visual Micro extension) referencing the active projects
```

### Active rigs (current pattern, read these for style)

Servo actuation in this repo is **SBUS-only** — an earlier PWM path (`ServoCalibration`, backed by a `ServoBank` driver) and a batch of early prototypes/bringup sketches (`Servoscpi`, `ServoTest`, `WifiTest`, `EncoderBringup`, `GpioInvertBringup`, `StrainGaugeBringup`, plus an original empty `HastaDAQ` stub) were removed once the real rigs below existed and worked — see git history before this point if you need that story. **`HastaDAQ` is a reused name** — the current one is a real, active flagship project (below), unrelated to the removed stub beyond sharing a folder name.

- **HastaDAQ** — the flagship system: 5 SBUS control surfaces (2 ailerons, 2 elevators, 1 rudder), MT6835 encoder + closed-loop elevator trim-hold, 2x ADS122C04 ADCs (half-bridge strain gauges) + ICM20649 IMU on one Qwiic chain, external trigger I/O for multi-instrument sync, and continuous UDP streaming alongside the usual SCPI RUN/DATA?. Architecturally different enough from every other rig here — and split across multiple sketch-local header files rather than one `.ino` — that it gets its own section below; read that before touching it.
- **SbusServoCalibration** — SBUS servo characterisation (channel range, dynamic response) against an MT6835 encoder on the servo's own output shaft.
- **EncoderCalibration** — NEMA17 (via A4988) + MT6835 rig: linearity characterisation, frequency response (sine/chirp with real direction reversals), and (dead-on-this-hardware but implemented/correct) MT6835 User Auto-Calibration support.
- **StrainGaugeCalibration** — Adafruit ADS122C04 24-bit ADC + half-bridge strain gauge, ratiometric external-reference wiring.

## HastaDAQ (flagship system)

Everything else in this repo blocks the whole sketch for a run's duration (`RUN` freezes the MCU for `durationS` then replies). HastaDAQ **cannot** do that — it's flying real control surfaces, so SBUS output and the elevator control loop must never stop, even mid-capture. It's the one fully non-blocking/event-driven sketch here: `loop()` services SCPI, polls the trigger pin, refreshes every sensor, advances the excitation/control-loop/capture/UDP state machines, and re-sends the SBUS frame, all every iteration, unconditionally — `RUN`/`ARM`/`FIRE` just flip state a state machine acts on, they never block. Copy this one (not the others) as a template for any future rig that has an always-on real-time responsibility.

Unlike every other rig here, `HastaDAQ.ino` itself is just SCPI handlers + `setup()`/`loop()` (~500 lines). The actual logic lives in sketch-local header-only classes sitting next to it (still `#include`d directly into the one `.ino` — Arduino sketches don't auto-prototype extra `.cpp` files, so header-only was the simplest safe split):

- **ChannelMixer.h** — owns the `SbusServoBank` and the per-channel gain/trim state. **This is the one place to rename a servo or move it to a different SBUS channel number**: edit the `CHANNEL_DEFS[]` table at the top of the file (`{"RUDDER", 0}, {"ELEV_R", 1}, {"ELEV_L", 2}, {"AIL_R", 3}, {"AIL_L", 4}`) — name and SBUS channel index both live there, and `SetChanConfig`/`GetChanConfig` accept either the channel's index or its name.
- **Sensors.h** — `SensorHub`: MT6835 encoder + both ADS122C04s (half-bridge strain gauges, ratiometric `VREF_SUPPLY` since each ADC's bridge excitation is drawn from that same ADC's own VIN — no external reference wiring needed, unlike `StrainGaugeCalibration`) + ICM20649 IMU, all on one Qwiic I2C bus.
- **CaptureManager.h** — the `HastaDaqSample` wire-format struct (68 bytes: timestamp, both ADC channels, encoder, accel/gyro, excitation + control output, per-channel servo commands), the bounded-capture state machine (`CaptureManager`), and the continuous-streaming one (`UdpStreamer`).

`HastaDrivers/src/ExcitationGenerator.h` and `TriggerIO.h` (shared, not sketch-local — see below) round out the split.

Signal flow per servo channel, every SBUS frame:

```
commandedDeg[ch] = trimDeg[ch] + excGain[ch]*excitationValue(t) + ctrlGain[ch]*controlOutput
```

One shared excitation waveform (sine / 1-cosine doublet / chirp) and one shared PID loop (error = encoder angle − target) are both mixed in per-channel by a `[-1, +1]` gain — `0` excludes a channel entirely, matched signs give symmetric excitation, opposite signs give differential. This is what makes "trim to an angle, then chirp the elevator" one continuous action: the PID's target *is* the trim angle, and the chirp rides on top of whatever it's already holding. The control loop runs every `loop()` iteration on its own real elapsed dt (`PidController::update(measurement)` tracks its own last-update timestamp) — there's deliberately no separate configurable control-loop rate; tune response purely via Kp/Ki/Kd.

Triggering: `RUN` = `ARM` (configure a bounded capture) immediately followed by an internal `FIRE`. `ARM` alone waits for a trigger instead — either SCPI `FIRE` or a real edge on the external trigger-in pin, for synchronising the capture (and, if excitation is armed, its phase-zero) with other equipment. Every trigger, from any source, also pulses the trigger-out pin, so this board can be the sync master for other instruments too.

Excitation has an **armed vs. active** split (`ExcitationGenerator.h`) specifically to support a start delay: `EXCITE`'s JSON body sets `armed` (sticky — "should the next trigger start this") and `delayS`; a trigger only transitions armed→active, and `update()` stays silent until `delayS` has elapsed since that trigger. This is what lets you arm excitation, wait for an external trigger, and have the waveform itself start N seconds later — e.g. trigger a data collection immediately but delay the chirp until the aircraft has settled at its trim point. `GetExcite` reports both `armed` (what you set) and the read-only `active` (what's actually happening right now).

One known-unconfirmed thing, called out in the `.ino`'s own header comment and needing bench verification before trusting results: the **second ADS122C04's I2C address** — Adafruit's board has address solder-jumpers but their guide never publishes the resulting address table, so `HastaDAQ.ino` falls back to a boot-time I2C bus scan over Serial if it doesn't answer at the guessed `0x41`.

`matlab/hastadaq/controlStepResponseTest.m` exploits the non-blocking `RUN` to help tune the elevator PID: it settles the loop at a starting target, starts a capture, steps `CTRLCONFIG`'s target mid-capture, and plots the encoder's step response plus PID output — re-run with different Kp/Ki/Kd in the script and compare plots.

## HastaDrivers (shared library)

A Visual Micro **shared items** project (`HastaDrivers.vcxitems`), imported by every sketch's `.vcxproj` via `<Import Project="..\HastaDrivers\HastaDrivers.vcxitems" Label="Shared" />`. Its `src/` folder is on every sketch's include path, so `#include <Whatever.h>` (angle brackets) resolves here, and — important — so does `#include "secrets.h"` (quote-style falls back to the same search path when nothing local matches).

Header-only, dependency-light drivers, deliberately kept minimal rather than pulling in a heavy vendor framework for one register read (see `Mt6835Encoder.h`'s header comment for the concrete story — an earlier SimpleFOC-based version made IntelliSense/compiles painfully slow):

- **Mt6835Encoder.h** — raw-SPI MT6835 magnetic encoder driver: continuous/unwrapped multi-turn angle, software zero, and (datasheet-confirmed, not guessed) calibration-status/User-Auto-Calibration register access.
- **StepperDriver.h** — STEP/DIR stepper driver with two modes: constant-speed free-run (`setSpeedDegPerS`/`update`) and position-tracking (`trackTo`, paced to a hard speed ceiling) for driving an arbitrary trajectory (sine/chirp) with real direction reversals.
- **SbusServo.h** — single-channel (or broadcast-to-all-16) SBUS servo output (wraps bolderflight/sbus) with the RP2040 UART-inversion workaround this project had to reverse-engineer (see git history / SbusServoCalibration.ino).
- **SbusServoBank.h** — multi-channel sibling of `SbusServo.h`: N independently-commanded channels sharing one SBUS frame/bus (`writeDeg(index, deg)`, indexed locally, not by raw SBUS channel number). Use this, not `SbusServo.h`, whenever a rig drives more than one servo (HastaDAQ's 5).
- **PidController.h** — small live-tunable PID, basic clamped-integration anti-windup, output hard-clamped to a configurable `+/-limitDeg`. Two `update()` overloads: pass an explicit `dtS`, or call `update(measurement)` and let the controller track its own last-update timestamp internally (what HastaDAQ uses) — `reset()` clears that internal timestamp too, so there's no separately-tracked dt variable that can go stale across an enable/disable cycle.
- **ExcitationGenerator.h** — sketch-facing wrapper around the trajectory generators below (sine/1-cosine/chirp, common `freqHz`/`amplitudeDeg`/`cycles`/`delayS` config) with the **armed vs. active** split HastaDAQ needs for trigger-delayed excitation: `setArmed()` sets sticky intent, `triggerStart()` is the only thing that starts it (and only if armed), `update()` stays at 0 until any configured `delayS` has elapsed since that trigger.
- **TriggerIO.h** — external trigger-in (interrupt-driven, configurable edge) + trigger-out (non-blocking pulse) pair, for synchronising a capture (and, if armed, excitation phase-zero) with other equipment. Single-instance only (documented in the header) — fine for these single-`.ino` sketches, not safe to instantiate twice.
- **SweepWave.h**, **LinearChirp.h**, **OneMinusCosine.h** — shared trajectory generators (triangle sweep; chirp, with sine as chirp's f0==f1 special case; the standard aerospace "1-cosine" doublet pulse) used by every rig's SWEEP/SINE/CHIRP/EXCITE commands.
- **Controlstate.h/.cpp** — mutex-guarded shared state scaffold for a *future* dual-core control loop; currently single-core so the mutex isn't load-bearing yet. Not used by any current active sketch (its original consumer, the SCPI 6-servo controller, was removed) — kept because the dual-core control loop it was built for hasn't happened yet; safe to delete too if that plan is dropped.
- **secrets.h** / **secrets.h.example** — gitignored WiFi credentials (`WIFI_SSID`/`WIFI_PASS`), shared across every sketch from this one location. Copy the `.example` file and fill it in on a new machine.

## Schematics (KiCad)

`kicad/hastadaq/hastadaq.kicad_sch` is the HastaDAQ schematic (WireViz's single-diagram output got too tangled for a system this size, and KiCad is the path to a future PCB). Open `hastadaq.kicad_pro` in KiCad 10. Connectivity is by net labels (same name = same net); only the two strain-gauge bridges are drawn with real wires. `hastadaq.pdf`/`.png` are pre-rendered copies.

- **Power architecture (HastaDAQ):** 8.4 V bench PSU → fuse → `VSERVO` rail, which feeds the servos directly *and* a UBEC whose 5 V output goes through a Schottky into the Pico's VSYS. The UBEC **must be set to 5 V** (Pico VSYS max is 5.5 V) and its input range must cover 8.4 V — the exact Overlander uBEC specs were not verifiable, check its label. Sensors run off the Pico's 3V3 pin. Each strain-gauge ADC has, in the schematic, 1k in each bridge-output leg + 100nF across them (~800 Hz corner) and 10uF + 100nF supply decoupling, to be placed at the ADC end; use shielded twisted cable for the gauge wires. The Pico Plus 2's own 3V3 is already a linear regulator (AP7366EA-33, 600 mA max, from VSYS — per Pimoroni's schematic; *not* a switching regulator like the Pico 2 W), so a dedicated LDO for the ADS122C04 boards is optional rather than essential. Power paths on the board: VBUS→VSYS goes through an on-board Schottky (D2); the USB connector's VBUS has no diode on its side.
- `kicad/tools/generate_hastadaq_sch.py` bootstrapped the first draft (`py kicad/tools/generate_hastadaq_sch.py`). **Once you edit the schematic in KiCad, the `.kicad_sch` is the source of truth — don't re-run the generator over it.**
- Symbols are project-local generic blocks (`HastaDAQ.kicad_sym`, all pins `passive`, no footprints). Before a PCB: assign real footprints, set proper pin electrical types, and replace the blocks with real connectors/footprints for the Pico Plus 2 and the Adafruit/MT6835 breakouts.
- Headless checks work: `kicad-cli sch erc` and `kicad-cli sch export pdf` (KiCad installs to `%LOCALAPPDATA%\Programs\KiCad\10.0\bin`, not on PATH). The exported PDF carries the same permissions-only lock described in the gotchas below.
- `wiring/hastadaq-rig.*` (WireViz) is still there as a cable-level view but the KiCad schematic is now the primary reference.

## Library management

`arduino-deps.txt` is the source of truth for the board core + every library version this repo is actually built against — not whatever Library Manager happens to install. Re-run `setup-arduino-deps.ps1` (installs via `arduino-cli`, targeting the real Arduino sketchbook folder — see gotcha below) after pulling on a new machine, and update the pinned version in that file (not just install-and-forget) whenever you deliberately bump something.

## Coding conventions (the "instrument" pattern)

Every active WiFi rig follows the same shape EXCEPT HastaDAQ (see its own section above for why) — copy `StrainGaugeCalibration.ino` or `EncoderCalibration.ino` as a template for a simple blocking-capture rig; copy `HastaDAQ.ino` instead if the new rig has anything that must keep running during a capture:

- **SCPI-over-TCP**, port 5025, via `Vrekrer_scpi_parser`. Flat (non-hierarchical) command names.
- **Two-line JSON for structured params**: the parser tokenizes on commas, so a command needing a JSON body (`RUN`, `SINE`, `CHIRP`, ...) reads its payload as a *second* raw line via `interface.readStringUntil('\n')`, not as a normal SCPI parameter.
- **`RUN` + `STATUS?` + `DATA?` binary capture convention**: `RUN` blocks for a run's duration logging into a fixed `Sample sampleBuf[MAX_SAMPLES]`, replies `OK <n>`; `DATA?` dumps it as one ASCII header line (`BIN <n> <bytesPerSample>`) followed by the raw packed array — binary, not CSV, because formatting/sending thousands of ASCII lines was the actual slow part, not the network. Every `Sample` struct gets a `static_assert(sizeof(Sample) == N, ...)` to keep the wire format honest.
- **`CYW43_PINS_SPCE` pin-fix table**: every WiFi sketch defines this array and calls `cyw43_set_pins_wl(CYW43_PINS_SPCE)` as the *first* line of `setup()`, before touching any other hardware — required because the RM2 is wired through the SP/CE connector (GP32-GP35), not an on-board radio (see gotcha below).
- **Bounded `while (!Serial)`** (3s), never indefinite — the board's actual job (WiFi + SCPI server) must come up whether or not anyone has a serial monitor open.
- **MATLAB side**: `matlab/common/` holds reusable pieces (`connectServo.m` for TCP connect + `*IDN?`, one `read<X>Data.m` binary parser per distinct wire format, shared FFT/Bode/time-history plotters). Each rig gets its own `matlab/<rig>/` folder of test scripts built on those. Don't force-fit a new rig's data onto an existing parser if the wire format genuinely differs — write a small parallel one (see `readStrainData.m` next to `readServoData.m`).
- **Wiring diagrams**: WireViz YAML source in `wiring/*.yml`, rendered to `.png`/`.svg`/`.html`/`.bom.tsv` alongside. Regenerate after any wiring change (`wireviz <file>.yml`, needs Graphviz on PATH) and actually look at the rendered image before calling it done.
- **Verify against real sources for anything hardware-safety-relevant** — datasheets, actual library source, actual register maps — not memory. This project has been bitten by guessing before (wrong pinouts, wrong calibration procedures) and helped repeatedly by checking (e.g. the MT6835 CAL_STATUS register meaning, the ADS122C04 absolute-max reference-voltage limits, the Vrekrer hash-collision bug below).

## Pico Plus 2 + RM2 / RP2350 gotchas

- **WiFi requires the CYW43 pin fix** (`CYW43_PINS_SPCE`, above) before *any* other hardware touch in `setup()` — the RM2 breakout is wired through the SP/CE connector (RM2 signals on GP32 REG_ON, GP33 CS, GP34 CLK, GP35 DATA; confirmed against Pimoroni's Pico Plus 2 pinout diagram), not the pins the core's defaults expect. Those GPIOs are not used by anything else here (Qwiic I2C = GP4/GP5, encoder SPI1 = GP10-13, trigger = GP14/15, SBUS UART1 = GP20/21), so there is no pin conflict.
- **Build with the "Pimoroni PicoPlus2W" board target even though the hardware is a Pico Plus 2 + RM2 breakout.** In the core's `boards.txt` only that target defines `-DPICO_CYW43_SUPPORTED=1 -DCYW43_PIN_WL_DYNAMIC=1` (CYW43 support and runtime-settable WL pins); the plain "PicoPlus2" target has neither, so WiFi would not compile in.
- **`digitalWrite()` resets GPIO pad overrides.** It calls `gpio_set_function()` internally on every single call, which clobbers any `gpio_set_outover()`/invert override you set. Use `gpio_put()` instead when you need a bare-GPIO override to stick. (In practice this repo ended up not needing manual overrides at all — `SbusServo.h` uses `SerialUART::setInvertTX()/setInvertRX()`, the officially-supported mechanism, instead — but the `digitalWrite()` gotcha is real and will bite any other bare-GPIO override work.)
- **`SerialUART` numbering is non-intuitive**: `Serial1` = UART0, `Serial2` = UART1. Each UART instance also has its own valid-pin bitset (e.g. GPIO20/21 are UART1-only) — using the wrong `SerialX` object for a given pin pair fails silently/confusingly rather than erroring clearly.
- **`Vrekrer_scpi_parser` defaults to an 8-bit command-matching hash** (`SCPI_HASH_TYPE`, default `uint8_t` — only 256 values), and it matches purely by hash, not by re-comparing the string. Register enough commands (this repo hit it around 13) and two commands can collide, silently routing to the *wrong* handler with no error. Always `#define SCPI_HASH_TYPE uint16_t` before `#include <Vrekrer_scpi_parser.h>` in every new sketch — it's free (this library's whole implementation lives in the header, no separately-compiled `.cpp` to go out of sync with).
- **Visual Micro project files are machine-generated.** A `.vcxproj`'s `IncludePath`/`ForcedIncludeFiles` blob and the `__vm/` folder (`.vsarduino.h`, `Compile.vmps.xml`, ...) are IntelliSense/build-cache artifacts tied to this specific machine's toolchain paths and per-project hash-named temp dirs. Don't hand-copy them from another project into a new one — write a minimal `.vcxproj` (GUID, configs, the shared-items import, the `.ino` as `ClCompile`) and let Visual Micro populate the rest on a real **Build** the first time the project is opened (same fix that resolved an earlier SimpleFOC library-detection issue in this repo's history).
- **The Arduino sketchbook lives under OneDrive**, not plain `Documents` — `C:\Users\finta\OneDrive\Documents\Arduino`. `setup-arduino-deps.ps1` targets this via `[Environment]::GetFolderPath("MyDocuments")`, which resolves correctly; don't hardcode `C:\Users\<user>\Documents`.
- **Adafruit's ADS122C04 board has undocumented address jumpers.** The guide confirms two address solder-jumpers exist (for running multiple boards on one I2C/Qwiic bus) but never publishes the resulting address for each combination. Don't assert a specific value — bridge one jumper, then confirm the real address with an I2C bus scan (`Wire.beginTransmission(addr); Wire.endTransmission()==0` for `addr` 1-126) rather than guessing; `HastaDAQ.ino` does this automatically at boot if its second ADC doesn't answer where expected.
- **Many datasheet PDFs carry a permissions-only lock** (blocks copy/paste, blank owner password) that generic PDF readers report as "password-protected" even though they open fine in a viewer. `pikepdf.open(path, password='')` then `.save(dst, encryption=False)` strips it — this is not the same thing as bypassing a real access-restricted document, it's TI/MagnTek-style copy-protection with an empty owner password.
