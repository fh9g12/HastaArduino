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

%% setup script

% AoAs = -5:1.25:22.5;
AoAs = -5:1.25:6.25;
Betas = unique([-40,-30:5:30,40]);
Vs = 40;
BetaAoAs = -5:5:20;   % only at these AoAs is the full Betas sweep done (others: Beta = 0)

RunNumber = wt.runNum.increment();   % saved in a MATLAB preference; wt.runNum.get() reads it without changing it, wt.runNum.set(n) sets it
testType = "Steady";   % Steady | Sine | Cosine | Chirp

% <-- fill in the model setup for this run
modelConfig = wt.hasta.ModelConfig(TankType="Solid", TankDiameter_mm=NaN, FuelMass_g=0);
% assert(~isnan(modelConfig.TankDiameter_mm) && ~isnan(modelConfig.FuelMass_g), ...
%     "Set the tank diameter and fuel mass in modelConfig before running.");

dataDir = "data";
if ~isfolder(dataDir)
    mkdir(dataDir);
end
filename = string(fullfile(dataDir, sprintf("Run%02d_AoAVSweep_%s.mat", RunNumber, ...
    char(datetime("now", Format="yyyyMMdd_HHmmss")))));

% the most recent zero run (scripts.ZeroRun), recorded in every test point's
% meta so the force sensors can be zeroed in post-processing
zeroRun = wt.hasta.getLastZeroRun(dataDir);
if zeroRun == ""
    warning("AoAVSweep:noZeroRun", "No zero run found in %s - run scripts.ZeroRun first.", dataDir);
elseif ~contains(zeroRun, sprintf("Run%02d_", RunNumber))
    warning("AoAVSweep:oldZeroRun", "The last zero run is from a different run number: %s", zeroRun);
end

% how many test points there will be, for the progress output
isBetaAoA = ismember(AoAs, BetaAoAs);
pointsPerSpeed = sum(isBetaAoA) * numel(Betas) + sum(~isBetaAoA);
totalPoints = numel(Vs) * pointsPerSpeed;
fprintf("\n=== AoA / V sweep, run %d ===\n", RunNumber);
fprintf("Speeds:  %s m/s  (%d)\n", mat2str(Vs), numel(Vs));
fprintf("AoAs:    %d from %g to %g deg; beta sweep (%d betas) at %s\n", ...
    numel(AoAs), AoAs(1), AoAs(end), numel(Betas), mat2str(AoAs(isBetaAoA)));
fprintf("Points:  %d per speed, %d in total\n", pointsPerSpeed, totalPoints);
fprintf("Saving to %s\n\n", filename);

%% run: one hdData / ohbData / meta per test point, kept in parallel arrays
hdData = wt.hasta.DaqData.empty;
ohbData = wt.OHBData.empty;
meta = wt.hasta.MetaData.empty;

ohb.moveIncidence(0,2,2,2,blocking=true);
hd.setSteady(["ElevR","ElevL"],0);

% board link health (needs firmware with SYS?). Tried once up front, so an
% older board costs one wait here rather than one per speed.
healthOK = printHealth(hd, "board at start");

k = 0;   % test points completed so far (TestNumber = k-1, starting at 0)
runTimer = tic;
try
    for vi = 1:length(Vs)
        % set tunnel speed
        fprintf("=== Speed %d/%d: %g m/s ===\n", vi, length(Vs), Vs(vi));
        SetSpeed(ohb, Vs(vi));
        if healthOK
            printHealth(hd, "board");
        end
        for i = 1:length(AoAs)
            % set AoA
            if isBetaAoA(i)
                xBetas = Betas;
            else
                xBetas = 0;
            end
            fprintf("  AoA %d/%d: %g deg (%d beta point(s))\n", i, length(AoAs), AoAs(i), numel(xBetas));
            ohb.moveIncidence(AoAs(i),2,2,2,blocking=true);
            for j = 1:length(xBetas)
                % set elevator angle
                hd.setSteady(["ElevR","ElevL"],xBetas(j));
                pause(0.25);
                % trigger sample
                N = 4;
                startTime = datetime("now");
                ohb.sample(N);
                hd.run(N,100);
                hd.waitForDone();
                hdPoint = hd.readData().mean();   % steady: keep just the average
                pause(0.25)
                ohbPoint = wt.OHBData.FromString(ohb.readLastSample);

                % only now count the point, so the three arrays stay the same length
                k = k + 1;
                hdData(k) = hdPoint;
                ohbData(k) = ohbPoint;
                meta(k) = wt.hasta.MetaData(Datetime=startTime, RunNumber=RunNumber, TestNumber=k-1, ...
                    TestType=testType, Filename=filename, ZeroRun=zeroRun, ModelConfig=modelConfig, ...
                    Parameters=struct(AoA_deg=AoAs(i), ElevatorDeg=xBetas(j), VelocityTarget=Vs(vi)));

                elapsed = toc(runTimer);
                fprintf("    [%d/%d] V=%g AoA=%g beta=%g | elapsed %s, ETA %s\n", ...
                    k, totalPoints, Vs(vi), AoAs(i), xBetas(j), ...
                    formatDuration(elapsed), formatDuration(elapsed / k * (totalPoints - k)));
            end
            hd.setSteady(["ElevR","ElevL"],0);
        end
    end
catch ME
    % don't lose tunnel time: keep what we have, then re-throw
    partialFile = replace(filename, ".mat", "_partial.mat");
    save(partialFile, "hdData", "ohbData", "meta");
    fprintf("\n!!! Stopped after %d/%d test points: %s\n", k, totalPoints, ME.message);
    fprintf("!!! Partial data saved to %s (the tunnel has been left as it is)\n", partialFile);
    % what the link looked like, to help work out why it stopped
    fprintf("!!! MATLAB has reconnected to the board %d time(s) this session\n", hd.ReconnectCount);
    if ~isempty(hd.LastHealth)
        fprintf("!!! last good board reading: %s\n", wt.hasta.DaqClient.formatHealth(hd.LastHealth));
    end
    if healthOK
        printHealth(hd, "!!! board now");   % one quick try; says so if it can't be reached
    end
    rethrow(ME);
end

%% save (before winding the tunnel down, so a problem there can't lose the data)
save(filename, "hdData", "ohbData", "meta");
fprintf("\nSaved %d test points to %s (took %s)\n", k, filename, formatDuration(toc(runTimer)));
if healthOK
    printHealth(hd, "board at end");
end

%% wind down
fprintf("Stopping the tunnel ...\n");
ohb.moveIncidence(0,2,2,2,blocking=true);
% ohb.SetWindSpeed(0,blocking=true);
% ohb.StopAll();
fprintf("Done.\n");


%% local functions (must be at the end of a script)
function SetSpeed(ohb, target)
% Ramp the tunnel to target in steps of at most 5 m/s (ramping up or down).
    if target > 40 || target < 0
        error('Invalid speed target')
    end
    currentSpeed = ohb.readWindSpeed();
    tries = 1;
    while isnan(currentSpeed)
        if tries >= 30
            error('Could not read the tunnel wind speed from the OHB server')
        end
        pause(1);
        currentSpeed = ohb.readWindSpeed();
        tries = tries + 1;
    end
    nSteps = max(1, ceil(abs(target - currentSpeed) / 5));
    steps = linspace(currentSpeed, target, nSteps + 1);
    for s = 2:numel(steps)
        fprintf("    wind speed -> %.1f m/s\n", steps(s));
        ohb.SetWindSpeed(steps(s), blocking=true);
        pause(0.5);
    end
end

function ok = printHealth(hd, label)
% Print one line of board link health. A single attempt only (restoring the
% client's setting afterwards), so a board that isn't answering doesn't hold
% the run up; returns false if the reading couldn't be had.
    attempts = hd.MaxAttempts;
    hd.MaxAttempts = 1;
    try
        fprintf("    %s: %s | MATLAB reconnects %d\n", label, ...
            wt.hasta.DaqClient.formatHealth(hd.getHealth()), hd.ReconnectCount);
        ok = true;
    catch ME
        fprintf("    %s: health unavailable (%s)\n", label, extractBefore(string(ME.message) + " (", " ("));
        ok = false;
    end
    hd.MaxAttempts = attempts;   % always reached: the failure above is caught
end

function str = formatDuration(seconds)
% h:mm:ss
    seconds = round(seconds);
    str = sprintf("%d:%02d:%02d", floor(seconds / 3600), floor(mod(seconds, 3600) / 60), mod(seconds, 60));
end
