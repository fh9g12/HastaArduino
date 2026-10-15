classdef (Abstract) ExcitationTest < wt.hasta.testtype.BaseTestType
    %EXCITATIONTEST A time-series test: one armed waveform on the elevators, recorded.
    %   Base of Sine, Cosine and Chirp. Free to pitch (PitchDeg set) it runs
    %   from the Datum's equilibrium: the controller is switched off without
    %   a jolt (the elevators keep the angles that held the target) unless
    %   ControllerDuring is true, and the waveform rides on top. At a fixed
    %   elevator angle (PitchDeg NaN) the waveform is added to that angle.
    %
    %     DelayS        quiet recording before the waveform starts
    %     TailS         recording after it ends (the free response)
    %     AmplitudeDeg  waveform size, elevator degrees (negative = the other way)
    %     Surfaces      the surfaces that follow the waveform
    %     ControllerDuring  leave the controller running during the waveform
    %     NominalDeg    the elevator angle the waveform is about; NaN (default) =
    %                   the Datum's equilibrium angles (free to pitch) or the
    %                   fixed ElevatorDeg. A value moves the surfaces there
    %                   (controller off) before the record starts.
    %
    %   The OHB is not sampled during these (it only returns averages): the
    %   Datum is the reference, and meta.DatumTest points at it.

    properties
        AmplitudeDeg (1,1) double = 1
        DelayS (1,1) double {mustBeNonnegative} = 1
        TailS (1,1) double {mustBeNonnegative} = 2
        Surfaces (1,:) wt.hasta.HDCh = [wt.hasta.HDCh.ElevR wt.hasta.HDCh.ElevL]
        ControllerDuring (1,1) logical = false
        NominalDeg (1,1) double = NaN
    end

    methods (Abstract)
        args = excitationArgs(obj)            % name/value pairs for hd.setExcitation (after the type)
        s = excitationDurationS(obj)          % delay + the waveform itself, excluding the tail
    end

    methods
        function obj = ExcitationTest(varargin)
            obj@wt.hasta.testtype.BaseTestType(varargin{:});
        end

        function tf = isDynamic(~)
            tf = true;
        end

        function t = firmwareType(obj)
            %FIRMWARETYPE The type name the board knows this waveform by.
            t = lower(obj.TestType);
        end

        function validate(obj)
            validate@wt.hasta.testtype.BaseTestType(obj);
            if obj.ControllerDuring && ~isnan(obj.NominalDeg)
                error("wt:hasta:testtype:badCondition", ...
                    "%s: NominalDeg and ControllerDuring together: the controller would fight the nominal angle.", obj.TestType);
            end
        end

        function s = durationS(obj)
            s = obj.excitationDurationS() + obj.TailS;
        end

        function r = run(obj, session)
            hd = session.Hd;
            trims = [];
            if obj.isFreePitch()
                session.ensureHeld(obj.PitchDeg);
                if obj.ControllerDuring
                    hd.setMix(obj.Surfaces, excGain=1);
                elseif ~isnan(obj.NominalDeg)
                    trims = repmat(obj.NominalDeg, 1, numel(obj.Surfaces));
                    hd.setMix(obj.Surfaces, trimDeg=trims, excGain=1, ctrlGain=0);
                    hd.disableControl();
                else
                    trims = hd.openLoopAtEquilibrium(session.Datum.Equilibrium, surfaces=obj.Surfaces, excGain=1);
                end
            elseif ~isnan(obj.NominalDeg)
                trims = repmat(obj.NominalDeg, 1, numel(obj.Surfaces));
                hd.setMix(obj.Surfaces, trimDeg=trims, excGain=1);
            else
                hd.setMix(obj.Surfaces, excGain=1);
            end
            args = obj.excitationArgs();
            hd.setExcitation(obj.firmwareType(), args{:}, "armed", true);
            session.log("%s: recording %.0f s ...", obj.describe(), obj.durationS());
            rec = session.recordDynamic(obj.durationS(), obj.Camera);
            hd.disarmExcitation();
            session.markDisturbed();
            params = obj.conditionParameters();
            params.ControllerOn = obj.ControllerDuring;
            params.Excitation = struct(args{:});
            params.EquilibriumTrimDeg = trims;
            r = struct("Hd", rec.Hd, "Ohb", session.emptyOhb(), "Pxi", rec.Pxi, ...
                "StartTime", rec.StartTime, "Parameters", params);
        end

        function recover(obj, session)
            session.Hd.disarmExcitation();
            if obj.isFreePitch()
                session.Control.hold(session.Hd, obj.PitchDeg, timeoutS=5);
            end
        end
    end
end
