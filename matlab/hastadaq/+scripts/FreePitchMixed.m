% FreePitchMixed: several test types in ONE run, free to pitch. The point of
% the test-point classes: build one array of whatever you like (any mix of
% wt.hasta.testtype.Steady / Datum / Sine / Cosine / Chirp / Step, at any
% conditions) and wt.hasta.runTests runs it in order. The rig is only changed
% where a point's condition differs from the last one, and a Datum (steady OHB
% sample) is taken automatically when a dynamic point has none for its
% condition newer than DatumMaxAgeS. Put a wt.hasta.testtype.Datum in the
% array yourself, or set ForceDatum=true on a point, to take one at a moment
% you choose.
%
% This example, at one pitch angle: sines, a chirp, a pulse, a random gust, a
% stepped chirp and a step.
% Edit the array to suit; the other FreePitch* scripts are single-type
% versions of the same thing.
%
% THIS MOVES THE ELEVATORS AND THE MODEL, WHICH IS FREE TO PITCH. If the
% model runs away from a target instead of settling, the controller's sign
% is wrong: ControlSettings(CtrlGain=1).

PitchDeg = 5;
HomePitchDeg = 0;           % where the controller leaves the model at the end
DatumMaxAgeS = 60;          % retake the datum when the last one is older than this

UsePxi = false;             % true: also record the 6-axis force sensor (PXI)
UseCamera = true;           % true: pulse the tracking camera around each dynamic record (needs UsePxi)
control = wt.hasta.ControlSettings();   % Kp 0.1, Ki 0.2, Kd 0.05, limit 20, CtrlGain -1, tolerance 0.2
% <-- fill in the model setup for this run
modelConfig = wt.hasta.ModelConfig(TankType="Liquid", TankDiameter_mm=50, FuelMass_g=165);

points = [ ...
    wt.hasta.testtype.Sine(PitchDeg=PitchDeg, FreqHz=0.5, AmplitudeDeg=2, Cycles=6)
    wt.hasta.testtype.Sine(PitchDeg=PitchDeg, FreqHz=0.8, AmplitudeDeg=2, Cycles=6)
    wt.hasta.testtype.Chirp(PitchDeg=PitchDeg, F0Hz=0.2, F1Hz=1, PeriodS=30, AmplitudeDeg=3)
    wt.hasta.testtype.Cosine(PitchDeg=PitchDeg, PeriodS=2, AmplitudeDeg=-5)
    wt.hasta.testtype.Random(PitchDeg=PitchDeg, DurationS=20, AmplitudeDeg=3)
    wt.hasta.testtype.SteppedChirp(PitchDeg=PitchDeg, DeltaDeg=3, DeltaTS=2)
    wt.hasta.testtype.Step(PitchDeg=PitchDeg, DeltaPitchDeg=-3, ForceDatum=true)
    ];

[hd, ohb, pxi] = wt.hasta.setupTestEnvironment(UsePxi=UsePxi, UseCamera=UseCamera);
results = wt.hasta.runTests(points, Hd=hd, Ohb=ohb, Pxi=pxi, Name="FreePitchMixed", ...
    ModelConfig=modelConfig, Control=control, DatumMaxAgeS=DatumMaxAgeS, HomePitchDeg=HomePitchDeg, ConfirmedAreaClear=true);
[hdData, ohbData, meta, pxiData] = deal(results.hdData, results.ohbData, results.meta, results.pxiData);
