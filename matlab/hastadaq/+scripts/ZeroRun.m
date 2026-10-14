% ZeroRun: wind-off zeroing run. Moves the model to zero incidence, sends
% the saved pitch-encoder zero (scripts.ZeroEncoderRun), takes one sample
% from the OHB and the Hasta DAQ, and saves it as a run. AoASweep records the latest of these in each test
% point's meta.ZeroRun so the force sensors can be zeroed in post-processing
% (nothing is subtracted here).
%
% Run with the wind OFF. This script checks that, and stops if it isn't.

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

%% check the wind is off
windSpeed = ohb.readWindSpeed();
assert(~isnan(windSpeed), "Could not read the wind speed from the OHB server.");
assert(abs(windSpeed) <= 0.25, ...
    "Wind speed is %.2f m/s - turn the wind off before a zero run.", windSpeed);

%% setup script
RunNumber = wt.runNum.increment();   % saved in a MATLAB preference; wt.runNum.get() reads it without changing it, wt.runNum.set(n) sets it
testType = "Zero";
N = 5;                        % sample time, s

% <-- keep in step with the model setup in AoASweep
modelConfig = wt.hasta.ModelConfig(TankType="Liquid", TankDiameter_mm=50, FuelMass_g=165);

dataDir = "data";
if ~isfolder(dataDir)
    mkdir(dataDir);
end
filename = string(fullfile(dataDir, sprintf("Run%02d_ZeroRun_%s.mat", RunNumber, ...
    char(datetime("now", Format="yyyyMMdd_HHmmss")))));

%% zero run
ohb.moveIncidence(0,2,2,2,blocking=true);

% elevators to zero for the reference sample; ZERO is refused while the
% PID is enabled, so make sure it is off
hd.disableControl();
hd.setSteady(["ElevR","ElevL"],0,settleS=0.5);

% a) send the saved encoder zero (scripts.ZeroEncoderRun) instead of zeroing
%    again, then check it: at zero incidence the encoder should read ~0
hd.setEncoderZeroOffset(wt.hasta.encoderZero.get());
zeroInfo = wt.hasta.encoderZero.info();
encoderDeg = hd.getEncoderDeg();
fprintf("Saved encoder zero sent (saved %s); the encoder reads %.3f deg at zero incidence.\n", ...
    zeroInfo.SavedAt, encoderDeg);
if abs(encoderDeg) > 0.5
    warning("ZeroRun:encoderOff", ...
        "The encoder reads %.2f deg at zero incidence - has it moved? Re-run scripts.ZeroEncoderRun if so.", encoderDeg);
end

% b) take a sample
startTime = datetime("now");
ohb.sample(N);
hd.run(N,100);
hd.waitForDone();
hdData = hd.readData().mean();   % steady: keep just the average
pause(0.25)
ohbData = wt.OHBData.FromString(ohb.readLastSample);

% same layout as AoASweep, just with one test point
meta = wt.hasta.MetaData(Datetime=startTime, RunNumber=RunNumber, TestNumber=0, ...
    TestType=testType, Filename=filename, ModelConfig=modelConfig, ...
    Parameters=struct(AoA_deg=0, ElevatorDeg=0, WindSpeed_ms=windSpeed));

%% save
save(filename, "hdData", "ohbData", "meta");
fprintf("Zero run saved to %s\n", filename);
