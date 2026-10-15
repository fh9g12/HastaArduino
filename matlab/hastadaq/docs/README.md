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
    +encoderZero/        get, set, info  : the saved encoder zero
    +examples/           demos needing only the Hasta DAQ
  +wt/+pxi/              optional PXI force sensor: ForceDaq, ForceData, loadCalibration (private/FT78552.cal)
  +wt/+runNum/           get, set, increment : the run number
  +scripts/              tunnel test scripts
  controlStepResponseTest.m   standalone controller step-response tuning
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
| `setExcitation(type, freqHz=, f0=, f1=, periodS=, amplitudeDeg=, cycles=, delayS=, armed=)` | `type` = `"sine" \| "cosine" \| "chirp" \| "step"` | `cycles=0` runs until disarmed; arming does not move anything until a trigger |
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

**`wt.hasta.MetaData`**: `RunNumber`, `TestNumber` (0-based), `TestType` (`Steady|Sine|Cosine|Chirp|Step|Zero`), `Filename`, `ZeroRun`, `ModelConfig`, `Parameters` (free-form struct of the point's set-points), `Notes`, `Datetime`. Build with `Name=Value`; an unknown name or invalid `TestType` errors.

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

**`scripts.*`** are the tunnel tests (they use the OHB connection and save data). Run them by name, e.g. `scripts.ZeroRun`.

| Script | Purpose |
|---|---|
| `ZeroEncoderRun` | zero the encoder at the model's zero position and save the offset (flag `CONFIRMED_MODEL_AT_ZERO`) |
| `ZeroRun` | wind **off**: incidence 0, send saved zero, check encoder ~0, take a sample, save as a run |
| `AoASweep`, `AoA_V_Sweep` | steady points over AoA (and tunnel speed), with an elevator-angle sweep at chosen AoAs |
| `FreePitchSine` | model free to pitch, **stepped-sine sweep**: per target pitch, controller hold -> equilibrium sample -> one sine per frequency in `SineFreqsHz`, each from that equilibrium |
| `FreePitchChirp` | model free to pitch, **chirp**: same flow, with a chirp (`ChirpF0Hz` to `ChirpF1Hz` over `ChirpPeriodS`) for each amplitude in `ChirpAmplitudesDeg` |
| `FreePitchCosine` | model free to pitch, **1-cosine pulse**: same flow, one pulse per `CosinePeriodsS` x `CosineAmplitudesDeg`, with `CosineDelayS` quiet before and `TailS` free response after |
| `FreePitchStep` | model free to pitch, **step response**: per target pitch and per `DeltaPitchDeg`: hold the target (record the elevator angles that hold it), hold the model `delta` away, switch the controller off at those angles, then an **armed `step` excitation** steps the elevators back to the target's angles `PreStepS` after the capture starts (timed on the board). Without PXI it polls the encoder while recording and re-engages the controller if the model strays more than `|delta| + OvershootAllowanceDeg` (flagged `Aborted`) |

**Force sensor.** `ZeroRun`, `AoASweep`, `AoA_V_Sweep` and the four free-pitch scripts all have `UsePxi` (default false). On, the PXI six-axis sensor is recorded on the same trigger edge as the board and saved as a fourth parallel array, `pxiData` (placeholders when off). Steady points and the zero run hold the mean over the trigger-high window (the zero run's `Gauges` are the tare: `pxiData(k).Forces(zeroData.Gauges)`); dynamic points keep the whole record. The helpers are `wt.pxi.connect(hd, card, rate)`, `wt.pxi.record(hd, forceDaq, durationS, sampleHz)` and `wt.pxi.plotForces`; the examples `steady`, `chirp`, `sinewave`, `pitchTest` and `freePitch*` take `USE_PXI` and print/plot untared loads (`zero`, `moveServos` and `setupControl` record nothing). `UseCamera` / `USE_CAMERA` (default false, needs the PXI) pulses the tracking camera before and after each record. While the PXI records MATLAB is blocked, so the step script's abort cannot run.

The four free-pitch scripts share a flow and a data layout: each target gives a `Steady` point (the averaged equilibrium) followed by the dynamic points (`Sine`, `Chirp`, `Cosine` or `Step`, full time series with their settings in `meta.Parameters`). A `Step` point records `TargetPitch_deg`, `DeltaPitch_deg`, `StepFromDeg` / `StepToDeg` (the elevator angles stepped between), `StepAmplitudeDeg`, `StepGains`, `PreStepS` / `PostStepS`, `StepDelayS` and `StepTimeS` (when the recorded elevator angle actually changed; NaN if the point aborted before the step), `PitchExcursionDeg`, and `Aborted` / `AbortS`.

**`wt.hasta.examples.*`** need only the Hasta DAQ (no tunnel computer, nothing saved) and are the best place to learn the API: `zero`, `moveServos`, `steady`, `chirp`, `sinewave`, `setupControl`, `pitchTest`, `freePitchChirp`, `freePitchSine`, `freePitchStep`, `freePitchCosine`, plus `testPxi` (checks the PXI card, the trigger loopback and that the PXI's edge starts the board; run it before any `USE_PXI`). The free-pitch ones also estimate the response (chirp: FFT ratio; sine: least-squares gain and phase; step: time to 63%, overshoot, 5% settling; cosine: peak excursion and when). Motion examples start with a `CONFIRMED_AREA_CLEAR = false` flag that stops the script until you set it true. `controlStepResponseTest.m` (in this folder) steps the pitch target during a capture to help tune Kp/Ki/Kd.

**Run numbers.** Every script that records data (`ZeroRun`, `AoASweep`, `AoA_V_Sweep`, `FreePitchSine`, `FreePitchChirp`, `FreePitchCosine`, `FreePitchStep`) calls `wt.runNum.increment()` when it starts, so each run of a script gets its own run number and there is normally no need to increment by hand. A consequence: a sweep never shares a run number with the `ZeroRun` before it, so the "last zero run is from a different run number" warning the sweeps print is expected with this convention.

## Writing a new test script

Follow the skeleton the existing tunnel scripts use. This is the shape, not boilerplate to copy blindly:

```matlab
% MyTest: what it does, in a few lines. What must be done first (ZeroEncoderRun, ZeroRun).
% THIS MOVES THE SURFACES. <the one thing most likely to go wrong, and what to do>

HastaIP = "192.168.1.107";  % <-- set to your board's actual IP
OHBIP = "192.168.1.61";

%% setup ohb / Hasta DAQ objects (reuse live ones: the board takes one client at a time)
if ~exist("ohb","var"),  ohb = wt.OHBControl(); end
if ~ohb.connected
    if ~ohb.connect(OHBIP), error('Not Connected to OHB server'); end
    ohb.openLogFile();
end
if ~exist("hd","var") || ~isvalid(hd)
    hd = wt.hasta.DaqClient(HastaIP);
end

%% send the saved encoder zero
hd.disableControl();
hd.setEncoderZeroOffset(wt.hasta.encoderZero.get());

%% plan: parameters, then work out totals for the progress output
...
filename = string(fullfile("data", sprintf("Run%02d_MyTest_%s.mat", RunNumber, char(datetime("now", Format="yyyyMMdd_HHmmss")))));
zeroRun = wt.hasta.getLastZeroRun("data");     % warn if empty / from another run

%% run: parallel arrays, one element per test point
hdData = wt.hasta.DaqData.empty;  ohbData = wt.OHBData.empty;  meta = wt.hasta.MetaData.empty;
k = 0;  runTimer = tic;
try
    for ...
        % command the rig, sample ohb and hd together, then ONLY NOW count the point
        k = k + 1;  hdData(k) = ...;  ohbData(k) = ...;  meta(k) = wt.hasta.MetaData(...);
        fprintf("    [%d/%d] ... | elapsed %s, ETA %s\n", ...);   % progress a person can follow
    end
catch ME
    save(replace(filename, ".mat", "_partial.mat"), "hdData", "ohbData", "meta");
    fprintf("\n!!! Stopped after %d/%d points: %s\n", k, totalPoints, ME.message);
    rethrow(ME);
end

%% save BEFORE any wind-down step, so a failure there can't lose the data
save(filename, "hdData", "ohbData", "meta");

%% local functions go at the END of a script file
```

Checklist: a safety flag or clear warning if it moves things; state left in a **stated** condition at the end; progress output with ETA; partial save on error; arrays stay the same length (add the point to all three together); no new toolbox dependency; run `checkcode` and exercise it against a fake board before it goes near the rig.

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
3. **Keep tests away from the real preferences:** put a folder containing stand-in `+wt/+hasta/+encoderZero/get.m` (and similar) **first** on the path for the test.
4. Report what you ran (`checkcode`, fake board) and what you did not (the real rig).

## Troubleshooting

| You see | Cause / fix |
|---|---|
| `Unrecognized method, property, or field 'X' for class 'wt.hasta.DaqClient'` | an `hd` made before the class changed keeps the old definition: `clear hd` (then `clear classes` if needed) |
| `No reply from the board to <cmd> after N attempt(s) ...` (`DaqClient:noReply`) | WiFi dropped, the board reset, or a stale connection. Check `hd.getHealth()` (uptime, reset reason, RSSI) and the board's Serial Monitor; `hd.ReconnectCount` shows how often it recovered |
| `actively refused` / can't connect | the board serves one client; `clear hd` the other session, or reset the board |
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
