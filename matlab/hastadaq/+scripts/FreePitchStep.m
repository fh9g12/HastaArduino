% FreePitchStep: STEP RESPONSE with the model free to pitch. For each target
% pitch angle ("AoA") and each delta in DeltaPitchDeg:
%   1. the controller holds the model at the target and we wait for it to
%      settle; a steady sample gives the EQUILIBRIUM values there (OHB +
%      Hasta DAQ) and the elevator angles that hold the target
%   2. the controller moves the model delta degrees away and holds it there
%      (a short sample gives the elevator angles that hold THAT pitch)
%   3. the controller is switched off without a jolt - the elevators stay at
%      the angles that held the displaced pitch - and a "step" excitation is
%      ARMED on the board: the elevators will step to the angles that held
%      the target PreStepS after the trigger. The record is then triggered, so
%      the step happens on the board at a known time after the start, with no
%      command from MATLAB; the model's response is recorded for PostStepS
%      after it
%   4. the controller is switched back on and brings the model back to the
%      target, ready for the next delta
% Each target gives a steady point (meta.TestType "Steady") and one "Step"
% point per delta, in the same arrays as the sweeps. A Step point is the full
% time series: the baseline before the step, the step, and the response. Its
% meta.Parameters hold the target, the delta, the elevator angles stepped
% from and to, the step delay, the detected step time, and whether it was
% aborted. The model is left held at HomePitchDeg by the controller.
%
% FORCE SENSOR (optional, UsePxi): the 6-axis force sensor on the PXI is
% recorded alongside, started by the SAME hardware edge as the Arduino's
% capture (the PXI raises the trigger line; the Arduino has been armed to wait
% for it). Saved as a fourth array, pxiData, parallel to the others
% (placeholders when UsePxi is false). Because the step is timed on the
% board, the blocking PXI record doesn't disturb it.
%
% SAFETY: without the PXI, MATLAB polls the encoder while recording and, if
% the model strays more than |delta| + OvershootAllowanceDeg from the target
% (a statically unstable or lightly damped model), switches the controller
% straight back on and marks the point Aborted. WITH the PXI the record
% blocks MATLAB, so there is NO such monitoring: keep PostStepS short and the
% deltas small until you know how the model behaves.
%
% The other free-pitch tests: FreePitchSine, FreePitchChirp and
% FreePitchCosine. Run scripts.ZeroEncoderRun once first (the pitch target is
% an encoder angle) and scripts.ZeroRun for the force-sensor zero, with the
% wind OFF. For the same sequence on the Hasta DAQ alone, see
% wt.hasta.examples.freePitchStep.
%
% THIS MOVES THE ELEVATORS AND THE MODEL, WHICH IS FREE TO PITCH. If the
% model runs away from a target instead of settling, the controller's sign
% is wrong: set CtrlGain = -1.

HastaIP = "192.168.1.107";  % <-- set to your board's actual IP
OHBIP = "192.168.1.61";

%% setup ohb object
if ~exist("ohb","var")
    ohb = wt.OHBControl();
end
if ~ohb.connected
    if ~ohb.connect(OHBIP)
        error('Not Connected to OHB server')
    end
    ohb.openLogFile();
end

%% setup Hasta DAQ object
% the board takes one client at a time, so reuse an existing connection
if ~exist("hd","var") || ~isvalid(hd)
    hd = wt.hasta.DaqClient(HastaIP);
end

%% send the saved encoder zero
% (saved by scripts.ZeroEncoderRun; the board forgets its zero when it restarts)
hd.disableControl();   % the offset is refused while the PID is enabled
hd.setEncoderZeroOffset(wt.hasta.encoderZero.get());

%% test plan
TargetPitches = [5];       % pitch angles (encoder, deg) the step returns to
DeltaPitchDeg = [3 -3];    % <-- how far from each target to start, deg: one step test per delta
IncidenceDeg = NaN;        % tunnel incidence for the whole test; NaN = leave it where it is

% the controller (kept across disable/enable)
KP = 0.1; KI = 0.2; KD = 0.05;      % <-- controller gains
OutLimitDeg = 15;          % most the controller can move the elevators
CtrlGain = -1;             % -1 if the controller pushes the wrong way
ToleranceDeg = 0.25;       % "settled" = within this of the target for 1 s

SteadyN = 4;               % equilibrium sample at the target, s
DisplacedN = 2;            % sample at the displaced pitch (for its elevator angles), s
PreStepS = 2;              % recorded at the displaced pitch before the step, s
PostStepS = 10;            % recorded after the step, s
SampleHz = 100;
UsePxi = false;            % true: also record the 6-axis force sensor (PXI), started by the same trigger edge
PxiCard = "Dev5";          % the NI device
PxiRateHz = 200;           % force-sensor sample rate
UseCamera = false;         % true: pulse the tracking camera at the start and end of each step record (needs UsePxi)
StepSurfaces = [wt.hasta.HDCh.ElevR wt.hasta.HDCh.ElevL];   % flip a servo's sign by hand if mounted mirrored
OvershootAllowanceDeg = 3; % abort if pitch strays more than |delta| + this from the target (not with UsePxi)
HomePitchDeg = 0;          % where the controller leaves the model at the end

RunNumber = wt.runNum.increment();
% <-- fill in the model setup for this run
modelConfig = wt.hasta.ModelConfig(TankType="Liquid", TankDiameter_mm=50, FuelMass_g=165);

nDelta = numel(DeltaPitchDeg);
stepColumns = arrayfun(@(s) s.column(), StepSurfaces);   % where the step surfaces sit in ServoAngles
stepSurfaceNames = [StepSurfaces.WireName];

dataDir = "data";
if ~isfolder(dataDir)
    mkdir(dataDir);
end
filename = string(fullfile(dataDir, sprintf("Run%02d_FreePitchStep_%s.mat", RunNumber, ...
    char(datetime("now", Format="yyyyMMdd_HHmmss")))));

zeroRun = wt.hasta.getLastZeroRun(dataDir);
if zeroRun == ""
    warning("FreePitchStep:noZeroRun", "No zero run found in %s - run scripts.ZeroRun first.", dataDir);
elseif ~contains(zeroRun, sprintf("Run%02d_", RunNumber))
    warning("FreePitchStep:oldZeroRun", "The last zero run is from a different run number: %s", zeroRun);
end

totalPoints = numel(TargetPitches) * (1 + nDelta);
fprintf("\n=== Free-to-pitch STEP test, run %d ===\n", RunNumber);
fprintf("Targets: %s deg, deltas: %s deg;  controller Kp=%g Ki=%g Kd=%g, limit %g deg\n", ...
    mat2str(TargetPitches), mat2str(DeltaPitchDeg), KP, KI, KD, OutLimitDeg);
fprintf("Per delta: %g s before the step + %g s after (%d surface(s) step back to the target's elevator angles)\n", ...
    PreStepS, PostStepS, numel(StepSurfaces));
if UsePxi
    fprintf("Force sensor (PXI) ON: records are triggered by the PXI; NO abort monitoring during them.\n");
end
fprintf("%d test points in all; saving to %s\n\n", totalPoints, filename);

%% run: one hdData / ohbData / meta (/ pxiData) per test point, kept in parallel arrays
hdData = wt.hasta.DaqData.empty;
ohbData = wt.OHBData.empty;
meta = wt.hasta.MetaData.empty;
pxiData = wt.pxi.ForceData.empty;

% the force sensor, if used: reuse a live one (the card is opened once per session)
forceDaq = [];
if UsePxi
    if ~exist("pxi","var") || ~isa(pxi,"wt.pxi.ForceDaq") || ~isvalid(pxi)
        pxi = wt.pxi.ForceDaq(PxiCard, rate=PxiRateHz);
    end
    pxi.lowOutput();                       % the trigger line must be LOW before the Arduino is armed
    hd.setTrigger(inEdge="rising");
    forceDaq = pxi;
end

if ~isnan(IncidenceDeg)
    ohb.moveIncidence(IncidenceDeg,2,2,2,blocking=true);
end
hd.setControl(Kp=KP, Ki=KI, Kd=KD, outLimitDeg=OutLimitDeg);
windSpeed = ohb.readWindSpeed();

k = 0;   % test points completed so far (TestNumber = k-1, starting at 0)
runTimer = tic;
try
    for ti = 1:numel(TargetPitches)
        target = TargetPitches(ti);
        fprintf("=== Target %d/%d: %g deg ===\n", ti, numel(TargetPitches), target);

        % 1. hold the target; equilibrium sample and the elevator angles that hold it
        r = hd.holdPitch(target, ctrlGain=CtrlGain, toleranceDeg=ToleranceDeg);
        fprintf("  controller holding: pitch %.2f deg, error %+.2f, %s after %.1f s\n", ...
            r.pitchDeg, r.errorDeg, settledText(r.settled), r.timeS);
        startTime = datetime("now");
        ohb.sample(SteadyN);
        [equilibrium, pxiPoint] = recordPoint(hd, forceDaq, SteadyN, SampleHz, false);
        pause(0.25)
        ohbPoint = wt.OHBData.FromString(ohb.readLastSample);
        trimsTarget = meanAngles(equilibrium, StepSurfaces);   % the elevator angles that hold the target
        k = k + 1;
        hdData(k) = equilibrium.mean();
        ohbData(k) = ohbPoint;
        pxiData(k) = pxiPoint.mean();
        meta(k) = wt.hasta.MetaData(Datetime=startTime, RunNumber=RunNumber, TestNumber=k-1, ...
            TestType="Steady", Filename=filename, ZeroRun=zeroRun, ModelConfig=modelConfig, ...
            Parameters=struct(TargetPitch_deg=target, ControllerOn=true, Settled=r.settled, ...
                Kp=KP, Ki=KI, Kd=KD, OutLimitDeg=OutLimitDeg, WindSpeed_ms=windSpeed, PxiUsed=UsePxi));
        fprintf("    [%d/%d] steady: pitch %.2f deg, elevators %s deg | elapsed %s\n", k, totalPoints, ...
            hdData(k).EncoderDeg, mat2str(round(trimsTarget, 2)), formatDuration(toc(runTimer)));

        for di = 1:nDelta
            delta = DeltaPitchDeg(di);
            displaced = target + delta;
            fprintf("  step %d/%d: from %+g deg away (%g deg) back to %g deg\n", di, nDelta, delta, displaced, target);

            % 2. move delta away, hold it, and get the elevator angles that hold it
            r = hd.holdPitch(displaced, ctrlGain=CtrlGain, toleranceDeg=ToleranceDeg);
            fprintf("    holding the displaced pitch: pitch %.2f deg, %s after %.1f s\n", r.pitchDeg, settledText(r.settled), r.timeS);
            displacedEq = hd.capture(DisplacedN, SampleHz);
            trimsDisplaced = meanAngles(displacedEq, StepSurfaces);

            % 3. controller off at the displaced angles (no jolt); arm a STEP on the board that
            %    takes each surface to the target's angle. Each surface gets its share of one
            %    common step: excGain = (its step) / (the largest step), the amplitude the largest.
            hd.openLoopAtEquilibrium(displacedEq, surfaces=StepSurfaces, excGain=0);
            stepDeg = trimsTarget - trimsDisplaced;
            stepAmplitude = max(abs(stepDeg));
            if stepAmplitude < 0.05
                warning("FreePitchStep:noStep", "The elevator angles at the two pitches differ by less than 0.05 deg: there will be no step to record.");
                stepAmplitude = 0;
                stepGains = zeros(size(stepDeg));
            else
                stepGains = stepDeg / stepAmplitude;
            end
            hd.setMix(StepSurfaces, excGain=stepGains);
            hd.setExcitation("step", amplitudeDeg=stepAmplitude, delayS=PreStepS, armed=true);

            totalS = PreStepS + PostStepS;
            startTime = datetime("now");
            ohb.sample(totalS);
            aborted = false;   abortS = NaN;
            if isempty(forceDaq)
                % the trigger is a software one (RUN); MATLAB stays free to watch the model
                hd.run(totalS, SampleHz);
                clk = tic;
                while toc(clk) < totalS
                    pitch = hd.getEncoderDeg();
                    if abs(pitch - target) > abs(delta) + OvershootAllowanceDeg
                        aborted = true;  abortS = toc(clk);
                        fprintf("    !!! pitch %.2f deg is %.1f deg from the target: switching the controller back on\n", ...
                            pitch, abs(pitch - target));
                        hd.holdPitch(target, ctrlGain=CtrlGain, toleranceDeg=ToleranceDeg, timeoutS=10);
                        break
                    end
                    pause(0.05);
                end
                hd.waitForDone(totalS + 30);
                response = hd.readData();
                pxiPoint = wt.pxi.ForceData();      % a placeholder keeps the arrays parallel
            else
                % the PXI raises the trigger: Arduino and force sensor start on the same edge
                [response, pxiPoint] = recordPoint(hd, forceDaq, totalS, SampleHz, UseCamera);
            end
            hd.disarmExcitation();
            pause(0.25)
            ohbPoint = wt.OHBData.FromString(ohb.readLastSample);

            % when did the elevators really step? (from the recorded angles, not the nominal delay)
            elevTrace = mean(response.ServoAngles(:, stepColumns), 2);
            before = median(elevTrace(response.Time < 0.5 * PreStepS));
            after = mean(trimsTarget);
            stepTimeS = NaN;   % stays NaN if the point was aborted before the step was due
            if ~(aborted && abortS < PreStepS) && abs(after - before) > 0.05
                idx = find(abs(elevTrace - before) > 0.5 * abs(after - before), 1);
                if ~isempty(idx)
                    stepTimeS = response.Time(idx);
                end
            end

            k = k + 1;
            hdData(k) = response;    % the whole time series: this is a dynamic test
            ohbData(k) = ohbPoint;
            pxiData(k) = pxiPoint;
            meta(k) = wt.hasta.MetaData(Datetime=startTime, RunNumber=RunNumber, TestNumber=k-1, ...
                TestType="Step", Filename=filename, ZeroRun=zeroRun, ModelConfig=modelConfig, ...
                Parameters=struct(TargetPitch_deg=target, DeltaPitch_deg=delta, DisplacedPitch_deg=displaced, ...
                    StepSurfaces=stepSurfaceNames, StepFromDeg=trimsDisplaced, StepToDeg=trimsTarget, ...
                    StepAmplitudeDeg=stepAmplitude, StepGains=stepGains, ...
                    PreStepS=PreStepS, PostStepS=PostStepS, StepDelayS=PreStepS, StepTimeS=stepTimeS, ...
                    PitchExcursionDeg=max(abs(response.EncoderDeg - target)), ...
                    Aborted=aborted, AbortS=abortS, ControllerOn=false, ...
                    Kp=KP, Ki=KI, Kd=KD, OutLimitDeg=OutLimitDeg, WindSpeed_ms=windSpeed, PxiUsed=UsePxi));
            fprintf("    [%d/%d] step %s: %d samples, step at %.2f s, pitch %.2f -> %.2f deg%s | elapsed %s, ETA %s\n", ...
                k, totalPoints, mat2str(round(trimsDisplaced, 2)) + ">" + mat2str(round(trimsTarget, 2)), response.NumSamples, ...
                stepTimeS, response.EncoderDeg(1), response.EncoderDeg(end), abortedText(aborted), ...
                formatDuration(toc(runTimer)), formatDuration(toc(runTimer) / k * (totalPoints - k)));

            % 4. controller back on: back to the target (also disarms the step and clears the mix)
            r = hd.holdPitch(target, ctrlGain=CtrlGain, toleranceDeg=ToleranceDeg);
            fprintf("    back on target: %s after %.1f s\n", settledText(r.settled), r.timeS);
        end
    end
catch ME
    % don't lose tunnel time: keep what we have, then re-throw
    partialFile = replace(filename, ".mat", "_partial.mat");
    save(partialFile, "hdData", "ohbData", "meta", "pxiData");
    fprintf("\n!!! Stopped after %d/%d test points: %s\n", k, totalPoints, ME.message);
    fprintf("!!! Partial data saved to %s\n", partialFile);
    fprintf("!!! The controller and surfaces have been left exactly as they were.\n");
    rethrow(ME);
end

%% save
save(filename, "hdData", "ohbData", "meta", "pxiData");
fprintf("\nSaved %d test points to %s (took %s)\n", k, filename, formatDuration(toc(runTimer)));

%% leave the model held
hd.holdPitch(HomePitchDeg, ctrlGain=CtrlGain, toleranceDeg=ToleranceDeg);
fprintf("Controller holding the model at %g deg (it is left running).\n", HomePitchDeg);


%% local functions (must be at the end of a script)
function [hdPoint, pxiPoint] = recordPoint(hd, forceDaq, durationS, sampleHz, useCamera)
% Record durationS seconds from the Hasta DAQ and, if a force sensor is given,
% from the PXI too. With the PXI both start on the SAME hardware edge: the
% Arduino is armed to wait for it, then the PXI raises it and records (this
% blocks MATLAB for the whole record). Without it the Arduino is simply run.
    if isempty(forceDaq)
        hdPoint = hd.capture(durationS, sampleHz);
        pxiPoint = wt.pxi.ForceData();      % a placeholder keeps the arrays parallel
    else
        hd.arm(durationS, sampleHz);
        pxiPoint = forceDaq.acquire(durationS, camera=useCamera);
        hd.waitForDone(durationS + 30);
        hdPoint = hd.readData();
    end
end

function trims = meanAngles(data, surfaces)
% The average commanded angle of each surface over a capture, as a row.
    trims = zeros(1, numel(surfaces));
    for i = 1:numel(surfaces)
        trims(i) = mean(data.Angle(surfaces(i)), "omitnan");
    end
end

function str = abortedText(aborted)
    str = "";
    if aborted
        str = "  ABORTED";
    end
end

function str = settledText(settled)
    str = "NOT settled";
    if settled
        str = "settled";
    end
end

function str = formatDuration(seconds)
% h:mm:ss
    seconds = round(seconds);
    str = sprintf("%d:%02d:%02d", floor(seconds / 3600), floor(mod(seconds, 3600) / 60), mod(seconds, 60));
end
