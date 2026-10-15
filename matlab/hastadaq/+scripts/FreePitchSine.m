% FreePitchSine: stepped-SINE sweep with the model free to pitch. For each
% target pitch angle, one sine per frequency in FreqsHz. The controller holds
% the model at the target, a Datum (steady OHB sample there) records the
% equilibrium, the controller is switched off without a jolt (the elevators
% keep the angles that held the target) and the sine is added on top.
% The OHB is not sampled during the time series (it only gives averages): each
% sine's meta.DatumTest says which Datum it belongs to, and a new Datum is
% taken when the last is older than a minute.
%
% Run scripts.ZeroEncoderRun once first (the pitch target is an encoder angle)
% and scripts.ZeroRun for the force-sensor zero, with the wind OFF.
% To mix different test types in one run, see scripts.FreePitchMixed.
%
% THIS MOVES THE ELEVATORS AND THE MODEL, WHICH IS FREE TO PITCH. If the
% model runs away from a target instead of settling, the controller's sign
% is wrong: ControlSettings(CtrlGain=1).

TargetPitches = [5];        % pitch angles (encoder, deg) to hold
FreqsHz = 0.2:0.05:1;       % <-- the N frequencies
AmplitudeDeg = 2.5;         % elevator amplitude
Cycles = 8;
DelayS = 1;                 % quiet recording before the sine starts
TailS = 2;                  % recording after it ends
HomePitchDeg = 0;           % where the controller leaves the model at the end

UsePxi = false;             % true: also record the 6-axis force sensor (PXI)
UseCamera = true;           % true: pulse the tracking camera around each dynamic record (needs UsePxi)
control = wt.hasta.ControlSettings();   % Kp 0.1, Ki 0.2, Kd 0.05, limit 20, CtrlGain -1, tolerance 0.2
% <-- fill in the model setup for this run
modelConfig = wt.hasta.ModelConfig(TankType="Liquid", TankDiameter_mm=50, FuelMass_g=165);

points = wt.hasta.testtype.BaseTestType.empty;
for pitch = TargetPitches
    for f = FreqsHz
        points(end+1) = wt.hasta.testtype.Sine(PitchDeg=pitch, FreqHz=f, AmplitudeDeg=AmplitudeDeg, ...
            Cycles=Cycles, DelayS=DelayS, TailS=TailS); %#ok<SAGROW>
    end
end

[hd, ohb, pxi] = wt.hasta.setupTestEnvironment(UsePxi=UsePxi, UseCamera=UseCamera);
results = wt.hasta.runTests(points, Hd=hd, Ohb=ohb, Pxi=pxi, Name="FreePitchSine", ...
    ModelConfig=modelConfig, Control=control, HomePitchDeg=HomePitchDeg, ConfirmedAreaClear=true);
[hdData, ohbData, meta, pxiData] = deal(results.hdData, results.ohbData, results.meta, results.pxiData);
