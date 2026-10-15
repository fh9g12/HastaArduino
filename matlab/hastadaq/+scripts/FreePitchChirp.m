% FreePitchChirp: CHIRP (frequency sweep) with the model free to pitch. For
% each target pitch angle:
%   1. the controller holds the model at the target and we wait for it to
%      settle
%   2. a steady sample gives the EQUILIBRIUM values (OHB + Hasta DAQ),
%      averaged
%   3. a chirp - one for each amplitude in ChirpAmplitudesDeg - is applied to
%      the elevators while the response is recorded in full. Each starts from
%      the equilibrium: the controller is switched off without a jolt (the
%      elevators keep their equilibrium angles as fixed trim) - or left
%      running - and between chirps it is switched back on to bring the
%      model back to the target
%   4. on to the next target (the controller's settings are kept)
% Each target gives 1 + N test points in the same arrays as the sweeps: the
% averaged steady one (meta.TestType "Steady") and the full record of each
% chirp (meta.TestType "Chirp", with its settings in
% meta.Parameters.Excitation). The model is left held at HomePitchDeg by the
% controller.
%
% FORCE SENSOR (optional, UsePxi): the 6-axis force sensor on the PXI is
% recorded alongside, started by the SAME hardware edge as the Arduino's
% capture, and saved as a fourth array, pxiData, parallel to the others
% (placeholders when UsePxi is false).
%
% A chirp covers a band in one go; several amplitudes show how the response
% changes with size (non-linearity). The other free-pitch tests:
% FreePitchSine (stepped sine), FreePitchCosine and FreePitchStep. Run
% scripts.ZeroEncoderRun once first (the pitch target is an encoder angle)
% and scripts.ZeroRun for the force-sensor zero, with the wind OFF. For the
% same sequence on the Hasta DAQ alone, see wt.hasta.examples.freePitchChirp.
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
TargetPitches = [5];   % pitch angles (encoder, deg) to hold
IncidenceDeg = NaN;        % tunnel incidence for the whole test; NaN = leave it where it is

% the controller (kept across disable/enable)
KP = 0.1; KI = 0.2; KD = 0.05;      % <-- controller gains
OutLimitDeg = 15;          % most the controller can move the elevators
CtrlGain = -1;              % -1 if the controller pushes the wrong way
ToleranceDeg = 0.25;       % "settled" = within this of the target for 1 s

SteadyN = 4;               % equilibrium sample time, s
SampleHz = 100;
UsePxi = true;            % true: also record the 6-axis force sensor (PXI), started by the same trigger edge
PxiCard = "PXI1Slot4_2";          % the NI device
PxiRateHz = 200;           % force-sensor sample rate
UseCamera = true;         % true: pulse the tracking camera at the start and end of each dynamic record (needs UsePxi)
ControllerDuringExcitation = false;   % true: leave the controller running during the excitation
ExciteSurfaces = [wt.hasta.HDCh.ElevR wt.hasta.HDCh.ElevL];   % flip a servo's sign by hand if mounted mirrored
TailS = 2;                 % extra recording after the excitation ends
HomePitchDeg = 0;          % where the controller leaves the model at the end

% The excitations to run at EACH target, in order. Each one is a cell: its
% type first, then name/value pairs for wt.hasta.DaqClient.setExcitation:
%   {"chirp", "f0", 0.2, "f1", 1.2, "periodS", 30, "amplitudeDeg", 1, "cycles", 1, "delayS", 1}
% The chirp sweeps f0 -> f1 once over periodS (cycles = 1). One chirp per
% amplitude:
ChirpF0Hz = 0.2;                % <-- sweep start
ChirpF1Hz = 1;                % <-- sweep end
ChirpPeriodS = 30;              % <-- time the sweep takes
ChirpAmplitudesDeg = [3];       % <-- one chirp per amplitude (elevator excitation, deg)
ChirpDelayS = 1;                % quiet recording before it starts
excitations = arrayfun(@(a) {"chirp", "f0", ChirpF0Hz, "f1", ChirpF1Hz, "periodS", ChirpPeriodS, ...
    "amplitudeDeg", a, "cycles", 1, "delayS", ChirpDelayS}, ChirpAmplitudesDeg, UniformOutput=false);

% RunNumber = wt.runNum.get();   % the same run as the ZeroRun before it; wt.runNum.increment() starts a new one
RunNumber = wt.runNum.increment();
% <-- fill in the model setup for this run
modelConfig = wt.hasta.ModelConfig(TankType="Liquid", TankDiameter_mm=50, FuelMass_g=165);

% work out each excitation's type, parameters and how long to record it
nExc = numel(excitations);
exc = repmat(struct("type", "", "args", {{}}, "params", struct(), "metaType", "", "durationS", 0), 1, nExc);
for ei = 1:nExc
    e = excitations{ei};
    exc(ei).type = string(e{1});
    exc(ei).args = e(2:end);
    exc(ei).params = struct(e{2:end});
    exc(ei).metaType = upper(extractBefore(exc(ei).type, 2)) + extractAfter(exc(ei).type, 1);   % "chirp" -> "Chirp"
    exc(ei).durationS = excitationDuration(exc(ei).type, exc(ei).params) + TailS;
end

dataDir = "data";
if ~isfolder(dataDir)
    mkdir(dataDir);
end
filename = string(fullfile(dataDir, sprintf("Run%02d_FreePitchChirp_%s.mat", RunNumber, ...
    char(datetime("now", Format="yyyyMMdd_HHmmss")))));

zeroRun = wt.hasta.getLastZeroRun(dataDir);
if zeroRun == ""
    warning("FreePitchChirp:noZeroRun", "No zero run found in %s - run scripts.ZeroRun first.", dataDir);
elseif ~contains(zeroRun, sprintf("Run%02d_", RunNumber))
    warning("FreePitchChirp:oldZeroRun", "The last zero run is from a different run number: %s", zeroRun);
end

totalPoints = numel(TargetPitches) * (1 + nExc);
controllerText = "OFF";
if ControllerDuringExcitation
    controllerText = "ON";
end
fprintf("\n=== Free-to-pitch test, run %d ===\n", RunNumber);
fprintf("Targets: %s deg;  controller Kp=%g Ki=%g Kd=%g, limit %g deg\n", ...
    mat2str(TargetPitches), KP, KI, KD, OutLimitDeg);
fprintf("Per target: %g s steady, then %d excitation(s), controller %s during them:\n", SteadyN, nExc, controllerText);
for ei = 1:nExc
    fprintf("    %d. %s, %s, %.0f s\n", ei, exc(ei).type, excitationSummary(exc(ei).params), exc(ei).durationS);
end
fprintf("%d test points in all; saving to %s\n\n", totalPoints, filename);

%% run: one hdData / ohbData / meta per test point, kept in parallel arrays
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

        % 1. hold the target
        r = hd.holdPitch(target, ctrlGain=CtrlGain, toleranceDeg=ToleranceDeg);
        fprintf("  controller holding: pitch %.2f deg, error %+.2f, %s after %.1f s\n", ...
            r.pitchDeg, r.errorDeg, settledText(r.settled), r.timeS);

        % 2. equilibrium sample
        startTime = datetime("now");
        ohb.sample(SteadyN);
        [equilibrium, pxiPoint] = recordPoint(hd, forceDaq, SteadyN, SampleHz, false);
        pause(0.25)
        ohbPoint = wt.OHBData.FromString(ohb.readLastSample);
        k = k + 1;
        hdData(k) = equilibrium.mean();
        ohbData(k) = ohbPoint;
        pxiData(k) = pxiPoint.mean();
        meta(k) = wt.hasta.MetaData(Datetime=startTime, RunNumber=RunNumber, TestNumber=k-1, ...
            TestType="Steady", Filename=filename, ZeroRun=zeroRun, ModelConfig=modelConfig, ...
            Parameters=struct(TargetPitch_deg=target, ControllerOn=true, Settled=r.settled, ...
                Kp=KP, Ki=KI, Kd=KD, OutLimitDeg=OutLimitDeg, WindSpeed_ms=windSpeed, PxiUsed=UsePxi));
        fprintf("    [%d/%d] steady: pitch %.2f deg, elevators %.2f / %.2f deg | elapsed %s\n", k, totalPoints, ...
            hdData(k).EncoderDeg, hdData(k).ELEV_R_Angle, hdData(k).ELEV_L_Angle, formatDuration(toc(runTimer)));

        % 3. each excitation in turn, from this target's equilibrium
        for ei = 1:nExc
            if ei > 1
                % the previous excitation moved the model: back to the target first
                % (this also switches the controller back on and clears the mix)
                r = hd.holdPitch(target, ctrlGain=CtrlGain, toleranceDeg=ToleranceDeg);
                fprintf("  back on target for excitation %d/%d: %s after %.1f s\n", ...
                    ei, nExc, settledText(r.settled), r.timeS);
            end

            % controller off at the equilibrium angles - or left on
            if ControllerDuringExcitation
                hd.setMix(ExciteSurfaces, excGain=1);
                trims = [];
            else
                trims = hd.openLoopAtEquilibrium(equilibrium, surfaces=ExciteSurfaces, excGain=1);
            end
            hd.setExcitation(exc(ei).type, exc(ei).args{:}, "armed", true);
            startTime = datetime("now");
            ohb.sample(exc(ei).durationS);
            [response, pxiPoint] = recordPoint(hd, forceDaq, exc(ei).durationS, SampleHz, UseCamera);
            hd.disarmExcitation();
            pause(0.25)
            ohbPoint = wt.OHBData.FromString(ohb.readLastSample);
            k = k + 1;
            hdData(k) = response;    % the whole time series: this is a dynamic test
            ohbData(k) = ohbPoint;
            pxiData(k) = pxiPoint;   % the whole record (a placeholder if UsePxi is false)
            meta(k) = wt.hasta.MetaData(Datetime=startTime, RunNumber=RunNumber, TestNumber=k-1, ...
                TestType=exc(ei).metaType, Filename=filename, ZeroRun=zeroRun, ModelConfig=modelConfig, ...
                Parameters=struct(TargetPitch_deg=target, ControllerOn=ControllerDuringExcitation, ...
                    Excitation=exc(ei).params, ExcitationIndex=ei, EquilibriumTrimDeg=trims, ...
                    Kp=KP, Ki=KI, Kd=KD, OutLimitDeg=OutLimitDeg, WindSpeed_ms=windSpeed, PxiUsed=UsePxi));
            fprintf("    [%d/%d] %s (%s): %d samples | elapsed %s, ETA %s\n", k, totalPoints, ...
                lower(exc(ei).metaType), excitationSummary(exc(ei).params), response.NumSamples, ...
                formatDuration(toc(runTimer)), formatDuration(toc(runTimer) / k * (totalPoints - k)));
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

function seconds = excitationDuration(type, p)
% How long the excitation takes: its start delay plus its cycles.
    if ~isfield(p, "cycles") || p.cycles <= 0
        error("FreePitchChirp:cycles", "The excitation needs cycles > 0 (it has to stop by itself).");
    end
    delay = 0;
    if isfield(p, "delayS")
        delay = p.delayS;
    end
    switch type
        case "sine"
            seconds = delay + p.cycles / p.freqHz;
        case {"chirp", "cosine"}
            seconds = delay + p.cycles * p.periodS;
        otherwise
            error("FreePitchChirp:type", "Unknown excitation type %s.", type);
    end
end

function str = excitationSummary(p)
% A short description of an excitation's parameters, for the progress output.
    parts = strings(1, 0);
    if isfield(p, "freqHz"), parts(end+1) = sprintf("%g Hz", p.freqHz); end
    if isfield(p, "f0") && isfield(p, "f1"), parts(end+1) = sprintf("%g->%g Hz", p.f0, p.f1); end
    if isfield(p, "periodS") && ~isfield(p, "f0"), parts(end+1) = sprintf("period %g s", p.periodS); end
    if isfield(p, "amplitudeDeg"), parts(end+1) = sprintf("%g deg", p.amplitudeDeg); end
    if isfield(p, "cycles"), parts(end+1) = sprintf("%g cycle(s)", p.cycles); end
    str = strjoin(parts, ", ");
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
