% FreePitchStep: STEP RESPONSE with the model free to pitch. For each target
% pitch angle and each delta in DeltaPitchDeg:
%   1. the controller holds the target; a Datum (steady OHB sample there) gives
%      the elevator angles that hold it
%   2. the controller moves the model delta degrees away and holds it there
%      (a short sample gives the elevator angles that hold THAT pitch)
%   3. the controller is switched off without a jolt - the elevators stay at
%      the displaced angles - and a "step" is ARMED on the board: PreStepS
%      after the record starts the elevators step to the target's angles,
%      timed on the board with no command from MATLAB. The response is
%      recorded for PostStepS after it
%   4. the controller brings the model back to the target for the next delta
% Without the force sensor the encoder is polled while recording and, if the
% pitch strays more than |delta| + OvershootAllowanceDeg from the target, the
% controller is switched straight back on (the point is flagged Aborted).
% With the force sensor MATLAB is blocked for the record, so there is no abort.
%
% Run scripts.ZeroEncoderRun once first (the pitch target is an encoder angle)
% and scripts.ZeroRun for the force-sensor zero, with the wind OFF.
% To mix different test types in one run, see scripts.FreePitchMixed.
%
% THIS MOVES THE ELEVATORS AND THE MODEL, WHICH IS FREE TO PITCH. Start with
% small deltas until you know how the model behaves. If the model runs away
% from a target instead of settling, the controller's sign is wrong:
% ControlSettings(CtrlGain=1).

TargetPitches = [5];        % pitch angles (encoder, deg) the step returns to
DeltaPitchDeg = [-5];       % <-- how far from each target to start, deg: one step test per delta
PreStepS = 2;               % recorded at the displaced pitch before the step, s
PostStepS = 10;             % recorded after the step, s
OvershootAllowanceDeg = 3;  % abort if pitch strays more than |delta| + this from the target (not with UsePxi)
HomePitchDeg = 0;           % where the controller leaves the model at the end

UsePxi = true;              % true: also record the 6-axis force sensor (PXI)
UseCamera = true;           % true: pulse the tracking camera around each step record (needs UsePxi)
control = wt.hasta.ControlSettings();   % Kp 0.1, Ki 0.2, Kd 0.05, limit 20, CtrlGain -1, tolerance 0.2
% <-- fill in the model setup for this run
modelConfig = wt.hasta.ModelConfig(TankType="Liquid", TankDiameter_mm=50, FuelMass_g=165);

points = wt.hasta.testtype.BaseTestType.empty;
for pitch = TargetPitches
    for delta = DeltaPitchDeg
        points(end+1) = wt.hasta.testtype.Step(PitchDeg=pitch, DeltaPitchDeg=delta, PreStepS=PreStepS, ...
            PostStepS=PostStepS, OvershootAllowanceDeg=OvershootAllowanceDeg); %#ok<SAGROW>
    end
end

[hd, ohb, pxi] = wt.hasta.setupTestEnvironment(UsePxi=UsePxi, UseCamera=UseCamera);
results = wt.hasta.runTests(points, Hd=hd, Ohb=ohb, Pxi=pxi, Name="FreePitchStep", ...
    ModelConfig=modelConfig, Control=control, HomePitchDeg=HomePitchDeg, ConfirmedAreaClear=true);
[hdData, ohbData, meta, pxiData] = deal(results.hdData, results.ohbData, results.meta, results.pxiData);
