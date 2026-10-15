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

%%%% force sensor (optional)
UsePxi = false;            %% true: also record the 6-axis force sensor (PXI), started by the same trigger edge
PxiCard = "Dev5";          %% the NI device
PxiRateHz = 200;           %% force-sensor sample rate
forceDaq = [];
if UsePxi
    forceDaq = wt.pxi.connect(hd, PxiCard, PxiRateHz);   %% trigger line low, board set to a rising-edge start
end

%% setup script

AoAs = -5:1:15;
Betas = unique([-45:5:45,-15:1.25:15]);

AoAs = 0:3:6;
Betas = [-20,0,20];

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
filename = string(fullfile(dataDir, sprintf("Run%02d_AoASweep_%s.mat", RunNumber, ...
    char(datetime("now", Format="yyyyMMdd_HHmmss")))));

% the most recent zero run (scripts.ZeroRun), recorded in every test point's
% meta so the force sensors can be zeroed in post-processing
zeroRun = wt.hasta.getLastZeroRun(dataDir);
if zeroRun == ""
    warning("AoASweep:noZeroRun", "No zero run found in %s - run scripts.ZeroRun first.", dataDir);
elseif ~contains(zeroRun, sprintf("Run%02d_", RunNumber))
    warning("AoASweep:oldZeroRun", "The last zero run is from a different run number: %s", zeroRun);
end

%% run: one hdData / ohbData / meta per test point, kept in parallel arrays
hdData = wt.hasta.DaqData.empty;
ohbData = wt.OHBData.empty;
pxiData = wt.pxi.ForceData.empty;
meta = wt.hasta.MetaData.empty;

ohb.moveIncidence(0,2,2,2,blocking=true);
hd.setSteady(["ElevR","ElevL"],0);

k = 0;   % test points completed so far (TestNumber = k-1, starting at 0)
try
    for i = 1:length(AoAs)
        % set AoA
        ohb.moveIncidence(AoAs(i),2,2,2,blocking=true);
        for j = 1:length(Betas)
            % set elevator angle
            hd.setSteady(["ElevR","ElevL"],Betas(j));
            pause(0.5);
            % trigger sample
            N = 5;
            startTime = datetime("now");
            ohb.sample(N);
            [hdFull, pxiFull] = wt.pxi.record(hd, forceDaq, N, 100);
            hdPoint = hdFull.mean();    % steady: keep just the average
            pxiPoint = pxiFull.mean();  % ... of the force sensor too
            pause(0.25)
            ohbPoint = wt.OHBData.FromString(ohb.readLastSample);

            % only now count the point, so the three arrays stay the same length
            k = k + 1;
            hdData(k) = hdPoint;
            ohbData(k) = ohbPoint;
            pxiData(k) = pxiPoint;
            meta(k) = wt.hasta.MetaData(Datetime=startTime, RunNumber=RunNumber, TestNumber=k-1, ...
                TestType=testType, Filename=filename, ZeroRun=zeroRun, ModelConfig=modelConfig, ...
                Parameters=struct(AoA_deg=AoAs(i), ElevatorDeg=Betas(j), PxiUsed=UsePxi));
        end
        hd.setSteady(["ElevR","ElevL"],0);
    end
catch ME
    % don't lose tunnel time: keep what we have, then re-throw
    partialFile = replace(filename, ".mat", "_partial.mat");
    save(partialFile, "hdData", "ohbData", "meta", "pxiData");
    fprintf("Stopped after %d test points; partial data saved to %s\n", k, partialFile);
    rethrow(ME);
end

%% save
save(filename, "hdData", "ohbData", "meta", "pxiData");
fprintf("Saved %d test points to %s\n", k, filename);
