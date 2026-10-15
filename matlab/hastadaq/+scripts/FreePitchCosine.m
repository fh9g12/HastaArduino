% FreePitchCosine: 1-COSINE PULSE with the model free to pitch. For each
% target pitch angle, one pulse per period x amplitude: the elevators go
% 0 -> amplitude -> 0 over the period (a negative amplitude pulses the other
% way) and the model's free response is recorded for TailS afterwards.
% PeriodS is the whole pulse (it peaks at PeriodS/2), so the matching
% frequency is 1/PeriodS. The controller holds the target, a Datum (steady
% OHB sample there) records the equilibrium, and the controller is switched
% off without a jolt before the pulse.
% The OHB is not sampled during the time series: each pulse's meta.DatumTest
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
PeriodsS = [1/0.5];         % <-- how long each pulse takes
AmplitudesDeg = [-10];      % <-- elevator pulse size (deg); negative = the other way
DelayS = 1;                 % quiet recording before the pulse starts
TailS = 8;                  % recorded after the pulse ends: the model's free response
HomePitchDeg = 0;           % where the controller leaves the model at the end

UsePxi = true;              % true: also record the 6-axis force sensor (PXI)
UseCamera = true;           % true: pulse the tracking camera around each dynamic record (needs UsePxi)
control = wt.hasta.ControlSettings();   % Kp 0.1, Ki 0.2, Kd 0.05, limit 20, CtrlGain -1, tolerance 0.2
% <-- fill in the model setup for this run
modelConfig = wt.hasta.ModelConfig(TankType="Liquid", TankDiameter_mm=50, FuelMass_g=165);

points = wt.hasta.testtype.BaseTestType.empty;
for pitch = TargetPitches
    for p = PeriodsS
        for a = AmplitudesDeg
            points(end+1) = wt.hasta.testtype.Cosine(PitchDeg=pitch, PeriodS=p, AmplitudeDeg=a, ...
                DelayS=DelayS, TailS=TailS); %#ok<SAGROW>
        end
    end
end

[hd, ohb, pxi] = wt.hasta.setupTestEnvironment(UsePxi=UsePxi, UseCamera=UseCamera);
results = wt.hasta.runTests(points, Hd=hd, Ohb=ohb, Pxi=pxi, Name="FreePitchCosine", ...
    ModelConfig=modelConfig, Control=control, HomePitchDeg=HomePitchDeg, ConfirmedAreaClear=true);
[hdData, ohbData, meta, pxiData] = deal(results.hdData, results.ohbData, results.meta, results.pxiData);
