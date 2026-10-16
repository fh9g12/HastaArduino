% PerVelocityRun: the full free-to-pitch test set for ONE tunnel speed. Run it
% once per velocity (set the speed in the tunnel, or give SpeedMs below and the
% OHB ramps to it). Five groups of test points, all with the model free to
% pitch and the controller holding each pitch before the test:
%   1. CHIRP         pitches [-5 0 5] x amplitudes [1 2 3] deg, one 60 s sweep each
%   2. SINE          pitches [-5 0 5] x amplitudes [1 3] deg x each frequency in SineFreqsHz
%   3. 1-COSINE      pitches [-5 0 5] x periods 1/[0.5 1 2 4 6 8 10] Hz x amplitudes [-5 -10] deg
%   4. TURBULENCE    pitch 0 x amplitudes [1 2 3] deg, one gust (the stored von Karman record) each
%   5. STEPPED CHIRP pitches [-5 0 5] x deltaT [2 1] s x delta [4 8 12] deg
% The OHB is not sampled during the time series: the runner takes a Datum
% (steady OHB sample at the pitch) whenever the last one for that pitch is older
% than a minute, and each dynamic point's meta.DatumTest points at it.
%
% Points are sorted by pitch (-5, then 0, then 5), each pitch running the five
% groups in the order above.
%
% Roughly an hour per velocity (see the plan printed at the start). Check the
% sine frequencies and the shortest cosine pulses (0.1 s at 10 Hz is faster than
% the servos can follow) before a long run.
%
% Run scripts.ZeroEncoderRun once first (the pitch targets are encoder angles)
% and scripts.ZeroRun for the force-sensor zero, with the wind OFF.
%
% THIS MOVES THE ELEVATORS AND THE MODEL, WHICH IS FREE TO PITCH. If the model
% runs away from a target instead of settling, the controller's sign is wrong:
% ControlSettings(CtrlGain=1).

Pitches = [-5 0 5];          % pitch angles (encoder, deg)
SpeedMs = NaN;               % tunnel speed for this run; NaN = leave the tunnel as it is
HomePitchDeg = 0;            % where the controller leaves the model at the end

% 1. chirps
ChirpAmplitudesDeg = [1 2 3];
ChirpF0Hz = 0.2;  ChirpF1Hz = 1;  ChirpPeriodS = 70;

% 2. sines
SineAmplitudesDeg = [1 3];
SineFreqsHz = 0.2:0.1:1;     % <-- check: "0.2:0.1:0.1" was given
SineCycles = 8;

% 3. 1-cosine pulses
CosineFreqsHz = [0.5 1 2 4 6 8 10];      % pulse period = 1/frequency
CosineAmplitudesDeg = [-5 -10];

% 4. turbulence
TurbulencePitches = 0;
TurbulenceAmplitudesDeg = [3];
TurbulenceDurationS = 50;    % of the 59.98 s stored record, from StartOffsetS = 0

% 5. stepped chirp
SteppedDeltaTS = [];
SteppedDeltasDeg = [];

UsePxi = true;               % true: also record the 6-axis force sensor (PXI)
UseCamera = true;            % true: pulse the tracking camera around each dynamic record (needs UsePxi)
control = wt.hasta.ControlSettings();   % Kp 0.1, Ki 0.2, Kd 0.05, limit 20, CtrlGain -1, tolerance 0.2
% <-- fill in the model setup for this run
modelConfig = wt.hasta.ModelConfig(TankType="Liquid", TankDiameter_mm=50, FuelMass_g=165);

points = wt.hasta.testtype.BaseTestType.empty;
for p = Pitches                                           % 1. chirps
    for a = ChirpAmplitudesDeg
        points(end+1) = wt.hasta.testtype.Chirp(PitchDeg=p, SpeedMs=SpeedMs, F0Hz=ChirpF0Hz, F1Hz=ChirpF1Hz, ...
            PeriodS=ChirpPeriodS, AmplitudeDeg=a); %#ok<SAGROW>
    end
end
for p = Pitches                                           % 2. sines
    for a = SineAmplitudesDeg
        for f = SineFreqsHz
            points(end+1) = wt.hasta.testtype.Sine(PitchDeg=p, SpeedMs=SpeedMs, FreqHz=f, AmplitudeDeg=a, ...
                Cycles=SineCycles); %#ok<SAGROW>
        end
    end
end
for p = Pitches                                           % 3. 1-cosine pulses
    for a = CosineAmplitudesDeg
        for f = CosineFreqsHz
            points(end+1) = wt.hasta.testtype.Cosine(PitchDeg=p, SpeedMs=SpeedMs, PeriodS=1/f, AmplitudeDeg=a); %#ok<SAGROW>
        end
    end
end
for p = TurbulencePitches                                 % 4. turbulence
    for a = TurbulenceAmplitudesDeg
        points(end+1) = wt.hasta.testtype.Random(PitchDeg=p, SpeedMs=SpeedMs, DurationS=TurbulenceDurationS, ...
            AmplitudeDeg=a); %#ok<SAGROW>
    end
end
for p = Pitches                                           % 5. stepped chirps
    for dt = SteppedDeltaTS
        for d = SteppedDeltasDeg
            points(end+1) = wt.hasta.testtype.SteppedChirp(PitchDeg=p, SpeedMs=SpeedMs, DeltaDeg=d, DeltaTS=dt); %#ok<SAGROW>
        end
    end
end

% everything at -5 first, then 0, then 5: one pitch move per pitch instead of one per group,
% and the data at a pitch is taken close together. sort is stable, so within a pitch
% the groups stay in the order above.
[~, order] = sort([points.PitchDeg]);
points = points(order);

[hd, ohb, pxi] = wt.hasta.setupTestEnvironment(UsePxi=UsePxi, UseCamera=UseCamera);
results = wt.hasta.runTests(points, Hd=hd, Ohb=ohb, Pxi=pxi, Name="PerVelocityRun", ...
    ModelConfig=modelConfig, Control=control, HomePitchDeg=HomePitchDeg, ConfirmedAreaClear=true);
[hdData, ohbData, meta, pxiData] = deal(results.hdData, results.ohbData, results.meta, results.pxiData);
