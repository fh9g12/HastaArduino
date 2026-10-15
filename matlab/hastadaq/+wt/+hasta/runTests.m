function results = runTests(points, opts)
%RUNTESTS Run an array of test points in order, record the data and save it.
%   [hd, ohb, pxi] = wt.hasta.setupTestEnvironment(UsePxi=true);
%   points = [ wt.hasta.testtype.Sine(PitchDeg=5, FreqHz=0.5)
%              wt.hasta.testtype.Chirp(PitchDeg=5) ];
%   results = wt.hasta.runTests(points, Hd=hd, Ohb=ohb, Pxi=pxi, Name="MyTest", ...
%                 ModelConfig=wt.hasta.ModelConfig(TankType="Liquid", TankDiameter_mm=50, FuelMass_g=165), ...
%                 ConfirmedAreaClear=true);
%
%   Points can be of any mix of wt.hasta.testtype classes. For each one the
%   rig is brought to its condition (only what differs from the last point
%   changes), dynamic points get a Datum (a steady OHB sample at that
%   condition, retaken when older than DatumMaxAgeS or on request), and the
%   point's own run records the data. The OHB only samples steady points.
%
%   Saves data/Run<NN>_<Name>_<time>.mat with the four parallel arrays
%   hdData, ohbData, meta, pxiData (a _partial file if anything fails, with
%   the rig made safe before the error is re-thrown), and returns them in a
%   struct (results.hdData, .ohbData, .meta, .pxiData, .filename).
%
%   Options:
%     Hd, Ohb, Pxi        from wt.hasta.setupTestEnvironment (Ohb/Pxi may be [])
%     Name                for the file name
%     ModelConfig         how the model is set up (wt.hasta.ModelConfig)
%     Control             wt.hasta.ControlSettings (default: the defaults)
%     RunNumber           default: the next one (wt.runNum.increment())
%     DatumMaxAgeS        default 60
%     SampleHz            board sample rate, default 100
%     HomePitchDeg        free-pitch: hold the model here at the end (NaN = leave it)
%     ConfirmedAreaClear  must be true if any point moves the model or surfaces
    arguments
        points (1,:) wt.hasta.testtype.BaseTestType
        opts.Hd (1,1) wt.hasta.DaqClient
        opts.Ohb = []
        opts.Pxi = []
        opts.Name (1,1) string = "Tests"
        opts.ModelConfig (1,1) wt.hasta.ModelConfig = wt.hasta.ModelConfig()
        opts.Control (1,1) wt.hasta.ControlSettings = wt.hasta.ControlSettings()
        opts.RunNumber (1,1) double = NaN
        opts.DatumMaxAgeS (1,1) double {mustBePositive} = 60
        opts.SampleHz (1,1) double {mustBePositive} = 100
        opts.HomePitchDeg (1,1) double = NaN
        opts.ConfirmedAreaClear (1,1) logical = false
    end
    if any(arrayfun(@(p) p.moves(), points))
        assert(opts.ConfirmedAreaClear, ...
            "These tests move the model or surfaces: pass ConfirmedAreaClear=true once the area is clear.");
    end
    runNumber = opts.RunNumber;
    if isnan(runNumber)
        runNumber = wt.runNum.increment();   % saved in a MATLAB preference; wt.runNum.get() reads it, wt.runNum.set(n) sets it
    end
    session = wt.hasta.TestSession(Hd=opts.Hd, Ohb=opts.Ohb, Pxi=opts.Pxi, Control=opts.Control, ...
        SampleHz=opts.SampleHz, DatumMaxAgeS=opts.DatumMaxAgeS, RunNumber=runNumber, Name=opts.Name, ...
        ModelConfig=opts.ModelConfig);
    opts.Control.apply(opts.Hd);
    results = session.execute(points, HomePitchDeg=opts.HomePitchDeg);
end
