# HastaArduino

Bench- and wind-tunnel instrumentation for a free-to-pitch / control-surface aircraft model: firmware for one board, the **Pimoroni Pico Plus 2** (RP2350B, no on-board radio) with a **Pimoroni RM2 WiFi/BT breakout on its SP/CE connector**, plus the MATLAB package that drives it. Every rig follows one shape: an Arduino sketch exposes an **SCPI-over-TCP instrument interface**; MATLAB drives it, pulls back binary sample data, and plots.

This file is for a future human or agent picking the repo up cold. It describes **architecture, conventions and traps**, not project-by-project detail. The `.ino` header comments and the doc comments on the MATLAB classes are the detailed, kept-current reference; read those for specifics.

> **Read [Rules for agents](#rules-for-agents-and-safety) before running or changing anything.** This code moves real control surfaces and writes state into the user's MATLAB.

## Contents

1. [Quick start (new machine)](#quick-start-new-machine)
2. [Repo layout](#repo-layout)
3. [How the pieces fit](#how-the-pieces-fit)
4. [Firmware](#firmware): HastaDAQ, wire protocol, HastaDrivers, other rigs
5. [MATLAB](#matlab): package map, client, data model, saved state, scripts
6. [Typical test session](#typical-test-session)
7. [Coding conventions](#coding-conventions): firmware and MATLAB
8. [Testing and verification without hardware](#testing-and-verification-without-hardware)
9. [Rules for agents and safety](#rules-for-agents-and-safety)
10. [Gotchas](#gotchas)
11. [Schematics, wiring, library management](#schematics-wiring-and-library-management)
12. [Open items and unverified assumptions](#open-items-and-unverified-assumptions)

## Quick start (new machine)

1. **WiFi credentials:** copy `HastaDrivers/src/secrets.h.example` to `secrets.h` (gitignored) and fill in `WIFI_SSID` / `WIFI_PASS`.
2. **Toolchain:** run `setup-arduino-deps.ps1` (uses `arduino-cli` and installs exactly what `arduino-deps.txt` pins, into the real Arduino sketchbook, which is under OneDrive here).
3. **Build and flash `HastaDAQ`** with Visual Studio + the Visual Micro extension (the shared `HastaDrivers` include path only exists there), or check that it compiles from a shell, run from the repo root:
   ```
   arduino-cli compile --fqbn rp2040:rp2040:pimoroni_pico_plus_2 --build-property "build.extra_flags=-I<repo>/HastaDrivers/src" --build-property "compiler.cpp.extra_flags=-I<repo>/HastaDrivers/src" HastaDAQ
   ```
   The extra `-I` is needed because plain `arduino-cli` doesn't know about the Visual Micro shared-items project. (Board target: see [open items](#open-items-and-unverified-assumptions).)
4. **Find the board's IP** in the Serial Monitor at boot (`[WiFi] Connected, IP=...`). The scripts hard-code it near the top (`HastaIP` / `boardIP`); edit it there.
5. **MATLAB:** put `matlab/hastadaq` on the path (it holds the `+wt` and `+scripts` packages). The tunnel computer interface (`wt.OHBControl`, `wt.OHBData`) comes from the separate **WtControl toolbox**, which is *not* in this repo and merges into the same `wt` package name.
6. **First-time calibration:** with the model at its zero position, run `scripts.ZeroEncoderRun` once (see [encoder zero](#saved-state-matlab-preferences)).

## Repo layout

```
HastaDAQ/               Flagship firmware: HastaDAQ.ino + sketch-local headers (ChannelMixer, Sensors, CaptureManager)
HastaDrivers/           Shared driver library (Visual Micro "shared items" project); src/ is on every sketch's include path
SbusServoCalibration/   Older rigs, one folder per sketch, folder name == .ino name (Arduino requirement)
EncoderCalibration/
StrainGaugeCalibration/
matlab/hastadaq/        THE MATLAB package for HastaDAQ: +wt/+hasta, +wt/+runNum, +scripts, controlStepResponseTest.m
matlab/common/          MATLAB helpers for the older rigs (TCP connect, binary parsers, FFT/Bode plots)
matlab/sbus|stepper|straingauge/   Per-rig MATLAB scripts for the older rigs
kicad/hastadaq/         KiCad schematic for HastaDAQ (primary electrical reference); kicad/tools/ = bootstrap generator
wiring/                 WireViz cable-level diagrams (secondary; partly stale, see open items)
docs/                   This file
arduino-deps.txt        Pinned core + library versions (source of truth)
setup-arduino-deps.ps1  Installs what arduino-deps.txt pins
HastaArduino.slnx       Visual Studio solution (Visual Micro) referencing the active projects
```

`data/` (captured results) and the Visual Micro build files are **not source**; see [Rules for agents](#rules-for-agents-and-safety).

## How the pieces fit

```
  tunnel computer                         MATLAB (matlab/hastadaq)                       Pico Plus 2 + RM2 (HastaDAQ/)
 +-----------------+   wt.OHBControl    +------------------------------+   TCP :5025   +-----------------------------+
 | OHB server      |<------------------>| scripts.*  (tests, save data)|   SCPI text   | HastaDAQ.ino  SCPI handlers |
 | (force balance, |  external toolbox  | wt.hasta.examples.* (demos)  |<------------->|   setup()/loop(), non-blocking|
 |  incidence,wind)|                    | wt.hasta.DaqClient (handle)  |  UDP stream   | ChannelMixer -> SBUS servos |
 +-----------------+                    | wt.hasta.DaqData/MetaData/...|<--(optional)--| Sensors: MT6835, 2xADS122C04|
                                        | wt.runNum, encoderZero (prefs)|              |          ICM20649 IMU       |
                                        +------------------------------+               | PID, ExcitationGenerator,   |
                                                                                        | TriggerIO, CaptureManager   |
                                                                                        +-----------------------------+
```

* **One instrument, one client.** The board serves one TCP client at a time; a new connection always replaces the old one (last wins).
* **The board is the real-time part; MATLAB is orchestration.** SBUS output, the pitch controller, excitation and capture all run on the board and keep running if MATLAB stalls. MATLAB sets state, triggers, and reads data back.
* **All angles are degrees, centred on 0** (see [servo mapping](#servo-angle-convention)).

## Firmware

### HastaDAQ (flagship)

Five SBUS control surfaces (rudder, 2 elevators, 2 ailerons), an MT6835 pitch encoder with a closed-loop elevator controller, two ADS122C04 ADCs (half-bridge strain gauges) and an ICM20649 IMU on one Qwiic chain, external trigger in/out for syncing with other instruments, SCPI control, and optional continuous UDP streaming.

Every other rig in the repo blocks the whole sketch for a run's duration. HastaDAQ **cannot**: it flies real control surfaces, so SBUS output and the controller must never stop, even mid-capture. It is fully non-blocking: every `loop()` iteration services SCPI, polls the trigger pin, refreshes all sensors, advances the excitation / controller / capture / UDP state machines, and re-sends the SBUS frame. `RUN`/`ARM`/`FIRE` only flip state; they never wait. Use `HastaDAQ.ino` (not the older rigs) as the template for anything with an always-on real-time duty.

`HastaDAQ.ino` is the SCPI handlers plus `setup()`/`loop()`. The logic lives in sketch-local header-only classes included directly (Arduino doesn't auto-build extra `.cpp` files, so header-only was the simple, safe split):

| File | Role |
|---|---|
| `ChannelMixer.h` | `CHANNEL_DEFS[]` (**the one place to rename a servo or move it to another SBUS channel**), per-channel trim / excitation gain / control gain, the `SbusServoBank`, and the `ChanUpdate` struct |
| `Sensors.h` | `SensorHub`: encoder, both ADCs, IMU, all cached and refreshed non-blocking each loop |
| `CaptureManager.h` | `HastaDaqSample` (the 68-byte wire struct), bounded-capture state machine, `UdpStreamer` |

Shared from `HastaDrivers`: `PidController`, `ExcitationGenerator`, `TriggerIO`, `Mt6835Encoder`, `SbusServoBank` and the waveform generators.

**Signal flow, per servo channel, every SBUS frame:**

```
commandedDeg[ch] = trimDeg[ch] + excGain[ch]*excitation(t) + ctrlGain[ch]*controlOutput
```

One shared excitation waveform (sine / 1-cosine / chirp) and one shared PID (error = target - encoder angle) are mixed into each channel by gains in `[-1, +1]`: `0` excludes a channel, equal signs are symmetric, opposite signs differential. The PID runs every loop on its own measured `dt`; there is no separate control rate, just Kp/Ki/Kd. The controller has basic clamped-integration anti-windup (the integral freezes while the output is saturated) and the output is hard-limited to `outLimitDeg`.

**Triggering.** `RUN` = `ARM` (configure a bounded capture) + an immediate internal trigger. `ARM` alone waits for `FIRE` or an edge on the trigger-in pin. Every trigger also pulses trigger-out. Excitation has an **armed vs active** split: `armed` is sticky ("the next trigger should start this"), a trigger turns armed into active after `delayS`, and a bounded excitation (`cycles > 0`) stops itself but **stays armed**, so the next trigger starts it again. Disarm it when done.

#### Servo angle convention

* All angles are **degrees from centre, +/-48.06 deg**. `SbusServoBank` maps them linearly: 1520 us centre = SBUS 1024, 920 / 2120 us = SBUS 64 / 1984 (servos programmed through the Futaba CIU-3 for those end-points).
* Anything commanded past +/-48.06 deg is clamped, and the logged servo angle is the **clamped** value actually sent.
* `chMin` / `chMax` are a per-channel clamp on the raw SBUS count (64..1984), not the angle scale.
* The count-to-microsecond factor (0.625 us per count, Futaba S.BUS convention) is an **unverified assumption**; check that +/-48 deg reaches the servo end-points.

#### Encoder zero

The MT6835 is an **absolute single-turn** encoder, so its raw 0-360 deg reading is the same after every power cycle. The zero the firmware applies is a **software offset held in RAM** (lost on reboot or reflash). It can be described by one number, the raw angle that reads as 0: read it with `ZEROOFFSET?` after `ZERO`, keep it on the PC, and re-apply it with `ZEROOFFSET <deg>` after any restart. Valid only while the encoder and magnet haven't moved relative to the model. Both `ZERO` and `ZEROOFFSET` are refused while the controller is enabled (they would step the PID error).

#### Link handling (WiFi)

* A new SCPI connection **always replaces** the current one; each connection gets `setNoDelay(true)` (replies go out at once) and TCP keepalive (`keepAlive(5, 2, 3)`: intended to notice a dead peer in ~11 s and to stop idle gaps letting the link go quiet). That the keepalive actually takes effect in this build has **not been verified on hardware**.
* The WiFi link is **watched and logged only**; there is deliberately **no automatic re-join**, because `WiFi.begin` blocks and would pause SBUS for seconds. Do not add a blocking reconnect to `loop()`.
* `SYS?` reports uptime (a small value means it rebooted), reset reason (e.g. brownout), WiFi state and RSSI, free heap, connect/disconnect/WiFi-drop counts and the longest `loop()` since last asked. The Serial Monitor logs timestamped connects, disconnects and WiFi changes. These exist to diagnose intermittent "no reply" problems; see [open items](#open-items-and-unverified-assumptions).
* The core already disables WiFi low-power mode after `begin()`, so power-save is not the cause of latency spikes.

### Wire protocol (HastaDAQ)

Newline-terminated ASCII over TCP port 5025; replies end in CRLF (trim them). Setters apply only the fields you send and keep everything else. **Commands that carry a JSON body read it as a second raw line** (the parser splits on commas, so JSON can't be a normal SCPI parameter). Replies are `OK`, a value/JSON line, or `ERR <reason>`.

| Command | Body / reply |
|---|---|
| `*IDN?` | identification string |
| `CHANCONFIG` | JSON object **or array of objects**: `channel` (index 0-4 or a `CHANNEL_DEFS` name), `excGain`, `ctrlGain` (-1..1), `trimDeg`, `chMin`, `chMax`. An array is validated first and then applied **together**, so surfaces start moving in the same SBUS frame; older firmware only accepts one object |
| `CHANCONFIG? <ch>` | JSON of that channel |
| `EXCITE` / `EXCITE?` | `type` (`sine`/`cosine`/`chirp`/`step`/`random`/`stepseq`), `freqHz`, `f0`, `f1`, `periodS`, `amplitudeDeg`, `cycles` (0 = until disarmed), `delayS`, `startOffsetS` + `durationS` (`random`: the slice of the stored turbulence record to play, must fit in 59.98 s else `ERR`), `dwells` (`stepseq`: up to 16 multiples of `periodS`), `armed`; the query adds read-only `active` |
| `CTRLCONFIG` / `CTRLCONFIG?` | `kp`, `ki`, `kd`, `targetDeg`, `outLimitDeg`, `enabled` |
| `RUN` / `ARM` | `{durationS, sampleHz}`; `RUN` arms and triggers at once and replies `OK` immediately |
| `FIRE` | software trigger (errors if nothing armed) |
| `STATUS?` | `ARMED` / `CAPTURING <elapsed>/<duration>` / `DONE <n>` (`DONE` is also the idle state) |
| `DATA?` | header line `BIN <n> <bytesPerSample>` then `n` raw little-endian `HastaDaqSample` records |
| `ENCODER?` | current encoder angle (deg), plain number |
| `ZERO` | software-zero the encoder here |
| `ZEROOFFSET?` / `ZEROOFFSET <deg>` | read / re-apply the saved raw-angle zero |
| `SYS?` | link-health JSON (above) |
| `TRIGCONFIG` / `?` | `outPulseMs`, `inEdge` (`rising`/`falling`) |
| `UDPCONFIG` / `?` | `ip`, `port`, `rateHz`, `enabled` (continuous stream, same record layout as `DATA?`) |

**Sample layout (68 bytes, `static_assert`ed):** `uint32 t_us`, then 16 floats: ADC1 mV, ADC2 mV, encoder deg, accel x/y/z, gyro x/y/z, excitation deg, controller output deg (11 floats), then **5 servo angles in `CHANNEL_DEFS` order** (rudder, elev R, elev L, ail R, ail L). `wt.hasta.DaqData.FromBytes` and `wt.hasta.HDCh` mirror this; change all three together.

Registered commands must stay below `SCPI_MAX_COMMANDS` (32; 21 are registered now) and the library needs `SCPI_HASH_TYPE uint16_t` (see [gotchas](#gotchas)).

### HastaDrivers (shared library)

A Visual Micro **shared items** project (`HastaDrivers.vcxitems`) imported by every sketch's `.vcxproj`. Its `src/` is on every sketch's include path, so `#include <X.h>` resolves there, and so does `#include "secrets.h"`. Header-only and deliberately minimal (an early SimpleFOC-based encoder driver made IntelliSense and compiles painfully slow; see `Mt6835Encoder.h`).

* **Mt6835Encoder.h**: raw-SPI MT6835, continuous unwrapped angle, software zero, the saved-zero pair (`zeroOffsetRawDegrees` / `setZeroOffsetRawDegrees`), and datasheet-confirmed calibration-status / auto-calibration access.
* **SbusServoBank.h**: N servos on one SBUS frame, centred-degree interface and the 64/1024/1984 mapping above. Use it (not `SbusServo.h`) whenever more than one servo is driven.
* **SbusServo.h**: single-channel SBUS output with the RP2040 UART-inversion workaround; used by `SbusServoCalibration`.
* **PidController.h**: live-tunable PID, `update(measurement)` tracks its own `dt`; `reset()` clears the timestamp too (no stale `dt` across enable/disable). `reset()` keeps the gains.
* **ExcitationGenerator.h**: sine / 1-cosine / chirp / step / random / stepseq with `cycles`, `delayS` and the armed/active split. `random` plays `durationS` seconds of `TurbulenceProfile.h` (one 60 s von Karman position record at 50 Hz, peak 1, generated by `matlab/hastadaq/tools/exportTurbulenceProfile.m` from the GustVaneControl generator; linear interpolation, quintic taper over the first/last 10%, auto-stops). `stepseq` holds `-amplitudeDeg` from the trigger for `delayS`, then alternates `+/-amplitudeDeg` for `dwells[i]*periodS` each, then 0 and stops (the stepped chirp). `LinearChirp.h`, `OneMinusCosine.h`, `SweepWave.h` are the generators underneath.
* **TriggerIO.h**: trigger-in (interrupt, configurable edge) and trigger-out (non-blocking pulse). Single instance only.
* **StepperDriver.h**: STEP/DIR stepper, free-run or position-tracking.
* **Controlstate.h/.cpp**: scaffold for a possible dual-core control loop; not used by any active sketch.
* **secrets.h / secrets.h.example**: gitignored WiFi credentials.

### Older rigs

`SbusServoCalibration` (SBUS servo characterisation against an encoder on the output shaft), `EncoderCalibration` (NEMA17 + MT6835 linearity / frequency response), `StrainGaugeCalibration` (ADS122C04 + half bridge). These are the simple blocking-capture pattern (see [firmware conventions](#firmware-1)). Their MATLAB lives in `matlab/common` and `matlab/{sbus,stepper,straingauge}` and uses raw `tcpclient` calls plus per-rig binary parsers; it is **not** part of the `wt.hasta` package. Servo actuation in the repo is SBUS-only; the earlier PWM path and prototypes were removed (see git history).

## MATLAB

The hands-on guide for this package (cookbook, API reference, script template, troubleshooting) is [`matlab/hastadaq/docs/README.md`](../matlab/hastadaq/docs/README.md); this section is the architecture summary.

Everything for HastaDAQ lives in `matlab/hastadaq`, organised as **packages** so it can later be lifted into the `wt` repo wholesale (`+wt/+hasta`, `+wt/+runNum`). Always call things by their **fully qualified name** (`wt.hasta.DaqClient`), in scripts and in the classes themselves; MATLAB packages do not see their siblings by bare name.

```
matlab/hastadaq/
  +wt/+hasta/
    DaqClient.m        the only code that talks to the board (handle class)
    DaqData.m          one capture: a property per signal, per servo angle; mean(), ToTable()
    HDCh.m             enum of the five surfaces (order = servo-angle columns = CHANNEL_DEFS order)
    MetaData.m         per-test-point context (run/test number, test type, ZeroRun, ModelConfig, Parameters)
    ModelConfig.m      model setup (tank type / diameter / fuel mass)
    getLastZeroRun.m   newest zero-run file in data/
    +encoderZero/      get / set / info : the saved encoder zero (a MATLAB preference)
    +examples/         runnable demos, one idea each (see below)
    +testtype/         test-point classes: BaseTestType, Steady, Datum, Zero, ExcitationTest, Sine, Cosine, Chirp, Step
    setupTestEnvironment.m  [hd,ohb,pxi] with the fixed addresses / card as defaults
    ControlSettings.m  controller settings (value class): apply, hold
    runTests.m, TestSession.m  run an array of test points, record, save
  +wt/+runNum/         get / set / increment : the run number (a MATLAB preference)
  +scripts/            the real tunnel tests: ZeroEncoderRun, ZeroRun, AoASweep, AoA_V_Sweep, FreePitchSine, FreePitchChirp, FreePitchCosine, FreePitchStep, FreePitchMixed
  +wt/+pxi/            optional PXI six-axis force sensor: ForceDaq, ForceData, loadCalibration (private/FT78552.cal)
  controlStepResponseTest.m   standalone controller step-response tuning script
  tools/exportTurbulenceProfile.m   bakes the turbulence record into the firmware (HastaDrivers/src/TurbulenceProfile.h)
```

### DaqClient

Creating one: `hd = wt.hasta.DaqClient(ip)` (port 5025, 20 s timeout). Scripts reuse a live `hd` (`if ~exist("hd","var") || ~isvalid(hd)`) because the board serves one client at a time. Public methods, by purpose:

| Group | Methods |
|---|---|
| Connection / health | `identify`, `ping`, `getHealth` (+ static `formatHealth`), properties `TimeoutS`, `MaxAttempts`, `ReconnectCount`, `LastHealth` |
| Surfaces | `setAngle` (fixed angle, zeroes the gains), `setSteady` (disarm excitation + `setAngle`), `setMix` (trim / excGain / ctrlGain, several surfaces in **one** command), `setChannel` / `getChannel` (one channel, also `chMin`/`chMax`) |
| Excitation | `setExcitation`, `getExcitation`, `disarmExcitation` |
| Controller | `setControl`, `enableControl`, `disableControl`, `getControl` |
| Free-to-pitch | `holdPitch` (controller holds a pitch and waits to settle), `openLoopAtEquilibrium` (controller off **without a jolt**, elevators keep their averaged equilibrium angles) |
| Capture | `run`, `arm`, `fire`, `getStatus`, `waitForDone`, `readData`, `capture` (= run + wait + read) |
| Encoder | `getEncoderDeg`, `zeroEncoder`, `getEncoderZeroOffset`, `setEncoderZeroOffset` |
| Triggers / UDP | `setTrigger`/`getTrigger`, `setUdp`/`getUdp` (UDP only configured, not received) |

Behaviour to know:

* **Transport robustness.** Each command goes out as **one write** (command line + JSON body together; two small writes stall on Nagle). A missing reply is retried up to `MaxAttempts` (5) times, reconnecting each time, with `TimeoutS` (20 s) per try; the final error is `DaqClient:noReply`. Queries and the settings commands are simply resent; **`RUN` and `FIRE` are never blindly resent**: after a lost reply the client asks `STATUS?` first and only resends if the board isn't already capturing (`FIRE` refuses to guess if the board is idle: `DaqClient:unverified`). A board `ERR` is reported immediately and never retried.
* **Controller settings are kept.** `setControl` remembers the last Kp/Ki/Kd/target/limit; `enableControl` re-sends them with the enable, and warns (then restores them) if the board's values differ, e.g. after a restart.
* **Synchronised moves.** Multi-surface changes use the array form of `CHANCONFIG`. Against old firmware this falls back to one command per surface with a one-time warning.
* **`setAngle`/`setSteady` zero `excGain` and `ctrlGain`** on the surfaces they move, so nothing else is added on top of the requested angle. `holdPitch` sets the mix back up for closed loop.
* **Errors** use identifiers `DaqClient:<camelCase>` (`noReply`, `boardError`, `badReply`, `badMix`, `badAngle`, ...).
* The firmware must be recent for some calls (`ZEROOFFSET`, `SYS?`, array `CHANCONFIG`); an older board simply doesn't answer an unknown command, which looks like a timeout.

### Data model

* **`DaqData`** is a value class; one object per capture, one row per sample. Properties: `Datetime`, `TimeMs`, `Adc1Mv`, `Adc2Mv`, `EncoderDeg`, `Accel`, `Gyro` (N x 3), `ExcitationDeg`, `ControlOutputDeg`, and **one property per servo: `RUDDER_Angle`, `ELEV_R_Angle`, `ELEV_L_Angle`, `AIL_R_Angle`, `AIL_L_Angle`**; dependent `Time` (s from first sample), `NumSamples`, `ServoAngles` (N x 5, `HDCh` order). `data.Angle(wt.hasta.HDCh.ElevL)` selects one. `data.mean()` condenses to one row (explicit, never automatic: `readData` always returns the full series).
* **`MetaData`** (one per test point): `RunNumber`, `TestNumber` (0-based), `TestType` (`Steady|Datum|Sine|Cosine|Chirp|Step|Random|SteppedChirp|Zero`), `Filename`, `DatumTest` (the `TestNumber` of the Datum a dynamic point is referenced to, else NaN), `ZeroRun` (file of the latest zero run, for zeroing the force sensors in post-processing; nothing is subtracted at acquisition), `ModelConfig`, free-form `Parameters` struct, `Notes`. Constructed with `Name=Value`; `TestType`/`TankType` are validated strings (`mustBeMember`), not enums.
* **Saved files:** `data/Run<NN>_<Test>_<yyyyMMdd_HHmmss>.mat` containing three **parallel arrays of equal length** with one element per test point: `hdData` (`DaqData`), `ohbData` (`wt.OHBData`), `meta` (`MetaData`). Steady-type points (`Steady`, `Datum`, `Zero`) store the averaged `DaqData` and the OHB sample; dynamic points store the full series and a NaN OHB placeholder; `pxiData` (`wt.pxi.ForceData`) is a fourth array, placeholders when the force sensor is off. On any error a `..._partial.mat` with the same variables is written before the error is re-thrown. `data/` is relative to the current folder and is not committed.

### Saved state (MATLAB preferences)

State that must outlive a MATLAB session lives in MATLAB **preferences**, group `wt`; it is per user and per install, not in the repo, and not shared between PCs.

| Preference | Access | Meaning |
|---|---|---|
| `wt/runNumber` | `wt.runNum.get / set / increment` | run counter; every recording script calls `increment` (saves current+1 and returns it) when it starts; unset reads as 1 |
| `wt/encoderZero` | `wt.hasta.encoderZero.get / set / info` | struct `{OffsetDeg, SavedAt}`; `get` errors if never saved |

The board forgets its encoder zero when it restarts, so the test scripts **send the saved offset at start-up** instead of zeroing again. Create it with `scripts.ZeroEncoderRun` (model at zero, flag set), or, if known, `wt.hasta.encoderZero.set(x)`.

### Scripts and examples

* **`scripts.*`** are the tests you run at the tunnel: they need the OHB connection, and save results. They are short: a list of **test points**, then `wt.hasta.setupTestEnvironment` and `wt.hasta.runTests` (see [Test points](#test-points-wthastatesttype)).

  | Script | Does |
  |---|---|
  | `ZeroEncoderRun` | zero the encoder at the model's zero, save the offset (no data recorded) |
  | `ZeroRun` | wind **off**: a `Zero` point (incidence 0, elevators 0, wind checked off, encoder checked ~0) saved as a run |
  | `AoASweep`, `AoA_V_Sweep` | `Steady` points over AoA, elevator angle (and tunnel speed) |
  | `FreePitchSine`, `FreePitchChirp`, `FreePitchCosine`, `FreePitchStep` | model free to pitch: the matching dynamic point type per frequency / amplitude / period / delta, each from a Datum at the target pitch |
  | `FreePitchMixed` | one run mixing sine, chirp, cosine and step points: the template for combining test types |

  All of them take `UsePxi` / `UseCamera` for the force sensor and camera.

* **`wt.hasta.examples.*`** are demos that need only the Hasta DAQ (no tunnel computer, nothing saved): `zero`, `moveServos`, `steady`, `chirp`, `sinewave`, `setupControl`, `pitchTest`, `freePitchChirp`, `freePitchSine`, `freePitchStep`, `freePitchCosine`, plus `testPxi` (checks the PXI card, the trigger loopback and that the PXI's edge starts the board; run it before any `USE_PXI`). They deliberately stay explicit, one idea each, and are the best place to learn the API. The free-pitch ones include the response analysis (FFT ratio for the chirp, least-squares sine fit, step t63/overshoot/settling, cosine peak excursion). Run them as `wt.hasta.examples.chirp`.
* Every script that records data calls `wt.runNum.increment()` (inside `runTests`) when it starts, so each script run gets its own run number. A sweep therefore never shares a number with the `ZeroRun` before it, and the "last zero run is from a different run number" warning it prints is expected.

### Test points (`wt.hasta.testtype`)

A test script is a **heterogeneous array of test points** passed to `wt.hasta.runTests`; mixing types needs no new code.

```matlab
[hd, ohb, pxi] = wt.hasta.setupTestEnvironment(UsePxi=true, UseCamera=true);   % IPs, NI card, sample rate are defaults here
points = [ wt.hasta.testtype.Sine(PitchDeg=5, FreqHz=0.5, Cycles=6)
           wt.hasta.testtype.Chirp(PitchDeg=5, F1Hz=1.5)
           wt.hasta.testtype.Steady(IncidenceDeg=8, ElevatorDeg=-5) ];
results = wt.hasta.runTests(points, Hd=hd, Ohb=ohb, Pxi=pxi, Name="MyRun", ConfirmedAreaClear=true, ...
    Control=wt.hasta.ControlSettings(Kp=0.2));            % defaults: Kp 0.1, Ki 0.2, Kd 0.05, limit 20, CtrlGain -1, tolerance 0.2
```

* **`BaseTestType`** (abstract, `matlab.mixin.Heterogeneous`) has the **condition** every point shares (`IncidenceDeg`, `ElevatorDeg`, `SpeedMs`, `PitchDeg`; NaN = leave alone; `PitchDeg` set means free to pitch with the controller holding it) plus `Camera` and `ForceDatum`. Subclasses: `Steady`, `Datum`, `Zero`, and the dynamic `Sine`, `Cosine`, `Chirp`, `Random` (a slice of the stored turbulence record), `SteppedChirp` (via `ExcitationTest`) and `Step`. A new type is one new class providing `typeName`, `describe` and `run(obj, session)`.
* **`runTests`** creates a `TestSession` (handle: connections, control settings, data so far, current condition, datum) and for each point: `precheck`, bring the rig to the condition (only what differs from the last point), take a **Datum** if the point is dynamic and none is newer than `DatumMaxAgeS` (default 60 s) for that condition (or `ForceDatum` is set), `run`, store the result. It prints the plan and progress with ETA, saves `hdData/ohbData/meta/pxiData`, writes a `_partial` file and calls the point's `recover` (disarm, controller back on) if anything fails, and refuses to run motion points unless `ConfirmedAreaClear=true`.
* **The OHB only returns averages**, so it is sampled only for steady-type points (`Steady`, `Datum`, `Zero`). Dynamic points store a NaN `wt.OHBData` placeholder, and `meta.DatumTest` is the `TestNumber` of the Datum they belong to (the datum's equilibrium is also what the free-pitch dynamic tests switch to open loop from).
* **`wt.hasta.ControlSettings`** (value class) holds the controller settings (`apply(hd)`, `hold(hd, pitchDeg)`); `wt.hasta.setupTestEnvironment` returns `[hd, ohb, pxi]` (only those asked for are connected; connections are kept between calls, `clear functions` forgets them) and sends the saved encoder zero.

## Typical test session

1. Wind **off**, model at its zero position: `scripts.ZeroEncoderRun` (once, or after the encoder / magnet is disturbed).
2. Wind off: `scripts.ZeroRun` (the force-sensor zero for this run).
3. Wind on, then `scripts.AoASweep` / `AoA_V_Sweep` / `FreePitchSine` / `FreePitchChirp` / `FreePitchCosine` / `FreePitchStep` / `FreePitchMixed`. Results are saved to `data/`.
4. The recording scripts increment the run number themselves when they start; use `wt.runNum.set(n)` to correct it if it gets out of step.
5. If MATLAB complains about an unrecognised property after a code update: `clear functions` (connections are kept inside `setupTestEnvironment`; also `clear classes` if needed).

## Coding conventions

### Firmware

Every active WiFi rig follows one shape **except HastaDAQ** (non-blocking, above). For a simple blocking-capture rig copy `StrainGaugeCalibration.ino` or `EncoderCalibration.ino`; for anything that must keep running during a capture copy `HastaDAQ.ino`.

* **SCPI-over-TCP**, port 5025, `Vrekrer_scpi_parser`, flat command names. **Two-line JSON** for structured parameters (second raw line via `interface.readStringUntil('\n')`).
* **`RUN` / `STATUS?` / `DATA?` binary capture**: logging into a fixed sample buffer, replying with an ASCII `BIN <n> <bytes>` header and raw packed records. Binary, not CSV (the ASCII formatting was the slow part). Every sample struct gets a `static_assert(sizeof(...) == N)`.
* **`CYW43_PINS_SPCE` pin table** plus `cyw43_set_pins_wl(...)` as the **first line of `setup()`** (the RM2 is on the SP/CE connector, GP32-GP35).
* **Bounded `while (!Serial)`** (3 s), never indefinite: WiFi + SCPI must come up with no serial monitor open.
* **Always `#define SCPI_HASH_TYPE uint16_t`** (and `SCPI_MAX_COMMANDS 32`) before including the parser.
* **Types used in function signatures go in a header, not the `.ino`.** The Arduino preprocessor inserts function prototypes *above* any struct defined in the `.ino`, so a signature using it fails to compile (`ChanUpdate` lives in `ChannelMixer.h` for this reason).
* **Never block in HastaDAQ's `loop()`**: no `delay()`, no blocking WiFi re-join, bounded stream reads. Anything slow becomes a state machine advanced a step per iteration.
* **Comments explain why.** Long header comments at the top of each file state the design reasoning, units and hardware assumptions; keep them current when behaviour changes (they are the detailed reference this README points to).
* Strings in `F("...")`. Naming: SCPI command handlers are `PascalCase` (`SetChanConfig`, `GetData`), other functions and variables `camelCase`, types `PascalCase`, constants `UPPER_CASE`.

### MATLAB

* **Packages and names.** Fully qualify every reference (`wt.hasta.HDCh.ElevL`). A `classdef` file uses its own bare name only in the `classdef` line and constructor. Class and file names are `PascalCase`; functions and methods `camelCase`; script parameters near the top are `UPPER_SNAKE_CASE` in the examples and `PascalCase` in the tunnel scripts (match the file you are editing). Units go in names: `...Deg`, `...Hz`, `...S`, `...Mv`, `..._ms` for struct fields.
* **Angles** are degrees centred on 0 everywhere in MATLAB too.
* **Classes.** Hardware connections are `handle` classes (`DaqClient`); data and configuration are plain **value classes** (`DaqData`, `MetaData`, `ModelConfig`) so a saved instance is just data. Validate with property validators (`mustBeMember`) rather than enum classes for small closed sets (`TestType`, `TankType`); use an enum only where the member also carries data (`HDCh`).
* **Arguments.** Use `arguments` blocks with `Name=Value` options. For numeric options `NaN` means "omitted, leave unchanged"; for booleans use `[]` as the "omitted" sentinel and convert with `logical(...)` so JSON gets a real `true`/`false` (the firmware ignores `0`/`1` for booleans).
* **Strings** are double-quoted `string`s; build them with `+` and `sprintf`. MATLAB cannot index a literal (`["a","b"](i)`); assign to a variable first.
* **Docs.** First comment line is `%CLASSNAME One-line purpose` (uppercase), then usage examples, then caveats. Anything that moves hardware says so in capitals (`THIS MOVES SURFACES`).
* **Errors** carry an identifier `Class:camelCase` and a message that says what to do next.
* **Tunnel scripts** are thin and functional: header comment (what, prerequisites, safety warning) -> parameters -> build an array of `wt.hasta.testtype` points -> `wt.hasta.setupTestEnvironment` -> `wt.hasta.runTests` (progress with ETA, partial save and `recover` on error, final save, `ConfirmedAreaClear`) -> any wind-down **after** the save. Do not put hardware logic in the script: add it to a test type or to `TestSession`.
* **Examples** stay explicit and follow one skeleton: header comment -> `CONFIRMED_* = false` flag with an `assert` (motion examples) -> parameters -> `wt.hasta.setupTestEnvironment` -> the calls being demonstrated, with progress `fprintf`s -> leave the rig in a stated state. Local functions go at the **end** of a script file.
* **No toolbox dependencies** in the analysis code (plain FFT / least squares, `detrend`, `interp1`), matching the older MATLAB in this repo.
* **Progress output matters.** Long runs print enough that a person can see where they are and what failed.

## Testing and verification without hardware

There is no automated test suite. What is done instead, and what an agent should do:

* **Firmware:** it must compile from the shell (command in [Quick start](#quick-start-new-machine)). That is the only check available without the board.
* **MATLAB static check:** `checkcode` on every changed file (`matlab -batch "checkcode('file.m','-id')"`). Constant `false` safety flags produce "cannot be reached" notes; that is expected.
* **Fake board:** the client and scripts are verified end to end against a small `tcpserver` that speaks the protocol (it must accept one client at a time, like the real board, and can withhold replies to exercise retries). Feed it synthetic data with a known response (e.g. sine gain 0.5, phase -0.5 rad) and check the analysis recovers it. A stand-in `OHBControl` and a copy of `wt.OHBData` are enough to run the tunnel scripts.
* **Mock NI card:** `wt.pxi.ForceDaq` is tested with a stand-in `daq()` function and `MockDaq`/`MockDaqChannel` classes placed first on the path (`readwrite` returns a timetable; when its output goes high it calls a callback standing in for the wire to the board's trigger-in, so the fake board's capture starts on the edge). Needs no NI hardware.
* **Keep tests away from the user's real state:** see the rules below.

## Rules for agents and safety

* **This code moves real control surfaces and a model that may be free to pitch.** Do not run motion scripts or flash firmware unless the user asks. Keep the `CONFIRMED_*` flags `false` by default and never "helpfully" set them. Do not remove the safety `assert`s.
* **Never write to the user's real MATLAB preferences when testing** (`wt/runNumber`, `wt/encoderZero`). A test once overwrote the saved encoder zero with a dummy and the value was lost. Shadow the accessors with fakes in a scratch folder that is first on the path, or use a temporary group. Reading (`wt.runNum.get`, `encoderZero.info`) is fine.
* **`getpref(group, name, default)` creates the preference** when it is missing, so a "read" written that way writes. Check `ispref` first.
* **Don't commit** `data/`, MATLAB autosave `*.asv`, or the Visual Micro build artifacts (`.vcxproj` / `.vcxproj.filters` changes and `__vm/` folders produced by building on this machine). They are machine-generated.
* **Verify anything hardware-safety-relevant against real sources** (datasheets, library source, register maps), not memory. This project has been bitten by guessing (pinouts, calibration procedures) and saved by checking. State what is unverified.
* **Don't change the wire layout in one place only.** Sample struct, `DaqData.FromBytes`, `HDCh` and `CHANNEL_DEFS` move together.
* **Be honest about untested changes.** Say what was run (compile, fake board, `checkcode`) and what was not (the real rig).

## Gotchas

**MATLAB**

* **Stale objects after a class change.** An `hd` created before a property was added keeps the old class and fails with "Unrecognized method, property, or field". `clear functions` (which forgets the connections kept by `setupTestEnvironment`) and `clear classes` if that is not enough. The connection is reused, so this shows up whenever `DaqClient` changes.
* **`readline` on timeout returns empty**, not an error; the client converts that into `DaqClient:noReply` (otherwise it surfaces later as a cryptic `strtrim` error).
* **The board refuses a second client** ("actively refused"); close or `clear` the first (or rely on the replace-old behaviour of current firmware).
* **`onCleanup` is not a reliable restore** when a script errors out; restore state explicitly.
* **Scripts run by package name** (`scripts.AoASweep`, `wt.hasta.examples.chirp`) share the base workspace. `wt.hasta.setupTestEnvironment` keeps the board, OHB and NI-card connections between calls (the board takes one client), so any script can be re-run straight away; `clear functions` closes them.

**Firmware / board**

* **`Vrekrer_scpi_parser` defaults to an 8-bit command hash** and matches purely by hash, so around a dozen commands can silently route to the wrong handler. Always use `SCPI_HASH_TYPE uint16_t`.
* **WiFi needs the CYW43 pin fix** (`CYW43_PINS_SPCE`) before any other hardware touch in `setup()`.
* **`digitalWrite()` resets GPIO pad overrides** (it calls `gpio_set_function()` each time); use `gpio_put()` if an override must stick. `SbusServo.h` uses `SerialUART::setInvertTX/RX()` instead.
* **`SerialUART` numbering:** `Serial1` = UART0, `Serial2` = UART1, and each has its own valid-pin set (GPIO20/21 are UART1-only).
* **Pico Plus 2 stock is RP2350 A2 (erratum RP2350-E9):** a floating input with the internal pull-down on can sit near 2.2 V and read high. `TriggerIO` uses `INPUT_PULLDOWN`; add an external pull-down of 8.2 kOhm or less on trigger-in if it can float.
* **Trigger-in is a 3.3 V input.** RP2350 GPIO 5 V tolerance was *not* confirmed from the datasheet; use a divider (e.g. 2.2 k series, 3.9 k to ground, which also acts as the external pull-down) for a 5 V source.
* **ADS122C04 address jumpers are undocumented by Adafruit.** Bridge one, then confirm the real address with an I2C scan; `HastaDAQ.ino` scans at boot if the second ADC doesn't answer at the guessed `0x41`.
* **Visual Micro project files are machine-generated** (`IncludePath` blobs, `__vm/`); don't hand-copy between projects. Write a minimal `.vcxproj` and let a real **Build** populate it.
* **The Arduino sketchbook lives under OneDrive**; `setup-arduino-deps.ps1` resolves it via `[Environment]::GetFolderPath("MyDocuments")`. Don't hard-code `Documents`.
* **Duplicate libraries break `arduino-cli lib install`** (e.g. two copies of Adafruit Unified Sensor); remove the extra folder.
* **Many datasheet PDFs carry a permissions-only lock** that readers report as password-protected; `pikepdf.open(path, password='')` then `.save(dst, encryption=False)` strips it (copy-protection with an empty owner password, not a real restriction).

## Schematics, wiring and library management

* **KiCad** (`kicad/hastadaq/hastadaq.kicad_sch`, KiCad 10) is the primary electrical reference. Connectivity is by net labels; only the strain-gauge bridges are drawn with wires. Power: 8.4 V bench PSU -> fuse -> `VSERVO` rail, feeding the servos directly and a UBEC whose 5 V output goes through a Schottky into the Pico's VSYS (the **UBEC must be set to 5 V**, VSYS max is 5.5 V, and its input must accept 8.4 V). Sensors run from the Pico's 3V3. Each ADC has 1 k + 100 nF bridge filtering and 10 uF + 100 nF decoupling at the ADC end. The cable is an **8-wire power connector**: pins 1, 8 GND; 2, 7 supply; 3, 6 sensor GND (drawn tied to common GND); 4 trigger out; 5 trigger in.
* `kicad/tools/generate_hastadaq_sch.py` bootstrapped the first draft; **once the schematic is edited in KiCad, the `.kicad_sch` is the source of truth, so don't re-run the generator over it.** Symbols are generic blocks; assign real footprints before a PCB. Headless checks: `kicad-cli sch erc` / `export pdf` (KiCad installs to `%LOCALAPPDATA%\Programs\KiCad\10.0\bin`, not on PATH).
* **WireViz** (`wiring/*.yml`, rendered alongside) is a secondary cable-level view. Regenerate after wiring changes (`wireviz <file>.yml`, Graphviz on PATH) and look at the image before calling it done.
* **Libraries:** `arduino-deps.txt` is the source of truth for the board core and every library version. Re-run `setup-arduino-deps.ps1` after pulling on a new machine, and update the pinned version there whenever you deliberately bump something.

## Open items and unverified assumptions

* **Board target.** Earlier notes say to build with the **"Pimoroni PicoPlus2W"** target because only it defines `PICO_CYW43_SUPPORTED` / `CYW43_PIN_WL_DYNAMIC`. Shell builds with `pimoroni_pico_plus_2` in core 6.1.0 also compile `HastaDAQ`; which target actually works at runtime has not been re-checked on hardware.
* **SBUS count-to-microsecond factor** (0.625 us/count, 1024 = 1520 us) is assumed, not measured.
* **Intermittent "no reply" from the board** during long runs: cause not yet identified (WiFi dropout, a stall, or a stale connection). `SYS?`, the Serial log and the client's `ReconnectCount` exist to find out; an automatic WiFi re-join and the hardware watchdog were deliberately **not** added (they would interrupt SBUS).
* **Second ADS122C04 address** is a guess (`0x41`) with a boot-time scan as the fallback.
* **RP2350 5 V tolerance** of the trigger-in pin is unconfirmed (use a divider).
* **Stale artefacts:** `kicad/hastadaq/hastadaq.pdf`/`.png` still show the old PSU / trigger headers (KiCad wasn't available to re-export), the schematic has not had ERC run since the power-connector change, and the WireViz files in `wiring/` predate the channel reorder and the power connector.
* **Run numbers are per script run**, not per wind on/off cycle (see [Scripts](#scripts-and-examples)); the zero-run "different run number" warning follows from that. If you want one number per wind cycle, only the first script of the cycle should call `increment()` and the others `get()`.
* **PXI force sensor (`wt.pxi`) is only partly verified on real NI hardware.** The card is the PXIe-6363, `"PXI1Slot4_2"` in `daqlist` (the default everywhere). `wt.hasta.examples.steady` has run with it: the card reads forces and its trigger starts the board. Not yet verified: the gauge channel order (check with a known load, `wt.hasta.examples.testPxi`), the calibrated/tared loads, and the camera pulse. Otherwise checked only against a mock `daq`. Assumed: `ai0`-`ai5` are the six gauges in the calibration file's order, `ai6` loops back `ao0`, `ao0` is wired straight to the Arduino trigger-in (it only swings 0 to 3.3 V, so no divider is needed; the divider advice is for the 5 V digital triggers). Keep the external pull-down on trigger-in so the line reads low whenever the NI output is not driving it (card idle or unpowered). The record is lead-in at 0 V, the trigger at 3.3 V for the record, then 0 V so `ao0` ends at zero. `readwrite` blocks MATLAB, so in PXI mode the free-pitch scripts cannot poll the encoder to abort; the step is armed on the board so one hardware edge starts the PXI record, the Arduino capture and the excitation together. Forces are `Matrix x (gaugeVolts - biasVolts)` (N, N.m); the bias is the mean of the zero run; nothing is subtracted at acquisition. `pxiData` is a fourth parallel array saved by every script that records (`ZeroRun`, `AoASweep`, `AoA_V_Sweep` and the four free-pitch scripts; placeholders when `UsePxi` is false). Steady points (and the `ZeroRun` sample) are stored as the mean over the trigger-high window, whose gauge voltages are the tare (`pxi.Forces(zeroData.Gauges)`); dynamic points keep the whole record. The helpers `wt.pxi.connect` (open the card once, line low, board set to a rising edge), `wt.pxi.record` (arm the board, record both on one edge) and `wt.pxi.plotForces` keep the scripts and the `wt.hasta.examples.*` demos (`USE_PXI`, default false; `steady`, `chirp`, `sinewave`, `pitchTest`, the four `freePitch*`) short; `zero`, `moveServos` and `setupControl` record nothing so have no PXI option. The camera pulse (`ctr1`, ~1 ms) is also untested; every recording script and example has `UseCamera` / `USE_CAMERA` (default false, needs the PXI) next to `UsePxi`, which pulses the camera before and after each record (free-pitch scripts: dynamic records only).
* **`step` excitation** holds the amplitude from `delayS` until disarmed (ignores `periodS`/`cycles`). Compile-checked only; reflash the board to get it (and `ZEROOFFSET`, `SYS?`, array `CHANCONFIG`).
* **`random` and `stepseq` excitations are verified only by compiling the firmware and against a MATLAB fake board that reimplements the same formulas** (no host C++ compiler here). The turbulence record is baked in: to change it run `exportTurbulenceProfile` (needs the GustVaneControl repo for the generator, path in `GustVaneMatlabDir`), rebuild and reflash; the board and `wt.hasta.DaqClient.TurbulenceRecordS` must agree on the 59.98 s length.
* **Test-point framework (`wt.hasta.testtype`, `runTests`) is verified only against the fake board and a mock NI card.** It replaces the earlier per-test scripts, whose behaviour it reproduces (hold, equilibrium, open loop at the equilibrium angles, armed excitation, step with abort); the old scripts had run on the rig, this refactor has not. Behaviour that changed on purpose: the OHB is no longer sampled during time series (a Datum is the reference, retaken after `DatumMaxAgeS` = 60 s); the controller defaults are limit 20 deg and tolerance 0.2 deg (were 15 and 0.25); the camera pulses on steady records too when `UseCamera` is on (`Datum` excepted).
* **Controller sign.** Whether a positive controller output reduces pitch error depends on how the elevators are mounted; `ctrlGain = -1` flips it. If the model runs away from a target, that is the first thing to check.
