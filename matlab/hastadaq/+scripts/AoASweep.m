% AoASweep: steady points over incidence (AoA) and elevator angle (beta).
% Each point moves the model, holds the elevators, and records the OHB, the
% Hasta DAQ (and the force sensor) for SampleS seconds; the averages are
% saved. Run scripts.ZeroRun (wind off) first.

AoAs = 0:3:6;
Betas = [-20 0 20];
SampleS = 5;               % sample time per point

UsePxi = false;            % true: also record the 6-axis force sensor (PXI)
UseCamera = false;         % true: pulse the tracking camera around each record (needs UsePxi)

% <-- fill in the model setup for this run
modelConfig = wt.hasta.ModelConfig(TankType="Solid", TankDiameter_mm=NaN, FuelMass_g=0);

points = wt.hasta.testtype.BaseTestType.empty;
for aoa = AoAs
    for beta = Betas
        points(end+1) = wt.hasta.testtype.Steady(IncidenceDeg=aoa, ElevatorDeg=beta, DurationS=SampleS); %#ok<SAGROW>
    end
end

[hd, ohb, pxi] = wt.hasta.setupTestEnvironment(UsePxi=UsePxi, UseCamera=UseCamera);
results = wt.hasta.runTests(points, Hd=hd, Ohb=ohb, Pxi=pxi, Name="AoASweep", ...
    ModelConfig=modelConfig, ConfirmedAreaClear=true);
[hdData, ohbData, meta, pxiData] = deal(results.hdData, results.ohbData, results.meta, results.pxiData);

ohb.moveIncidence(0, 2, 2, 2, blocking=true);   % leave the model at zero incidence
