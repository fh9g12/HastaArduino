% FreePitchChirp: CHIRP with the model free to pitch. For each target pitch
% angle, one chirp (a linear sweep F0Hz -> F1Hz over PeriodS) per amplitude.
% The controller holds the model at the target, a Datum (steady OHB sample
% there) records the equilibrium, the controller is switched off without a
% jolt and the chirp is added on top. A chirp covers a band in one go; several
% amplitudes show how the response changes with size (non-linearity).
% The OHB is not sampled during the time series: each chirp's meta.DatumTest
% says which Datum it belongs to.
%
% Run scripts.ZeroEncoderRun once first (the pitch target is an encoder angle)
% and scripts.ZeroRun for the force-sensor zero, with the wind OFF.
% To mix different test types in one run, see scripts.FreePitchMixed.
%
% THIS MOVES THE ELEVATORS AND THE MODEL, WHICH IS FREE TO PITCH. If the
% model runs away from a target instead of settling, the controller's sign
% is wrong: ControlSettings(CtrlGain=1).

TargetPitches = [5];        % pitch angles (encoder, deg) to hold
F0Hz = 0.2;                 % <-- sweep start
F1Hz = 1;                   % <-- sweep end
PeriodS = 30;               % <-- time the sweep takes
AmplitudesDeg = [3];        % <-- one chirp per amplitude (elevator excitation, deg)
DelayS = 1;                 % quiet recording before it starts
TailS = 2;                  % recording after it ends
HomePitchDeg = 0;           % where the controller leaves the model at the end

UsePxi = true;              % true: also record the 6-axis force sensor (PXI)
UseCamera = true;           % true: pulse the tracking camera around each dynamic record (needs UsePxi)
control = wt.hasta.ControlSettings();   % Kp 0.1, Ki 0.2, Kd 0.05, limit 20, CtrlGain -1, tolerance 0.2
% <-- fill in the model setup for this run
modelConfig = wt.hasta.ModelConfig(TankType="Liquid", TankDiameter_mm=50, FuelMass_g=165);

points = wt.hasta.testtype.BaseTestType.empty;
for pitch = TargetPitches
    for a = AmplitudesDeg
        points(end+1) = wt.hasta.testtype.Chirp(PitchDeg=pitch, F0Hz=F0Hz, F1Hz=F1Hz, PeriodS=PeriodS, ...
            AmplitudeDeg=a, DelayS=DelayS, TailS=TailS); %#ok<SAGROW>
    end
end

[hd, ohb, pxi] = wt.hasta.setupTestEnvironment(UsePxi=UsePxi, UseCamera=UseCamera);
results = wt.hasta.runTests(points, Hd=hd, Ohb=ohb, Pxi=pxi, Name="FreePitchChirp", ...
    ModelConfig=modelConfig, Control=control, HomePitchDeg=HomePitchDeg, ConfirmedAreaClear=true);
[hdData, ohbData, meta, pxiData] = deal(results.hdData, results.ohbData, results.meta, results.pxiData);
