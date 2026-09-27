# HastaArduino

Bench-instrumentation firmware + MATLAB tooling for characterising servo/stepper/encoder/strain-gauge hardware, built around one board: the **Pimoroni Pico Plus 2 W** (RP2350, built-in RM2 WiFi/BT module). Every active rig follows the same shape — an Arduino sketch exposes an SCPI-over-TCP instrument interface, a MATLAB script drives it and pulls back binary sample data, plots follow.

This file is for a future agent (human or Claude) picking this repo up cold. It describes architecture and conventions, not project-by-project detail — read the `.ino` header comments for that; they're kept current on purpose.

## Repo layout

```
HastaDrivers/         Shared driver library (Visual Micro "shared items" project — see below)
<ProjectName>/         One folder per Arduino sketch, folder name == .ino name (hard Arduino requirement)
matlab/common/        Shared MATLAB helpers (TCP connect, binary parsers, FFT/Bode plotting)
matlab/<rig>/          Per-rig MATLAB test scripts (pwm, sbus, stepper, straingauge)
wiring/                WireViz-generated wiring diagrams (.yml source + rendered .png/.svg/.html/.bom.tsv)
arduino-deps.txt       Pinned board core + library versions (source of truth, not Library Manager's idea of "latest")
setup-arduino-deps.ps1 Installs exactly what arduino-deps.txt pins, via arduino-cli
HastaArduino.slnx      Visual Studio solution (Visual Micro extension) referencing the active projects
```

### Active rigs (current pattern, read these for style)

- **ServoCalibration**, **SbusServoCalibration** — PWM and SBUS servo characterisation (pulse/channel range, dynamic response) against an MT6835 encoder on the servo's own output shaft.
- **EncoderCalibration** — NEMA17 (via A4988) + MT6835 rig: linearity characterisation, frequency response (sine/chirp with real direction reversals), and (dead-on-this-hardware but implemented/correct) MT6835 User Auto-Calibration support.
- **StrainGaugeCalibration** — Adafruit ADS122C04 24-bit ADC + half-bridge strain gauge, ratiometric external-reference wiring.
- **StrainGaugeBringup**, **EncoderBringup**, **GpioInvertBringup** — standalone bring-up sketches (no WiFi/SCPI), each isolating one hardware question before it got folded into a real rig. Not registered in the `.slnx` — plain folder + `.ino`, nothing else needed to build them.

### Legacy / superseded (don't build on these without checking first)

- **HastaDAQ** — empty stub, dead scaffold.
- **Servoscpi** — an earlier full SCPI+WiFi 6-servo controller (WiFi + `ControlState` + `ServoBank`, no encoder feedback). Superseded by the per-axis Calibration sketches' RUN/DATA? convention, but it's the thing `ControlState`/multi-channel `ServoBank` were built for — read it if you need that history.
- **ServoTest**, **WifiTest** — pre-networking bringup tests (open-loop servo chirp; bare CYW43/WiFi connectivity). Their findings (pin mappings, etc.) are already folded into every later sketch's header comments.

## HastaDrivers (shared library)

A Visual Micro **shared items** project (`HastaDrivers.vcxitems`), imported by every sketch's `.vcxproj` via `<Import Project="..\HastaDrivers\HastaDrivers.vcxitems" Label="Shared" />`. Its `src/` folder is on every sketch's include path, so `#include <Whatever.h>` (angle brackets) resolves here, and — important — so does `#include "secrets.h"` (quote-style falls back to the same search path when nothing local matches).

Header-only, dependency-light drivers, deliberately kept minimal rather than pulling in a heavy vendor framework for one register read (see `Mt6835Encoder.h`'s header comment for the concrete story — an earlier SimpleFOC-based version made IntelliSense/compiles painfully slow):

- **ServoBank.h/.cpp** — multi-channel hobby-servo driver using RP2040/2350's native hardware PWM (`analogWriteFreq`/`analogWrite`), not the PIO-based `Servo` library — chosen specifically so the PWM carrier can run above the usual 50Hz (confirmed working to 600Hz+), runtime-tunable (`setPwmFreqHz`/`setPulseRangeUs`).
- **Mt6835Encoder.h** — raw-SPI MT6835 magnetic encoder driver: continuous/unwrapped multi-turn angle, software zero, and (datasheet-confirmed, not guessed) calibration-status/User-Auto-Calibration register access.
- **StepperDriver.h** — STEP/DIR stepper driver with two modes: constant-speed free-run (`setSpeedDegPerS`/`update`) and position-tracking (`trackTo`, paced to a hard speed ceiling) for driving an arbitrary trajectory (sine/chirp) with real direction reversals.
- **SbusServo.h** — SBUS servo output (wraps bolderflight/sbus) with the RP2040 UART-inversion workaround this project had to reverse-engineer (see git history / SbusServoCalibration.ino).
- **SweepWave.h**, **LinearChirp.h** — shared trajectory generators (triangle sweep; chirp, with sine as chirp's f0==f1 special case) used by every rig's SWEEP/SINE/CHIRP commands.
- **Controlstate.h/.cpp** — mutex-guarded shared state scaffold for a *future* dual-core control loop; currently single-core so the mutex isn't load-bearing yet. Used by the legacy `Servoscpi`, not by the active Calibration sketches.
- **secrets.h** / **secrets.h.example** — gitignored WiFi credentials (`WIFI_SSID`/`WIFI_PASS`), shared across every sketch from this one location. Copy the `.example` file and fill it in on a new machine.

## Library management

`arduino-deps.txt` is the source of truth for the board core + every library version this repo is actually built against — not whatever Library Manager happens to install. Re-run `setup-arduino-deps.ps1` (installs via `arduino-cli`, targeting the real Arduino sketchbook folder — see gotcha below) after pulling on a new machine, and update the pinned version in that file (not just install-and-forget) whenever you deliberately bump something.

## Coding conventions (the "instrument" pattern)

Every active WiFi rig follows the same shape — copy the newest one (`StrainGaugeCalibration.ino` or `EncoderCalibration.ino`) as a template rather than starting from scratch:

- **SCPI-over-TCP**, port 5025, via `Vrekrer_scpi_parser`. Flat (non-hierarchical) command names.
- **Two-line JSON for structured params**: the parser tokenizes on commas, so a command needing a JSON body (`RUN`, `SINE`, `CHIRP`, ...) reads its payload as a *second* raw line via `interface.readStringUntil('\n')`, not as a normal SCPI parameter.
- **`RUN` + `STATUS?` + `DATA?` binary capture convention**: `RUN` blocks for a run's duration logging into a fixed `Sample sampleBuf[MAX_SAMPLES]`, replies `OK <n>`; `DATA?` dumps it as one ASCII header line (`BIN <n> <bytesPerSample>`) followed by the raw packed array — binary, not CSV, because formatting/sending thousands of ASCII lines was the actual slow part, not the network. Every `Sample` struct gets a `static_assert(sizeof(Sample) == N, ...)` to keep the wire format honest.
- **`CYW43_PINS_SPCE` pin-fix table**: every WiFi sketch defines this array and calls `cyw43_set_pins_wl(CYW43_PINS_SPCE)` as the *first* line of `setup()`, before touching any other hardware — required for the Pico Plus 2 W's built-in RM2 module (see gotcha below).
- **Bounded `while (!Serial)`** (3s), never indefinite — the board's actual job (WiFi + SCPI server) must come up whether or not anyone has a serial monitor open.
- **MATLAB side**: `matlab/common/` holds reusable pieces (`connectServo.m` for TCP connect + `*IDN?`, one `read<X>Data.m` binary parser per distinct wire format, shared FFT/Bode/time-history plotters). Each rig gets its own `matlab/<rig>/` folder of test scripts built on those. Don't force-fit a new rig's data onto an existing parser if the wire format genuinely differs — write a small parallel one (see `readStrainData.m` next to `readServoData.m`).
- **Wiring diagrams**: WireViz YAML source in `wiring/*.yml`, rendered to `.png`/`.svg`/`.html`/`.bom.tsv` alongside. Regenerate after any wiring change (`wireviz <file>.yml`, needs Graphviz on PATH) and actually look at the rendered image before calling it done.
- **Verify against real sources for anything hardware-safety-relevant** — datasheets, actual library source, actual register maps — not memory. This project has been bitten by guessing before (wrong pinouts, wrong calibration procedures) and helped repeatedly by checking (e.g. the MT6835 CAL_STATUS register meaning, the ADS122C04 absolute-max reference-voltage limits, the Vrekrer hash-collision bug below).

## Pico Plus 2 W / RP2350 gotchas

- **WiFi requires the CYW43 pin fix** (`CYW43_PINS_SPCE`, above) before *any* other hardware touch in `setup()` — this board's WiFi doesn't come up on the earlephilhower core's defaults without it.
- **`digitalWrite()` resets GPIO pad overrides.** It calls `gpio_set_function()` internally on every single call, which clobbers any `gpio_set_outover()`/invert override you set. Use `gpio_put()` instead when you need a bare-GPIO override to stick (see `GpioInvertBringup`).
- **`SerialUART` numbering is non-intuitive**: `Serial1` = UART0, `Serial2` = UART1. Each UART instance also has its own valid-pin bitset (e.g. GPIO20/21 are UART1-only) — using the wrong `SerialX` object for a given pin pair fails silently/confusingly rather than erroring clearly.
- **`Vrekrer_scpi_parser` defaults to an 8-bit command-matching hash** (`SCPI_HASH_TYPE`, default `uint8_t` — only 256 values), and it matches purely by hash, not by re-comparing the string. Register enough commands (this repo hit it around 13) and two commands can collide, silently routing to the *wrong* handler with no error. Always `#define SCPI_HASH_TYPE uint16_t` before `#include <Vrekrer_scpi_parser.h>` in every new sketch — it's free (this library's whole implementation lives in the header, no separately-compiled `.cpp` to go out of sync with).
- **Visual Micro project files are machine-generated.** A `.vcxproj`'s `IncludePath`/`ForcedIncludeFiles` blob and the `__vm/` folder (`.vsarduino.h`, `Compile.vmps.xml`, ...) are IntelliSense/build-cache artifacts tied to this specific machine's toolchain paths and per-project hash-named temp dirs. Don't hand-copy them from another project into a new one — write a minimal `.vcxproj` (GUID, configs, the shared-items import, the `.ino` as `ClCompile`) and let Visual Micro populate the rest on a real **Build** the first time the project is opened (same fix that resolved an earlier SimpleFOC library-detection issue in this repo's history).
- **The Arduino sketchbook lives under OneDrive**, not plain `Documents` — `C:\Users\finta\OneDrive\Documents\Arduino`. `setup-arduino-deps.ps1` targets this via `[Environment]::GetFolderPath("MyDocuments")`, which resolves correctly; don't hardcode `C:\Users\<user>\Documents`.
- **Many datasheet PDFs carry a permissions-only lock** (blocks copy/paste, blank owner password) that generic PDF readers report as "password-protected" even though they open fine in a viewer. `pikepdf.open(path, password='')` then `.save(dst, encryption=False)` strips it — this is not the same thing as bypassing a real access-restricted document, it's TI/MagnTek-style copy-protection with an empty owner password.
