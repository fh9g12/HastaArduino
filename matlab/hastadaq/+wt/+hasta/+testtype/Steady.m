classdef Steady < wt.hasta.testtype.BaseTestType
    %STEADY A steady point: hold the condition, sample for DurationS, save the averages.
    %   wt.hasta.testtype.Steady(IncidenceDeg=4, ElevatorDeg=10)
    %   wt.hasta.testtype.Steady(PitchDeg=5)            % free to pitch, controller holding
    %   The OHB samples over the same time, so this is the point type for AoA
    %   and speed sweeps. The saved Hasta DAQ, force and OHB data are averages.

    properties
        DurationS (1,1) double {mustBePositive} = 4
    end

    methods
        function s = typeName(~)
            s = "Steady";
        end

        function obj = Steady(varargin)
            obj@wt.hasta.testtype.BaseTestType(varargin{:});
        end

        function s = describe(obj)
            s = sprintf("%gs %s", obj.DurationS, obj.conditionText());
        end

        function s = durationS(obj)
            s = obj.DurationS + 2;
        end

        function r = run(obj, session)
            if obj.isFreePitch()
                session.ensureHeld(obj.PitchDeg);
            end
            rec = session.recordSteady(obj.DurationS, obj.Camera);
            r = struct("Hd", rec.Hd.mean(), "Ohb", rec.Ohb, "Pxi", rec.Pxi.mean(), ...
                "StartTime", rec.StartTime, "Equilibrium", rec.Hd, ...
                "Parameters", obj.conditionParameters());
        end
    end

    methods (Access = protected)
        function s = conditionText(obj)
            parts = strings(1, 0);
            if ~isnan(obj.SpeedMs), parts(end+1) = sprintf("V=%g", obj.SpeedMs); end
            if ~isnan(obj.IncidenceDeg), parts(end+1) = sprintf("AoA=%g", obj.IncidenceDeg); end
            if ~isnan(obj.ElevatorDeg), parts(end+1) = sprintf("beta=%g", obj.ElevatorDeg); end
            if ~isnan(obj.PitchDeg), parts(end+1) = sprintf("pitch=%g", obj.PitchDeg); end
            s = strjoin(parts, " ");
        end
    end
end
