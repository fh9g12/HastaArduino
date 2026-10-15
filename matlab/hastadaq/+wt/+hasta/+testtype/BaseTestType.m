classdef (Abstract) BaseTestType < matlab.mixin.Heterogeneous
    %BASETESTTYPE One test point: a condition to set up and a measurement to make.
    %   Test points of different types go in one array, and
    %   wt.hasta.runTests runs it in order:
    %
    %     points = [ wt.hasta.testtype.Sine(PitchDeg=5, FreqHz=0.5, Cycles=6)
    %                wt.hasta.testtype.Chirp(PitchDeg=5, F1Hz=1.5)
    %                wt.hasta.testtype.Steady(IncidenceDeg=8, ElevatorDeg=-5) ];
    %
    %   The CONDITION is the same for every type (leave a field NaN to leave
    %   that part of the rig alone):
    %     IncidenceDeg   tunnel incidence (the OHB moves the model)
    %     ElevatorDeg    both elevators held at this angle (fixed-surface tests)
    %     SpeedMs        tunnel speed, ramped in steps of at most 5 m/s
    %     PitchDeg       model free to pitch: the controller holds this encoder
    %                    angle (NaN = not a free-pitch test; then the controller is off)
    %   The runner only changes what differs from the previous point, and takes
    %   a Datum (steady OHB sample) whenever a dynamic point's condition has no
    %   recent one. Time-series (dynamic) points are not sampled by the OHB,
    %   which only returns averages: their OHB data is a NaN placeholder and
    %   their meta.DatumTest says which Datum point they belong to.
    %
    %   Other common settings:
    %     Camera       pulse the tracking camera around this record (when the
    %                  force sensor's camera is enabled)
    %     ForceDatum   take a fresh Datum before this point even if the last
    %                  one is recent
    %
    %   Each type provides run(obj, session) (the measurement; returns a
    %   struct, see wt.hasta.TestSession) and describe(obj). To add a type,
    %   add one class to this package.

    properties
        IncidenceDeg (1,1) double = NaN
        ElevatorDeg (1,1) double = NaN
        SpeedMs (1,1) double = NaN
        PitchDeg (1,1) double = NaN
        Camera (1,1) logical = true
        ForceDatum (1,1) logical = false
    end

    properties (Dependent)
        TestType        % the meta.TestType this point is saved as (from typeName)
    end

    methods (Abstract)
        s = typeName(obj)            % "Sine", "Chirp", ... the meta.TestType
        r = run(obj, session)        % make the measurement; returns Hd, Ohb, Pxi, Parameters, StartTime
        s = describe(obj)            % short text for the progress output
    end

    methods
        function s = get.TestType(obj)
            s = obj.typeName();
        end

        function obj = BaseTestType(varargin)
            %BASETESTTYPE Set properties by Name=Value.
            if mod(numel(varargin), 2) ~= 0
                error("wt:hasta:testtype:badArgs", "Give Name=Value pairs.");
            end
            for k = 1:2:numel(varargin)
                obj.(varargin{k}) = varargin{k + 1};
            end
        end

        function tf = isFreePitch(obj)
            %ISFREEPITCH True when the controller holds PitchDeg.
            tf = ~isnan(obj.PitchDeg);
        end

        function tf = isDynamic(~)
            %ISDYNAMIC True for time-series tests (they need a Datum).
            tf = false;
        end

        function tf = moves(obj)
            %MOVES True when running this point moves the model or surfaces.
            tf = obj.isDynamic() || ~isnan(obj.ElevatorDeg) || ~isnan(obj.PitchDeg) || ~isnan(obj.IncidenceDeg);
        end

        function s = durationS(~)
            %DURATIONS Rough time the point takes, for the progress estimate.
            s = 10;
        end

        function c = condition(obj)
            %CONDITION The condition fields as a struct.
            c = struct("IncidenceDeg", obj.IncidenceDeg, "ElevatorDeg", obj.ElevatorDeg, ...
                "SpeedMs", obj.SpeedMs, "PitchDeg", obj.PitchDeg);
        end

        function p = conditionParameters(obj)
            %CONDITIONPARAMETERS The condition, under the names used in the saved meta.Parameters.
            p = struct();
            if ~isnan(obj.IncidenceDeg), p.AoA_deg = obj.IncidenceDeg; end
            if ~isnan(obj.ElevatorDeg), p.ElevatorDeg = obj.ElevatorDeg; end
            if ~isnan(obj.SpeedMs), p.VelocityTarget = obj.SpeedMs; end
            if ~isnan(obj.PitchDeg), p.TargetPitch_deg = obj.PitchDeg; end
        end

        function precheck(~, ~)
            %PRECHECK Called before the condition is applied; error to stop the run.
        end

        function recover(~, ~)
            %RECOVER Called after an error, best effort, to leave the rig safe.
        end

        function validate(obj)
            %VALIDATE Error if the condition is contradictory.
            if obj.isFreePitch() && ~isnan(obj.ElevatorDeg)
                error("wt:hasta:testtype:badCondition", ...
                    "%s: ElevatorDeg and PitchDeg together: with the model free to pitch the controller moves the elevators.", obj.TestType);
            end
        end
    end

    methods (Static, Sealed, Access = protected)
        function obj = getDefaultScalarElement()
            obj = wt.hasta.testtype.Steady();
        end
    end
end
