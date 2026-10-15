% AoA_V_Sweep: steady points over tunnel speed, incidence (AoA) and elevator
% angle (beta). The tunnel ramps to each speed in steps of at most 5 m/s; the
% full beta sweep is done only at the AoAs in BetaAoAs (the others: beta = 0).
% Each point records the OHB, the Hasta DAQ (and the force sensor) for
% SampleS seconds and saves the averages. Run scripts.ZeroRun (wind off) first.

% AoAs = -5:1.25:22.5;
AoAs = -5:1.25:6.25;
Betas = unique([-40, -30:5:30, 40]);
Vs = 40;
BetaAoAs = -5:5:20;        % only at these AoAs is the full Betas sweep done (others: Beta = 0)
SampleS = 4;               % sample time per point

UsePxi = false;            % true: also record the 6-axis force sensor (PXI)
UseCamera = false;         % true: pulse the tracking camera around each record (needs UsePxi)

% <-- fill in the model setup for this run
modelConfig = wt.hasta.ModelConfig(TankType="Solid", TankDiameter_mm=NaN, FuelMass_g=0);

points = wt.hasta.testtype.BaseTestType.empty;
for v = Vs
    for aoa = AoAs
        betas = 0;
        if ismember(aoa, BetaAoAs)
            betas = Betas;
        end
        for beta = betas
            points(end+1) = wt.hasta.testtype.Steady(SpeedMs=v, IncidenceDeg=aoa, ElevatorDeg=beta, DurationS=SampleS); %#ok<SAGROW>
        end
    end
end

[hd, ohb, pxi] = wt.hasta.setupTestEnvironment(UsePxi=UsePxi, UseCamera=UseCamera);
results = wt.hasta.runTests(points, Hd=hd, Ohb=ohb, Pxi=pxi, Name="AoAVSweep", ...
    ModelConfig=modelConfig, ConfirmedAreaClear=true);
[hdData, ohbData, meta, pxiData] = deal(results.hdData, results.ohbData, results.meta, results.pxiData);

%% wind down (after the data is saved, so a problem here can't lose it)
fprintf("Stopping the tunnel ...\n");
ohb.moveIncidence(0, 2, 2, 2, blocking=true);
% ohb.SetWindSpeed(0, blocking=true);
% ohb.StopAll();
fprintf("Done.\n");
