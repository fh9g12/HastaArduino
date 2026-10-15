# HastaDAQ MATLAB package

The MATLAB side of the HastaDAQ rig: a client for the board's SCPI-over-TCP interface, classes for the data it returns, saved run state, runnable examples, and the test scripts used at the wind tunnel.

This is the hands-on guide for this folder. The whole-system picture (firmware, wire protocol, hardware, repo-wide rules and gotchas) is in [`../../../docs/README.md`](../../../docs/README.md); read its **Rules for agents and safety** section before running or changing anything here. The doc comments inside each class and script are the detailed reference and are kept current; this file tells you where things are and how they are meant to be used.

## Contents

1. [Setup](#setup)
2. [What is where](#what-is-where)
3. [Cookbook](#cookbook)
4. [DaqClient reference](#daqclient-reference)
5. [Data classes](#data-classes)
6. [Saved files and run state](#saved-files-and-run-state)
7. [Scripts and examples](#scripts-and-examples)
8. [Writing a new test script](#writing-a-new-test-script)
9. [Conventions](#conventions)
10. [Testing without hardware](#testing-without-hardware)
11. [Troubleshooting](#troubleshooting)
12. [Moving this into the `wt` repo](#moving-this-into-the-wt-repo)

## Setup

* **MATLAB:** developed and checked on R2025a. The code uses `arguments` blocks and `Name=Value` call syntax, so R2021a or later is required.
* **Path:** add this folder (`matlab/hastadaq`) to the MATLAB path. It contains the `+wt` and `+scripts` packages.
* **External dependency (tunnel scripts only):** `wt.OHBControl` and `wt.OHBData` come from the separate **WtControl toolbox**, which is not in this repo. It uses the same top-level `wt` package name, and the two merge. The examples and the client do not need it.
* **Board:** needs `HastaDAQ` firmware running and its IP address (printed in the Serial Monitor at boot). Scripts keep the IP in a variable at the top (`HastaIP` or `boardIP`). A few calls need recent firmware: `setEncoderZeroOffset` / `getEncoderZeroOffset`, `getHealth`, and the one-command multi-surface moves (an older board still works for the last one, with a warning).
* **First-time calibration:** with the model at its zero position run `scripts.ZeroEncoderRun`, which saves the encoder zero the other scripts rely on.

## What is where

```
matlab/hastadaq/
  +wt/+hasta/
    DaqClient.m          talks to the board; the only code that does   (handle class)
    DaqData.m            one capture: a property per signal and per servo angle   (value class)
    HDCh.m               enum of the five surfaces; order = servo-angle columns
    MetaData.m           context for one test point
    ModelConfig.m        model setup: tank type / diameter / fuel mass
    getLastZeroRun.m     newest zero-run file in data/
    setupTestEnvironment.m   [hd, ohb, pxi]: connections, with the IPs / card / rate as defaults
    ControlSettings.m    controller settings (value class): apply(hd), hold(hd, pitchDeg)
    runTests.m           run an array of test points in order, record, save
    TestSession.m        the state of one run (handle): connections, datum, data so far
    +testtype/           the test points: BaseTestType, Steady, Datum, Zero, ExcitationTest, Sine, Cosine, Chirp, Random, SteppedChirp, Step
    +encoderZero/        get, set, info  : the saved encoder zero
    +examples/           demos needing only the Hasta DAQ
  +wt/+pxi/              optional PXI force sensor (card "PXI1Slot4_2", the PXIe-6363): ForceDaq, ForceData, loadCalibration (private/FT78552.cal), and the helpers connect, record, plotForces
  +wt/+runNum/           get, set, increment : the run number
  +scripts/              tunnel test scripts
  controlStepResponseTest.m   standalone controller step-response tuning
  tools/exportTurbulenceProfile.m   bakes the turbulence record into the firmware (HastaDrivers/src/TurbulenceProfile.h)
  docs/README.md         this file
```

Packages mean **everything is called by its full name** (`wt.hasta.DaqClient`, `wt.hasta.HDCh.ElevL`, `wt.runNum.increment()`); MATLAB packages do not see their siblings by bare name, in scripts or inside the classes.

## Cookbook

All snippets assume `hd = wt.hasta.DaqClient("192.168.1.107");` and the elevators `elev = [wt.hasta.HDCh.ElevL wt.hasta.HDCh.ElevR];`. Anything that moves a surface is marked.

**Connect and check the link**

```matlab
hd = wt.hasta.DaqClient(ip);          % prints *IDN?
rtt = hd.ping();                      % round trip, s; reconnects/retries if needed
h = hd.getHealth();                   % uptime, reset reason, WiFi state/RSSI, longest loop ...
disp(wt.hasta.DaqClient.formatHealth(h))
```

**Put the encoder zero back after the board restarts** (it forgets it)

```matlab
hd.disableControl();                                   % refused while the controller is on
hd.setEncoderZeroOffset(wt.hasta.encoderZero.get());   % saved by scripts.ZeroEncoderRun
```

**Move surfaces to fixed angles** (moves surfaces; degrees from centre, +/-48.06)

```matlab
hd.setAngle(wt.hasta.HDCh.Rudder, 10);
hd.setAngle(elev, 3);                                  % one angle for both, in ONE command
hd.setAngle([wt.hasta.HDCh.AilL wt.hasta.HDCh.AilR], [5 -5]);   % one angle per surface
```

**A steady measurement** (moves surfaces)

```matlab
hd.setSteady(elev, 3, settleS=2);      % angle, no excitation, wait for the servos
data = hd.capture(10, 100);            % record 10 s at 100 Hz, wait, read back -> DaqData
point = data.mean();                   % explicit: one row of averages
```

**An excitation** (moves surfaces)

```matlab
hd.setMix(elev, excGain=1);            % the elevators follow the shared waveform
hd.setExcitation("chirp", f0=0.5, f1=4, periodS=10, amplitudeDeg=1, cycles=1, delayS=1, armed=true);
data = hd.capture(1 + 10 + 2, 100);    % delay + sweep + tail
hd.disarmExcitation();                 % a bounded excitation stays ARMED: always disarm
```

For a sine use `setExcitation("sine", freqHz=1, amplitudeDeg=1, cycles=5, delayS=1, armed=true)`; for a 1-cosine pulse `("cosine", periodS=2, ...)`; for a step `("step", amplitudeDeg=1.5, delayS=2, armed=true)` (jumps to the amplitude at `delayS` and holds until disarmed; `periodS`/`cycles` are ignored).

**Hold a pitch angle with the controller, then excite from equilibrium** (moves surfaces and the model)

```matlab
hd.setControl(Kp=1, Ki=0.2, Kd=0, outLimitDeg=15);    % tune once; the settings are kept
r = hd.holdPitch(5, ctrlGain=1);                       % waits to settle; r.settled, r.pitchDeg, r.errorDeg
eq = hd.capture(4, 100);                               % equilibrium (full series; eq.mean() for the average)
hd.openLoopAtEquilibrium(eq, excGain=1);               % controller off WITHOUT a jolt
hd.setExcitation("sine", freqHz=1, amplitudeDeg=1, cycles=5, delayS=1, armed=true);
resp = hd.capture(1 + 5 + 2, 100);
hd.disarmExcitation();
hd.holdPitch(5);                                       % controller back on to hold the model
```

If the model runs away from the target instead of settling, the controller's sign is wrong: use `ctrlGain=-1`. To keep the controller running during the excitation use `hd.setMix(elev, excGain=1)` instead of `openLoopAtEquilibrium`.

**A saved run: load it and look**

```matlab
s = load("data/Run09_FreePitch_20261014_182038.mat");   % -> s.hdData, s.ohbData, s.meta
types  = [s.meta.TestType];                             % string array, one per point
sines  = s.hdData(types == "Sine");                     % the sine records
d = sines(1);
plot(d.Time, d.EncoderDeg, d.Time, d.ELEV_L_Angle)      % any signal by name
plot(d.Time, d.ServoAngles)                             % all five servos, N x 5
d.Angle(wt.hasta.HDCh.ElevL)                            % one servo by enum
T = d.ToTable();                                        % everything as a table
s.meta(2).Parameters.Excitation.freqHz                  % the test point's settings
s.meta(2).ZeroRun                                       % the zero-run file for post-processing
```

## DaqClient reference

`hd = wt.hasta.DaqClient(boardIP, port=5025, timeoutS=20)`. Public settings: `TimeoutS` (reply timeout, default 20 s), `MaxAttempts` (default 5); read-only: `ReconnectCount`, `LastHealth`, `BoardIP`, `Port`; constant `MaxAngleDeg` (48.06). Options not given are **left unchanged** on the board.

| Method | Options / returns | Notes |
|---|---|---|
| `identify`, `ping`, `getHealth` | `rttS`; health struct | `getHealth` needs recent firmware; `formatHealth` (static) makes a one-line summary |
| `setAngle(surface, angleDeg)` | one angle or one per surface | trim = angle and `excGain = ctrlGain = 0` on those surfaces; angles outside +/-48.06 error |
| `setSteady(surface, angleDeg, settleS=0)` | | disarms excitation, then `setAngle`, then waits `settleS` |
| `setMix(surface, trimDeg=, excGain=, ctrlGain=)` | each: one value or one per surface | several surfaces in **one** command; `excGain`/`ctrlGain` in [-1, 1] |
| `setChannel(channel, excGain=, ctrlGain=, trimDeg=, chMin=, chMax=)` | | one channel; `channel` = `HDCh`, a name string or 0-4; `chMin/chMax` clamp raw SBUS counts (64..1984) |
| `getChannel(channel)` | struct | |
| `setExcitation(type, freqHz=, f0=, f1=, periodS=, amplitudeDeg=, cycles=, delayS=, startOffsetS=, durationS=, dwells=, armed=)` | `type` = `"sine" \| "cosine" \| "chirp" \| "step" \| "random" \| "stepseq"` | `cycles=0` runs until disarmed; arming does not move anything until a trigger |
| `getExcitation`, `disarmExcitation` | struct | `active` in the struct is read-only |
| `setControl(Kp=, Ki=, Kd=, targetDeg=, outLimitDeg=, enabled=)` | | settings are remembered; `enabled` takes a logical |
| `enableControl`, `disableControl`, `getControl` | struct | `enableControl` re-sends the remembered settings and warns if the board's differ |
| `holdPitch(targetDeg, surfaces=, ctrlGain=1, toleranceDeg=0.25, stableS=1, timeoutS=30, pollS=0.1)` | `r.settled, pitchDeg, errorDeg, timeS` | surfaces default to both elevators; sets trim 0, `excGain` 0, `ctrlGain`; warns (does not error) if it can't settle |
| `capture(durationS, sampleHz=100)` | `DaqData` | `run` + `waitForDone` + `readData` |
| `openLoopAtEquilibrium(eq, surfaces=, excGain=0)` | trims used | trims = mean elevator angles in `eq`, sent with `ctrlGain=0` in one command, then the controller is disabled |
| `run`, `arm`, `fire`, `getStatus`, `waitForDone(timeoutS=60)`, `readData` | status struct: `state` (`ARMED/CAPTURING/DONE`), `elapsedS`, `durationS`, `nSamples` | the low-level capture steps |
| `getEncoderDeg`, `zeroEncoder` | | `zeroEncoder` is refused (error) while the controller is on |
| `getEncoderZeroOffset`, `setEncoderZeroOffset(deg)` | raw angle (0-360) that reads as 0 | see [run state](#saved-files-and-run-state) |
| `setTrigger(outPulseMs=, inEdge=)`, `getTrigger` | `inEdge` = `"rising" \| "falling"` | external trigger in/out |
| `setUdp(ip=, port=, rateHz=, enabled=)`, `getUdp` | | configures the stream; receiving it is up to you (`udpport`) |

**Robustness built in.** Each command is sent as one write. If the board doesn't reply within `TimeoutS` the client reconnects and tries again, up to `MaxAttempts`; the final failure is `DaqClient:noReply`. Queries and settings are simply resent. `run` and `fire` are *not* blindly resent: the client asks `STATUS?` first and only resends if the board isn't already capturing (`fire` refuses to guess when the board is idle: `DaqClient:unverified`). A board `ERR` reply is raised at once as `DaqClient:boardError` and never retried.

## Data classes

**`wt.hasta.DaqData`**: one capture, one row per sample, as a value class.

* Properties: `Datetime`, `TimeMs`, `Adc1Mv`, `Adc2Mv`, `EncoderDeg`, `Accel` and `Gyro` (N x 3), `ExcitationDeg`, `ControlOutputDeg`, and one per servo: `RUDDER_Angle`, `ELEV_R_Angle`, `ELEV_L_Angle`, `AIL_R_Angle`, `AIL_L_Angle`.
* Dependent: `Time` (seconds from the first sample), `NumSamples`, `ServoAngles` (N x 5 in `HDCh` order).
* Methods: `Angle(surface)`, `mean()` (condense to one row; works on arrays; never applied automatically), `ToTable()`, `ToStruct()`; static `FromBytes` builds one from the raw `DATA?` payload.
* The servo angle is the **commanded** angle after the +/-48.06 deg clamp, in degrees from centre.

**`wt.hasta.HDCh`**: enum `Rudder, ElevR, ElevL, AilR, AilL`. `.WireName` is the firmware's name (`"ELEV_L"`), `.column()` the index into `ServoAngles`. A string with a member's name (`"ElevL"`) converts automatically where an `HDCh` is expected. Its order must match `CHANNEL_DEFS` in the firmware.

**`wt.hasta.MetaData`**: `RunNumber`, `TestNumber` (0-based), `TestType` (`Steady|Datum|Sine|Cosine|Chirp|Step|Random|SteppedChirp|Zero`), `Filename`, `ZeroRun`, `ModelConfig`, `Parameters` (free-form struct of the point's set-points), `Notes`, `Datetime`. Build with `Name=Value`; an unknown name or invalid `TestType` errors.

**`wt.hasta.ModelConfig`**: `TankType` (`"Solid"|"Liquid"`), `TankDiameter_mm`, `FuelMass_g` (NaN = not set).

## Saved files and run state

**Result files** are written by the tunnel scripts to `data/` (relative to the current folder, not committed) as `Run<NN>_<Name>_<yyyyMMdd_HHmmss>.mat`, each holding three **parallel arrays of equal length**, one element per test point:

| Variable | Class | Holds |
|---|---|---|
| `hdData` | `wt.hasta.DaqData` | steady points: the averaged row (`mean()`); dynamic points: the full time series |
| `ohbData` | `wt.OHBData` | the tunnel computer's sample for the same point (force balance, wind, ...) |
| `meta` | `wt.hasta.MetaData` | context for the point |

If a script stops on an error it first writes `..._partial.mat` (same variables, what was completed) and then re-throws. `wt.hasta.getLastZeroRun()` returns the newest `*_ZeroRun_*.mat`; the sweeps record it in `meta.ZeroRun` so the force sensors can be zeroed in post-processing. **Nothing is subtracted at acquisition.**

**Run state** that must outlive a session lives in MATLAB **preferences** (group `wt`): per user and per MATLAB install, not in the repo, not shared between PCs.

| Preference | Access | Meaning |
|---|---|---|
| `wt/runNumber` | `wt.runNum.get`, `.set(n)`, `.increment()` | run counter; every recording script calls `increment` (saves current+1 and returns it) when it starts; unset reads as 1 |
| `wt/encoderZero` | `wt.hasta.encoderZero.get`, `.set(deg)`, `.info()` | struct `{OffsetDeg, SavedAt}`; `get` errors if never saved |

The board forgets its encoder zero on restart, so scripts **send the saved offset at start-up** instead of zeroing again. It is valid while the encoder and its magnet have not moved relative to the model: redo `scripts.ZeroEncoderRun` if they have, or if a run's `ZeroRun` check warns that the encoder doesn't read ~0 at zero incidence. These accessors never write when you only read; keep it that way (see [Conventions](#conventions)).

## Scripts and examples

**`scripts.*`** are the tunnel tests (they use the OHB connection and save data). Run them by name, e.g. `scripts.ZeroRun`. Each is a short list of test points (see below) handed to `wt.hasta.runTests`.

| Script | Purpose |
|---|---|
| `ZeroEncoderRun` | zero the encoder at the model's zero position and save the offset (flag `CONFIRMED_MODEL_AT_ZERO`) |
| `ZeroRun` | wind **off**: a `Zero` point: incidence 0, elevators 0, wind checked off, encoder checked ~0, one sample saved as a run |
| `AoASweep`, `AoA_V_Sweep` | `Steady` points over AoA and elevator angle (and tunnel speed, ramped in steps of at most 5 m/s) |
| `FreePitchSine` | model free to pitch, **stepped sine**: one `Sine` per frequency in `FreqsHz`, per target pitch |
| `FreePitchChirp` | model free to pitch, **chirp**: one `Chirp` (`F0Hz` to `F1Hz` over `PeriodS`) per amplitude |
| `FreePitchCosine` | model free to pitch, **1-cosine pulse**: one `Cosine` per period x amplitude |
| `FreePitchStep` | model free to pitch, **step response**: one `Step` per target and delta. The Datum gives the target's elevator angles, the controller holds the model `delta` away, then an **armed `step` excitation** steps the elevators back, timed on the board. Without the force sensor the encoder is polled and the controller re-engaged if the model strays more than `|delta| + OvershootAllowanceDeg` (flagged `Aborted`) |
| `FreePitchMixed` | the template for **mixing** test types in one run (sine, chirp, cosine and step at one pitch) |

All of them take `UsePxi` / `UseCamera` (default false, or as you set them) for the force sensor and camera.

### Test points

A test point is a **condition** (what the rig is set to) plus a **measurement**. They are classes in `wt.hasta.testtype` with a common base, so one array can mix them:

```matlab
[hd, ohb, pxi] = wt.hasta.setupTestEnvironment(UsePxi=true, UseCamera=true);   % addresses, card and rate are defaults inside
points = [ wt.hasta.testtype.Sine(PitchDeg=5, FreqHz=0.5, AmplitudeDeg=2, Cycles=6)
           wt.hasta.testtype.Chirp(PitchDeg=5, F0Hz=0.2, F1Hz=1, PeriodS=30)
           wt.hasta.testtype.Cosine(PitchDeg=5, PeriodS=2, AmplitudeDeg=-5)
           wt.hasta.testtype.Step(PitchDeg=5, DeltaPitchDeg=-3)
           wt.hasta.testtype.Steady(IncidenceDeg=8, ElevatorDeg=-5, SpeedMs=30) ];
% grow it in a loop with:  points(end+1) = wt.hasta.testtype.Sine(...);   (start from  wt.hasta.testtype.BaseTestType.empty)
results = wt.hasta.runTests(points, Hd=hd, Ohb=ohb, Pxi=pxi, Name="MyRun", ...
    ModelConfig=wt.hasta.ModelConfig(TankType="Liquid", TankDiameter_mm=50, FuelMass_g=165), ...
    Control=wt.hasta.ControlSettings(), HomePitchDeg=0, ConfirmedAreaClear=true);
% results.hdData, .ohbData, .meta, .pxiData, .filename   (also saved to data/)
```

| Type | `TestType` saved | Measurement |
|---|---|---|
| `Steady` | Steady | hold the condition, sample `DurationS` (OHB + board + force), save the averages |
| `Datum` | Datum | the same, as the reference for dynamic points; the runner takes these itself |
| `Zero` | Zero | wind-off zero sample (incidence 0, elevators 0) |
| `Sine`, `Cosine`, `Chirp` | Sine / Cosine / Chirp | one armed waveform on `Surfaces` (default both elevators), `DelayS` before and `TailS` after, from the Datum's equilibrium (or on top of the fixed `ElevatorDeg`) |
| `Random` | Random | a gust: `DurationS` of the board's stored von Karman turbulence record from `StartOffsetS` (default 0: the same settings always give the same gust; use explicit offsets for a quasi-random series, or NaN to draw one when the point is created, saved in `meta.Parameters.Excitation.startOffsetS`), scaled by `AmplitudeDeg`, tapered at both ends |
| `SteppedChirp` | SteppedChirp | stepped square wave about the nominal: to `-DeltaDeg/2` and settle `SettleS`, then `+DeltaDeg/2` for `Dwells(1)*DeltaTS`, `-DeltaDeg/2` for `Dwells(2)*DeltaTS`, ... (default `Dwells = [3 2 1 1]`), then back to nominal; `NominalDeg` NaN = the Datum's equilibrium (free to pitch) or the fixed `ElevatorDeg` |
| `Step` | Step | free-pitch step response (needs `PitchDeg`) |

**Condition fields** (NaN = leave that part of the rig alone): `IncidenceDeg`, `ElevatorDeg` (fixed elevators), `SpeedMs`, and `PitchDeg` (the controller holds this encoder angle: free to pitch; leave it NaN and the controller is off). The runner only changes what differs from the previous point. Other settings on every point: `Camera` (pulse the camera around this record when the force sensor's camera is on) and `ForceDatum` (take a fresh Datum first).

**The datum.** The OHB only returns averages, so it is sampled only for steady-type points. Dynamic points store a NaN `wt.OHBData` placeholder, and the runner makes sure there is a `Datum` for their condition, no older than `DatumMaxAgeS` (default 60 s; `runTests(..., DatumMaxAgeS=...)`), taking one when needed. `meta.DatumTest` is the `TestNumber` of the Datum a dynamic point belongs to. Put a `Datum` in the array yourself, or set `ForceDatum=true` on a point, to take one at a moment you choose.

**Controller.** `wt.hasta.ControlSettings(Kp=, Ki=, Kd=, OutLimitDeg=, CtrlGain=, ToleranceDeg=, Surfaces=)`, defaults 0.1 / 0.2 / 0.05 / 20 / -1 / 0.2 / both elevators. `runTests` applies it and stores it in every point's `meta.Parameters.Control`.

**Adding a test type** is one class in `+testtype`: subclass `BaseTestType` (or `ExcitationTest` for another waveform), provide `typeName`, `describe`, `durationS` and `run(obj, session)`, and add its name to the `TestType` list in `MetaData`. `run` uses the session (`session.Hd`, `.Ohb`, `.Pxi`, `.Control`, `.Datum`, `session.ensureHeld(pitchDeg)`, `session.recordSteady(...)`, `session.recordDynamic(...)`, `session.markDisturbed()`) and returns a struct: `Hd`, `Ohb`, `Pxi`, `StartTime`, `Parameters`. Give it a `recover(obj, session)` that leaves the rig safe if it fails mid-way.

**Force sensor.** `wt.hasta.setupTestEnvironment(UsePxi=true)` connects it and puts the board's trigger input on a rising edge; every recording then starts the board and the PXI on the same hardware edge and saves a fourth parallel array, `pxiData` (placeholders when off). Steady-type points hold the mean over the trigger-high window (the zero run's `Gauges` are the tare: `pxiData(k).Forces(zeroData.Gauges)`); dynamic points keep the whole record. The lower-level helpers are `wt.pxi.connect(hd, card, rate)`, `wt.pxi.record(hd, forceDaq, durationS, sampleHz)` and `wt.pxi.plotForces`. `UseCamera` pulses the tracking camera before and after each record (it is a property of the force sensor: `pxi.Camera`). While the PXI records MATLAB is blocked, so the step test's abort cannot run.

**Turbulence record.** The `Random` gusts all come from one 60 s record baked into the firmware (`HastaDrivers/src/TurbulenceProfile.h`). To regenerate it (different seed or time scale): `addpath("matlab/hastadaq/tools"); exportTurbulenceProfile(Seed=2, TimeScale_s=1.5)`, which uses the generator in the GustVaneControl repo (`GustVaneMatlabDir`, default `C:\git\GustVaneControl\matlab`), then rebuild and reflash.

A `Step` point records `TargetPitch_deg`, `DeltaPitch_deg`, `StepFromDeg` / `StepToDeg` (the elevator angles stepped between), `StepAmplitudeDeg`, `StepGains`, `PreStepS` / `PostStepS`, `StepDelayS` and `StepTimeS` (when the recorded elevator angle actually changed; NaN if the point aborted before the step), `PitchExcursionDeg`, and `Aborted` / `AbortS`.

**`wt.hasta.examples.*`** need only the Hasta DAQ (no tunnel computer, nothing saved) and are the best place to learn the API: `zero`, `moveServos`, `steady`, `chirp`, `sinewave`, `setupControl`, `pitchTest`, `freePitchChirp`, `freePitchSine`, `freePitchStep`, `freePitchCosine`, plus `testPxi` (checks the PXI card, the trigger loopback and that the PXI's edge starts the board; run it before any `USE_PXI`). The free-pitch ones also estimate the response (chirp: FFT ratio; sine: least-squares gain and phase; step: time to 63%, overshoot, 5% settling; cosine: peak excursion and when). They get their connections from `wt.hasta.setupTestEnvironment` and stay explicit on purpose (one idea each). Motion examples start with a `CONFIRMED_AREA_CLEAR = false` flag that stops the script until you set it true. `controlStepResponseTest.m` (in this folder) steps the pitch target during a capture to help tune Kp/Ki/Kd.

**Run numbers.** `runTests` calls `wt.runNum.increment()` when it starts, so each run of a script gets its own run number and there is normally no need to increment by hand (pass `RunNumber=` to override). A consequence: a sweep never shares a run number with the `ZeroRun` before it, so the "last zero run is from a different run number" warning is expected with this convention.

## Writing a new test script

A tunnel script is a short, functional list: build the points, set up, run, wind down after the save. Do not put hardware logic in the script.

```matlab
% MyTest: what it does, in a few lines. What must be done first (ZeroEncoderRun, ZeroRun).
% THIS MOVES THE SURFACES. <the one thing most likely to go wrong, and what to do>

PitchDeg = 5;  FreqsHz = 0.3:0.1:0.9;                 % parameters, with the units in the names
UsePxi = false;  UseCamera = false;
modelConfig = wt.hasta.ModelConfig(TankType="Liquid", TankDiameter_mm=50, FuelMass_g=165);   % <-- fill in

points = wt.hasta.testtype.BaseTestType.empty;
for f = FreqsHz
    points(end+1) = wt.hasta.testtype.Sine(PitchDeg=PitchDeg, FreqHz=f);   %#ok<SAGROW>
end

[hd, ohb, pxi] = wt.hasta.setupTestEnvironment(UsePxi=UsePxi, UseCamera=UseCamera);
results = wt.hasta.runTests(points, Hd=hd, Ohb=ohb, Pxi=pxi, Name="MyTest", ModelConfig=modelConfig, ...
    HomePitchDeg=0, ConfirmedAreaClear=true);
[hdData, ohbData, meta, pxiData] = deal(results.hdData, results.ohbData, results.meta, results.pxiData);
% wind down here, AFTER the data is saved
```

Checklist: a clear warning in the header if it moves things; parameters at the top; state left in a **stated** condition at the end; no new toolbox dependency; run `checkcode` and exercise it against a fake board before it goes near the rig. If you need behaviour that is not a point type yet, add a type (see above) rather than loops of `hd.` calls in the script.

## Conventions

* **Names.** Classes and files `PascalCase`; functions and methods `camelCase`; the parameters at the top of a script are `UPPER_SNAKE_CASE` in the examples and `PascalCase` in the tunnel scripts (match the file you edit). Units in names: `...Deg`, `...Hz`, `...S`, `...Mv`, `..._ms`. **Angles are degrees from centre, everywhere.**
* **Classes.** Hardware connections are `handle` classes; data and configuration are plain **value classes** so a saved instance is just data. Small closed sets (`TestType`, `TankType`) use `mustBeMember` on a string property, not enums; an enum is used only where each member also carries data (`HDCh`).
* **Arguments.** `arguments` blocks with `Name=Value` options. `NaN` means "omitted, leave unchanged" for numeric options; `[]` for booleans, converted with `logical(...)` so JSON carries a real `true`/`false` (the firmware ignores `0`/`1`).
* **Strings** are double-quoted `string`s. MATLAB cannot index a literal (`["a","b"](i)`): assign it to a variable first.
* **Errors** have an identifier `Class:camelCase` and say what to do next.
* **Doc comments:** the first line is `%CLASSNAME One-line purpose`, then usage, then caveats; anything that moves hardware says so in capitals.
* **State and safety.** Never use `getpref(group, name, default)` to read: it **creates** the preference when it is missing (check `ispref` first). Tests must not write to the user's real preferences (`wt/runNumber`, `wt/encoderZero`); shadow the accessors with fakes instead. Don't use `onCleanup` as the only way to restore state: it does not reliably run when a script errors out.
* **No toolbox dependencies** in analysis code (plain FFT, least squares, `detrend`, `interp1`).
* **Keep the wire layout in step.** `DaqData.FromBytes`, `HDCh` and the firmware's `HastaDaqSample` / `CHANNEL_DEFS` change together.

## Testing without hardware

There is no test suite. What is done, and should be done for any change:

1. **`checkcode`** on every file you touched (`matlab -batch "checkcode('<file>','-id')"`). Constant `false` safety flags produce "cannot be reached" notes; that is expected.
2. **A fake board.** The client and the scripts are checked end to end against a small `tcpserver` that speaks the protocol. Make it accept **one client at a time** (like the real board), read the JSON second line for the commands that take one, and be able to *withhold* a reply to exercise the retry paths.

   ```matlab
   srv = tcpserver("127.0.0.1", 5099);  configureTerminator(srv, "LF");
   configureCallback(srv, "terminator", @fakeBoard);       % fakeBoard(src,~) reads a line, writes a reply
   hd = wt.hasta.DaqClient("127.0.0.1", 5099, 2);          % short timeout for the test
   ```

   Return synthetic `DATA?` records with a **known response** (e.g. a sine through gain 0.5 and a 0.5 rad lag) and check the analysis recovers it. For the tunnel scripts a stand-in `OHBControl` (a handle class with `connected`, `sample`, `readLastSample`, `readWindSpeed`, `moveIncidence`) and a copy of `wt.OHBData` are enough.
3. **A mock NI card** for the PXI code: a stand-in `daq()` function (first on the path) returning a `MockDaq` whose `readwrite` gives a timetable and calls a callback when the output goes high, standing in for the wire to the board's trigger-in so the fake board's capture starts on the edge.
4. **Keep tests away from the real preferences:** put a folder containing stand-in `+wt/+hasta/+encoderZero/get.m` (and similar) **first** on the path for the test.
5. Report what you ran (`checkcode`, fake board) and what you did not (the real rig).

## Troubleshooting

| You see | Cause / fix |
|---|---|
| `Unrecognized method, property, or field 'X' for class 'wt.hasta.DaqClient'` | an `hd` made before the class changed keeps the old definition: `clear functions` (it forgets the connections kept by `setupTestEnvironment`), then `clear classes` if needed |
| `No reply from the board to <cmd> after N attempt(s) ...` (`DaqClient:noReply`) | WiFi dropped, the board reset, or a stale connection. Check `hd.getHealth()` (uptime, reset reason, RSSI) and the board's Serial Monitor; `hd.ReconnectCount` shows how often it recovered |
| `actively refused` / can't connect | the board serves one client; close the other session (`clear functions`), or reset the board |
| `No encoder zero has been saved yet` | run `scripts.ZeroEncoderRun` (model at zero) or `wt.hasta.encoderZero.set(x)` |
| `ERR control loop enabled -- CTRLCONFIG enabled:false first` | `ZERO` / `ZEROOFFSET` are refused while the controller runs: `hd.disableControl()` first |
| warning: board's control settings differ ... did the board restart? | the board lost its settings (likely a reboot); the client re-applied yours. Check `getHealth` for a brownout |
| warning: firmware can't move several surfaces in one command | older firmware: moves work but aren't synchronised; reflash |
| `Pitch did not settle ...` | gains too soft/aggressive, wrong `ctrlGain` sign (model running away), or target out of reach of `outLimitDeg` |
| a command that never gets a reply on a new feature | the board's firmware is older than the feature (`SYS?`, `ZEROOFFSET`) |
| `Unrecognized function or variable` for `wt.OHBControl` / `wt.OHBData` | the WtControl toolbox isn't on the path (tunnel scripts only) |

## Moving this into the `wt` repo

The code is arranged for this. To move it:

* Copy `+wt/+hasta` and `+wt/+runNum` into the `wt` repo's `+wt` folder (packages merge; `OHBControl` / `OHBData` already live there). Nothing in them depends on this folder's location.
* The preference names (`wt/runNumber`, `wt/encoderZero`) are fixed strings in `+wt/+runNum/private/runNumPref.m` and `+wt/+hasta/+encoderZero/private/zeroPref.m`; moving the code keeps existing saved values.
* `+scripts` and `controlStepResponseTest.m` are tests specific to this rig; keep or move them as suits. They call everything by the full `wt.hasta` / `wt.runNum` names, so they still work after the move.
* The firmware contract that the classes depend on is the command set and the 68-byte sample layout described in [`../../../docs/README.md`](../../../docs/README.md); keep that document with the firmware.
