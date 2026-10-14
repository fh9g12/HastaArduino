classdef ForceData
    %FORCEDATA One record from the 6-axis force/torque sensor (via the PXI).
    %   Returned by wt.pxi.ForceDaq.acquire. A value class, like
    %   wt.hasta.DaqData, so an instance can be saved and loaded as plain data.
    %
    %   f = pxi.acquire(10);
    %   plot(f.TimeFromTrigger, f.Forces())            % calibrated, no tare
    %   F = f.Forces(zeroRun.Gauges)                   % tared with a zero run's mean
    %
    %   What is stored is RAW: the six strain-gauge voltages and the
    %   trigger line. The calibration matrix is carried along but only
    %   applied on request (Forces), and no tare is subtracted, matching
    %   the rest of the data: nothing is zeroed at acquisition. For a tare
    %   use the mean gauge voltages of a wind-off record:
    %       bias = zeroData.mean().Gauges
    %
    %   TriggerVolts is the output line that also starts the Arduino,
    %   looped back into an analogue input, on the same sample clock as the
    %   gauges. Its rising edge (TriggerIndex) is the instant the Arduino's
    %   capture began, so TimeFromTrigger lines up with wt.hasta.DaqData.Time.
    %   The gauge channels are assumed to be in the calibration file's
    %   order (see wt.pxi.loadCalibration); check with a known load.

    properties
        Datetime = NaT                                  % when the record was taken
        Rate (1,1) double = NaN                         % samples per second
        Time (:,1) double = double.empty(0, 1)          % s from the first sample
        Gauges (:,6) double = zeros(0, 6)               % raw gauge voltages, calibration-file order
        TriggerVolts (:,1) double = double.empty(0, 1)  % the looped-back trigger output
        TriggerIndex (1,1) double = NaN                 % sample of its rising edge (NaN if not seen)
        Calibration (1,1) struct = struct()             % wt.pxi.loadCalibration result
    end

    properties (Dependent)
        NumSamples
        TimeFromTrigger   % Time relative to the trigger edge (NaN if the edge wasn't seen)
    end

    properties (Constant)
        TriggerThresholdV = 1.65   % half of the 3.3 V trigger level
    end

    methods (Static)
        function obj = FromTimetable(tt, calibration)
            %FROMTIMETABLE Build from the timetable readwrite returns: channels
            %named G0..G5 (the gauges) and Trigger.
            arguments
                tt timetable
                calibration (1,1) struct
            end
            obj = wt.pxi.ForceData();
            obj.Datetime = datetime("now");
            t = tt.Time;
            if isduration(t)
                t = seconds(t);
            end
            obj.Time = t(:) - t(1);
            if numel(t) > 1
                obj.Rate = 1 / median(diff(obj.Time));
            end
            obj.Gauges = tt{:, ["G0", "G1", "G2", "G3", "G4", "G5"]};
            obj.TriggerVolts = tt.Trigger;
            obj.TriggerIndex = wt.pxi.ForceData.risingEdge(obj.TriggerVolts);
            obj.Calibration = calibration;
        end

        function idx = risingEdge(v)
            %RISINGEDGE Index of the first sample that crosses the trigger
            %threshold upwards, or NaN if the record has no such edge (for
            %example it started with the line already high).
            thr = wt.pxi.ForceData.TriggerThresholdV;
            idx = find(v(2:end) > thr & v(1:end-1) <= thr, 1) + 1;
            if isempty(idx)
                idx = NaN;
            end
        end
    end

    methods
        function n = get.NumSamples(obj)
            n = numel(obj.Time);
        end

        function t = get.TimeFromTrigger(obj)
            if isnan(obj.TriggerIndex)
                t = nan(size(obj.Time));
            else
                t = obj.Time - obj.Time(obj.TriggerIndex);
            end
        end

        function ft = Forces(obj, biasVolts)
            %FORCES Calibrated loads, N x 6 = [Fx Fy Fz Tx Ty Tz] in the
            %calibration's units (N and N-m). biasVolts (1 x 6, default 0)
            %is subtracted from the gauge voltages first: use a zero run's
            %mean gauges, e.g. zeroData.mean().Gauges.
            arguments
                obj
                biasVolts (1,6) double = zeros(1, 6)
            end
            if ~isfield(obj.Calibration, "Matrix")
                error("wt:pxi:noCalibration", "This record carries no calibration matrix.");
            end
            ft = (obj.Gauges - biasVolts) * obj.Calibration.Matrix.';
        end

        function out = mean(obj)
            %MEAN Condense each record to one row: the average over the
            %window where the trigger line was high (that is, while the
            %Arduino was capturing), or over the whole record if it never
            %was. Explicit, like wt.hasta.DaqData.mean; works on arrays.
            out = obj;
            for e = 1:numel(obj)
                sel = obj(e).TriggerVolts > wt.pxi.ForceData.TriggerThresholdV;
                if ~any(sel)
                    sel = true(size(sel));
                end
                out(e).Time = mean(obj(e).Time(sel));
                out(e).Gauges = mean(obj(e).Gauges(sel, :), 1);
                out(e).TriggerVolts = mean(obj(e).TriggerVolts(sel));
                out(e).TriggerIndex = NaN;
            end
        end

        function T = ToTable(obj, biasVolts)
            %TOTABLE One row per sample: times, the six gauge voltages, the
            %trigger line, and the calibrated loads (tared if biasVolts given).
            arguments
                obj
                biasVolts (1,6) double = zeros(1, 6)
            end
            ft = obj.Forces(biasVolts);
            T = table(obj.Time, obj.TimeFromTrigger, obj.Gauges(:, 1), obj.Gauges(:, 2), obj.Gauges(:, 3), ...
                obj.Gauges(:, 4), obj.Gauges(:, 5), obj.Gauges(:, 6), obj.TriggerVolts, ...
                ft(:, 1), ft(:, 2), ft(:, 3), ft(:, 4), ft(:, 5), ft(:, 6), ...
                VariableNames=["Time", "TimeFromTrigger", "G0", "G1", "G2", "G3", "G4", "G5", "Trigger", ...
                    "Fx", "Fy", "Fz", "Tx", "Ty", "Tz"]);
        end

        function out = ToStruct(obj)
            %TOSTRUCT All properties as a struct.
            names = properties(obj);
            out = struct();
            for k = 1:numel(names)
                out.(names{k}) = obj.(names{k});
            end
        end
    end
end
