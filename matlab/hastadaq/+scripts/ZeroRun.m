% ZeroRun: wind-off zeroing run. Moves the model to zero incidence and the
% elevators to zero, checks the saved pitch-encoder zero (scripts.ZeroEncoderRun)
% reads ~0, takes one sample from the OHB, the Hasta DAQ (and the force
% sensor) and saves it as a run. The other scripts record the latest of these
% in each test point's meta.ZeroRun, and the force sensor's mean gauge
% voltages here are the tare for the later runs: pxiData(k).Forces(zeroGauges).
% Nothing is subtracted at acquisition.
%
% Run with the wind OFF. This script checks that, and stops if it isn't.

UsePxi = false;        % true: also record the 6-axis force sensor (PXI)
UseCamera = false;     % true: pulse the tracking camera around the record (needs UsePxi)

% <-- keep in step with the model setup in AoASweep
modelConfig = wt.hasta.ModelConfig(TankType="Liquid", TankDiameter_mm=50, FuelMass_g=165);

[hd, ohb, pxi] = wt.hasta.setupTestEnvironment(UsePxi=UsePxi, UseCamera=UseCamera);

results = wt.hasta.runTests(wt.hasta.testtype.Zero(), Hd=hd, Ohb=ohb, Pxi=pxi, ...
    Name="ZeroRun", ModelConfig=modelConfig, ConfirmedAreaClear=true);
[hdData, ohbData, meta, pxiData] = deal(results.hdData, results.ohbData, results.meta, results.pxiData);
