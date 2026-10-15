classdef TestSession < handle
    %TESTSESSION The state of one test run: the connections, the data so far, the datum.
    %   Created and driven by wt.hasta.runTests; the test types
    %   (wt.hasta.testtype.*) use it to set up the rig and to record.
    %
    %   For a test type's run(obj, session):
    %     session.Hd / Ohb / Pxi / Control / SampleHz / Datum    the pieces
    %     session.ensureHeld(pitchDeg)    controller holding the target (skips if it already is)
    %     session.recordSteady(durationS, camera)    OHB + board + force sensor, all full records
    %     session.recordDynamic(durationS, camera)   board + force sensor only (the OHB only averages)
    %     session.markDisturbed()         the model was moved off its target
    %     session.log(fmt, ...)           indented progress text
    %   run returns a struct: Hd, Ohb, Pxi (the data), StartTime, Parameters
    %   (and Equilibrium, the full capture a Datum starts the dynamic tests from).

    properties (SetAccess = private)
        Hd                    % wt.hasta.DaqClient
        Ohb = []              % the tunnel computer, or []
        Pxi = []              % wt.pxi.ForceDaq, or []
        Control               % wt.hasta.ControlSettings
        SampleHz (1,1) double = 100
        Datum = []            % latest datum: Condition, Equilibrium (full capture), TestNumber, EndTime
        DatumMaxAgeS (1,1) double = 60
        RunNumber (1,1) double = NaN
        Name (1,1) string = "Tests"
        Filename (1,1) string = ""
        ZeroRun (1,1) string = ""
        ModelConfig (1,1) wt.hasta.ModelConfig
        WindSpeed (1,1) double = NaN
        Condition = []        % the condition the rig is in now (struct)
        OnTarget (1,1) logical = false    % free-pitch: the controller is holding the target
        HdData = wt.hasta.DaqData.empty
        OhbData = wt.OHBData.empty
        PxiData = wt.pxi.ForceData.empty
        Meta = wt.hasta.MetaData.empty
        Planned (1,1) double = 0          % points in the plan (the datums taken automatically are extra)
        PlannedSeconds (1,1) double = 0
        DoneSeconds (1,1) double = 0
    end

    properties (Access = private)
        Timer
        HealthOK = false
    end

    properties (Dependent)
        HasForceSensor
    end

    methods
        function obj = TestSession(opts)
            arguments
                opts.Hd (1,1) wt.hasta.DaqClient
                opts.Ohb = []
                opts.Pxi = []
                opts.Control (1,1) wt.hasta.ControlSettings = wt.hasta.ControlSettings()
                opts.SampleHz (1,1) double = 100
                opts.DatumMaxAgeS (1,1) double = 60
                opts.RunNumber (1,1) double
                opts.Name (1,1) string = "Tests"
                opts.ModelConfig (1,1) wt.hasta.ModelConfig = wt.hasta.ModelConfig()
                opts.DataDir (1,1) string = "data"
            end
            obj.Hd = opts.Hd;
            obj.Ohb = opts.Ohb;
            obj.Pxi = opts.Pxi;
            obj.Control = opts.Control;
            obj.SampleHz = opts.SampleHz;
            obj.DatumMaxAgeS = opts.DatumMaxAgeS;
            obj.RunNumber = opts.RunNumber;
            obj.Name = opts.Name;
            obj.ModelConfig = opts.ModelConfig;
            if ~isfolder(opts.DataDir)
                mkdir(opts.DataDir);
            end
            obj.Filename = string(fullfile(opts.DataDir, sprintf("Run%02d_%s_%s.mat", obj.RunNumber, obj.Name, ...
                char(datetime("now", Format="yyyyMMdd_HHmmss")))));
            obj.ZeroRun = wt.hasta.getLastZeroRun(opts.DataDir);
        end

        function tf = get.HasForceSensor(obj)
            tf = ~isempty(obj.Pxi);
        end

        function log(~, fmt, varargin)
            %LOG Indented progress text.
            fprintf("      " + fmt + "\n", varargin{:});
        end

        function ohb = emptyOhb(~)
            %EMPTYOHB The OHB placeholder for points it did not sample (all NaN).
            ohb = wt.OHBData();
        end

        function markDisturbed(obj)
            %MARKDISTURBED A dynamic test moved the model: it is no longer on its target.
            obj.OnTarget = false;
        end

        function r = ensureHeld(obj, pitchDeg)
            %ENSUREHELD Controller holding pitchDeg; does nothing if it already is.
            r = [];
            if ~obj.OnTarget
                r = obj.Control.hold(obj.Hd, pitchDeg);
                obj.log("controller holding %g deg: pitch %.2f, error %+.2f, %s after %.1f s", pitchDeg, ...
                    r.pitchDeg, r.errorDeg, settledText(r.settled), r.timeS);
                obj.OnTarget = true;
            end
        end

        function rec = recordSteady(obj, durationS, camera)
            %RECORDSTEADY Record durationS s from the board, the force sensor and the OHB.
            %   Returns Hd and Pxi (the full records), Ohb (the OHB's average) and StartTime.
            rec.StartTime = datetime("now");
            if ~isempty(obj.Ohb)
                obj.Ohb.sample(durationS);
            end
            [rec.Hd, rec.Pxi] = wt.pxi.record(obj.Hd, obj.Pxi, durationS, obj.SampleHz, camera=obj.useCamera(camera));
            if isempty(obj.Ohb)
                rec.Ohb = obj.emptyOhb();
            else
                pause(0.25)
                rec.Ohb = wt.OHBData.FromString(obj.Ohb.readLastSample);
            end
        end

        function rec = recordDynamic(obj, durationS, camera)
            %RECORDDYNAMIC Record durationS s from the board and the force sensor (not the OHB).
            rec.StartTime = datetime("now");
            [rec.Hd, rec.Pxi] = wt.pxi.record(obj.Hd, obj.Pxi, durationS, obj.SampleHz, camera=obj.useCamera(camera));
        end
    end

    methods
        function results = execute(obj, points, opts)
            %EXECUTE Run the array of test points in order; returns the data and saves it.
            arguments
                obj
                points (1,:) wt.hasta.testtype.BaseTestType
                opts.HomePitchDeg (1,1) double = NaN
            end
            for p = points
                p.validate();
            end
            obj.Planned = numel(points);
            obj.PlannedSeconds = sum(arrayfun(@(p) p.durationS(), points));
            if ~isempty(obj.Ohb)
                obj.WindSpeed = obj.Ohb.readWindSpeed();
            end
            obj.printPlan(points);
            if ~any(arrayfun(@(p) p.TestType == "Zero", points))
                obj.checkZeroRun();
            end
            obj.Timer = tic;
            obj.printHealth("board at start");
            current = [];
            try
                for i = 1:numel(points)
                    current = points(i);
                    fprintf("[%d/%d] %s  %s\n", i, obj.Planned, current.TestType, current.describe());
                    obj.runPoint(current);
                end
            catch ME
                obj.saveFile(replace(obj.Filename, ".mat", "_partial.mat"));
                fprintf("\n!!! Stopped after %d data point(s): %s\n", numel(obj.Meta), ME.message);
                fprintf("!!! Partial data saved to %s\n", replace(obj.Filename, ".mat", "_partial.mat"));
                fprintf("!!! MATLAB has reconnected to the board %d time(s) this session\n", obj.Hd.ReconnectCount);
                if ~isempty(obj.Hd.LastHealth)
                    fprintf("!!! last good board reading: %s\n", wt.hasta.DaqClient.formatHealth(obj.Hd.LastHealth));
                end
                if ~isempty(current) && current.isDynamic()
                    try
                        current.recover(obj);
                        fprintf("!!! The rig has been made safe (excitation disarmed%s).\n", ...
                            controllerNote(current));
                    catch
                        fprintf("!!! Could not reach the board to make the rig safe.\n");
                    end
                end
                rethrow(ME);
            end
            obj.saveFile(obj.Filename);
            fprintf("\nSaved %d data point(s) to %s (took %s)\n", numel(obj.Meta), obj.Filename, formatDuration(toc(obj.Timer)));
            obj.printHealth("board at end");
            if ~isnan(opts.HomePitchDeg)
                obj.Control.hold(obj.Hd, opts.HomePitchDeg);
                fprintf("Controller holding the model at %g deg (it is left running).\n", opts.HomePitchDeg);
            end
            results = struct("hdData", obj.HdData, "ohbData", obj.OhbData, "meta", obj.Meta, ...
                "pxiData", obj.PxiData, "filename", obj.Filename);
        end
    end

    methods (Access = private)
        function runPoint(obj, point)
            point.precheck(obj);
            obj.setCondition(point);
            if point.isDynamic()
                obj.ensureDatum(point);
            end
            r = point.run(obj);
            obj.add(point, r);
        end

        function ensureDatum(obj, point)
            % A datum for this condition no older than DatumMaxAgeS, else take one now.
            c = obj.Condition;
            stale = isempty(obj.Datum) || ~isequaln(obj.Datum.Condition, c) ...
                || seconds(datetime("now") - obj.Datum.EndTime) > obj.DatumMaxAgeS || point.ForceDatum;
            if stale
                why = "none yet";
                if ~isempty(obj.Datum)
                    why = sprintf("last one is %.0f s old", seconds(datetime("now") - obj.Datum.EndTime));
                    if ~isequaln(obj.Datum.Condition, c), why = "new condition"; end
                    if point.ForceDatum, why = "requested"; end
                end
                fprintf("    taking a datum (%s)\n", why);
                datum = wt.hasta.testtype.Datum(IncidenceDeg=point.IncidenceDeg, ElevatorDeg=point.ElevatorDeg, ...
                    SpeedMs=point.SpeedMs, PitchDeg=point.PitchDeg);
                obj.runPoint(datum);
            end
        end

        function setCondition(obj, point)
            % Bring the rig to the point's condition, changing only what differs.
            want = point.condition();
            prev = obj.Condition;
            first = isempty(prev);
            if first
                prev = struct("IncidenceDeg", NaN, "ElevatorDeg", NaN, "SpeedMs", NaN, "PitchDeg", NaN);
            end
            eff = prev;                                   % NaN = leave as it is
            for f = ["IncidenceDeg", "ElevatorDeg", "SpeedMs"]
                if ~isnan(want.(f)), eff.(f) = want.(f); end
            end
            eff.PitchDeg = want.PitchDeg;                 % NaN here means not free to pitch
            changed = @(f) ~isequaln(eff.(f), prev.(f)) || first;
            wasFree = ~isnan(prev.PitchDeg);
            free = ~isnan(eff.PitchDeg);
            hd = obj.Hd;

            if ~isnan(want.SpeedMs) && changed("SpeedMs") && ~isempty(obj.Ohb)
                obj.rampSpeed(eff.SpeedMs);
                obj.WindSpeed = obj.Ohb.readWindSpeed();
                obj.printHealth("board");
            end
            if ~free && (first || wasFree)
                hd.disableControl();                      % off before fixed-elevator tests
            end
            if ~isnan(want.IncidenceDeg) && changed("IncidenceDeg") && ~isempty(obj.Ohb)
                if ~free && ~first
                    hd.setSteady(obj.Control.Surfaces, 0);   % elevators to 0 before the model moves
                    prev.ElevatorDeg = NaN;                  % ... so the elevator angle is set again below
                end
                fprintf("    incidence -> %g deg\n", eff.IncidenceDeg);
                obj.Ohb.moveIncidence(eff.IncidenceDeg, 2, 2, 2, blocking=true);
            end
            if ~free
                if ~isnan(want.ElevatorDeg) && (~isequaln(eff.ElevatorDeg, prev.ElevatorDeg) || wasFree || first)
                    hd.setSteady(obj.Control.Surfaces, eff.ElevatorDeg, settleS=0.5);
                end
                obj.OnTarget = false;
            else
                if first || ~wasFree || changed("PitchDeg")
                    obj.OnTarget = false;
                end
                obj.ensureHeld(eff.PitchDeg);
            end
            obj.Condition = eff;
        end

        function add(obj, point, r)
            k = numel(obj.Meta) + 1;
            params = r.Parameters;
            params.Control = obj.Control.ToStruct();
            params.WindSpeed_ms = obj.WindSpeed;
            params.PxiUsed = obj.HasForceSensor;
            datumTest = NaN;
            if point.isDynamic() && ~isempty(obj.Datum)
                datumTest = obj.Datum.TestNumber;
            end
            obj.HdData(k) = r.Hd;
            obj.OhbData(k) = r.Ohb;
            obj.PxiData(k) = r.Pxi;
            obj.Meta(k) = wt.hasta.MetaData(Datetime=r.StartTime, RunNumber=obj.RunNumber, TestNumber=k-1, ...
                TestType=point.TestType, Filename=obj.Filename, ZeroRun=obj.ZeroRun, ModelConfig=obj.ModelConfig, ...
                DatumTest=datumTest, Parameters=params);
            if point.TestType == "Datum"
                obj.Datum = struct("Condition", obj.Condition, "Equilibrium", r.Equilibrium, ...
                    "TestNumber", k - 1, "EndTime", datetime("now"));
            end
            obj.DoneSeconds = obj.DoneSeconds + point.durationS();
            elapsed = toc(obj.Timer);
            eta = "?";
            if obj.DoneSeconds > 0
                eta = formatDuration(elapsed / obj.DoneSeconds * max(0, obj.PlannedSeconds - obj.DoneSeconds));
            end
            fprintf("    saved as test %d (%s): %d samples | elapsed %s, ETA %s\n", k - 1, point.TestType, ...
                r.Hd.NumSamples, formatDuration(elapsed), eta);
        end

        function use = useCamera(obj, camera)
            use = obj.HasForceSensor && obj.Pxi.Camera && camera;
        end

        function rampSpeed(obj, target)
            % Ramp the tunnel to target in steps of at most 5 m/s (up or down).
            if target > 40 || target < 0
                error("wt:hasta:badSpeed", "Invalid speed target %g m/s.", target);
            end
            ohb = obj.Ohb;
            currentSpeed = ohb.readWindSpeed();
            tries = 1;
            while isnan(currentSpeed)
                if tries >= 30
                    error("wt:hasta:noWindSpeed", "Could not read the tunnel wind speed from the OHB server.");
                end
                pause(1);
                currentSpeed = ohb.readWindSpeed();
                tries = tries + 1;
            end
            nSteps = max(1, ceil(abs(target - currentSpeed) / 5));
            steps = linspace(currentSpeed, target, nSteps + 1);
            for s = 2:numel(steps)
                fprintf("    wind speed -> %.1f m/s\n", steps(s));
                ohb.SetWindSpeed(steps(s), blocking=true);
                pause(0.5);
            end
        end

        function checkZeroRun(obj)
            if obj.ZeroRun == ""
                warning("wt:hasta:noZeroRun", "No zero run found - run scripts.ZeroRun first.");
            elseif ~contains(obj.ZeroRun, sprintf("Run%02d_", obj.RunNumber))
                warning("wt:hasta:oldZeroRun", "The last zero run is from a different run number: %s", obj.ZeroRun);
            end
        end

        function printPlan(obj, points)
            types = string(arrayfun(@(p) char(p.TestType), points, UniformOutput=false));
            [names, ~, idx] = unique(types, "stable");
            counts = accumarray(idx(:), 1)';
            fprintf("\n=== %s, run %d ===\n", obj.Name, obj.RunNumber);
            fprintf("%d points: %s\n", numel(points), strjoin(names + " x" + string(counts), ", "));
            fprintf("Roughly %s, plus a datum whenever a dynamic point has none newer than %g s\n", ...
                formatDuration(obj.PlannedSeconds), obj.DatumMaxAgeS);
            fprintf("Controller: %s | force sensor %s%s\n", jsonencode(obj.Control.ToStruct()), ...
                onOff(obj.HasForceSensor), cameraNote(obj));
            fprintf("Saving to %s\n\n", obj.Filename);
        end

        function printHealth(obj, label)
            % One line of board link health, a single attempt only (a board that
            % isn't answering must not hold the run up). Tried once up front.
            if label == "board at start"
                obj.HealthOK = true;
            end
            if ~obj.HealthOK
                return
            end
            attempts = obj.Hd.MaxAttempts;
            obj.Hd.MaxAttempts = 1;
            try
                fprintf("    %s: %s | MATLAB reconnects %d\n", label, ...
                    wt.hasta.DaqClient.formatHealth(obj.Hd.getHealth()), obj.Hd.ReconnectCount);
            catch ME
                fprintf("    %s: health unavailable (%s)\n", label, extractBefore(string(ME.message) + " (", " ("));
                obj.HealthOK = false;
            end
            obj.Hd.MaxAttempts = attempts;
        end

        function saveFile(obj, file)
            hdData = obj.HdData;
            ohbData = obj.OhbData;
            meta = obj.Meta;
            pxiData = obj.PxiData;
            save(file, "hdData", "ohbData", "meta", "pxiData");
        end
    end
end

function str = settledText(settled)
    str = "NOT settled";
    if settled
        str = "settled";
    end
end

function str = onOff(tf)
    str = "OFF";
    if tf
        str = "ON";
    end
end

function str = cameraNote(obj)
    str = "";
    if obj.HasForceSensor && obj.Pxi.Camera
        str = " + camera";
    end
end

function str = controllerNote(point)
    str = "";
    if point.isFreePitch()
        str = ", controller back on";
    end
end

function str = formatDuration(seconds)
% h:mm:ss
    seconds = round(seconds);
    str = sprintf("%d:%02d:%02d", floor(seconds / 3600), floor(mod(seconds, 3600) / 60), mod(seconds, 60));
end
