classdef Step < wt.hasta.testtype.BaseTestType
    %STEP Free-to-pitch step response: from DeltaPitchDeg away back to PitchDeg.
    %   wt.hasta.testtype.Step(PitchDeg=5, DeltaPitchDeg=-5)
    %
    %   The Datum gives the elevator angles that hold PitchDeg. The controller
    %   then holds the model DeltaPitchDeg away, a short capture gives the
    %   angles that hold THAT, the controller is switched off without a jolt
    %   (elevators stay at the displaced angles) and a "step" is armed on the
    %   board: PreStepS after the record starts the elevators step to the
    %   target's angles, timed on the board. The record runs for
    %   PreStepS + PostStepS.
    %
    %   With no force sensor the encoder is polled while recording and, if the
    %   pitch strays more than |delta| + OvershootAllowanceDeg from the target,
    %   the controller is switched straight back on (the point is flagged
    %   Aborted). With the force sensor MATLAB is blocked for the record, so
    %   there is no abort.

    properties
        DeltaPitchDeg (1,1) double = 3
        DisplacedS (1,1) double {mustBePositive} = 2          % capture at the displaced pitch, s
        PreStepS (1,1) double {mustBeNonnegative} = 2         % recorded before the step, s
        PostStepS (1,1) double {mustBePositive} = 10          % recorded after the step, s
        OvershootAllowanceDeg (1,1) double = 3
        Surfaces (1,:) wt.hasta.HDCh = [wt.hasta.HDCh.ElevR wt.hasta.HDCh.ElevL]
    end

    methods
        function s = typeName(~)
            s = "Step";
        end

        function obj = Step(varargin)
            obj@wt.hasta.testtype.BaseTestType(varargin{:});
        end

        function tf = isDynamic(~)
            tf = true;
        end

        function validate(obj)
            validate@wt.hasta.testtype.BaseTestType(obj);
            if ~obj.isFreePitch()
                error("wt:hasta:testtype:badCondition", "Step needs PitchDeg: it steps a model that is free to pitch.");
            end
        end

        function s = describe(obj)
            s = sprintf("step from %+g deg away, %g s + %g s", obj.DeltaPitchDeg, obj.PreStepS, obj.PostStepS);
        end

        function s = durationS(obj)
            s = obj.PreStepS + obj.PostStepS + obj.DisplacedS + 15;
        end

        function r = run(obj, session)
            hd = session.Hd;
            target = obj.PitchDeg;
            displaced = target + obj.DeltaPitchDeg;
            columns = arrayfun(@(sf) sf.column(), obj.Surfaces);
            trimsTarget = meanAngles(session.Datum.Equilibrium, obj.Surfaces);

            % the elevator angles that hold the displaced pitch
            r0 = session.Control.hold(hd, displaced);
            session.log("holding the displaced pitch %g deg: pitch %.2f, %s after %.1f s", displaced, r0.pitchDeg, settledText(r0.settled), r0.timeS);
            displacedEq = hd.capture(obj.DisplacedS, session.SampleHz);
            trimsDisplaced = meanAngles(displacedEq, obj.Surfaces);

            % controller off at those angles (no jolt) and a step armed that takes each
            % surface to the target's angle: excGain = its step / the largest step
            hd.openLoopAtEquilibrium(displacedEq, surfaces=obj.Surfaces, excGain=0);
            stepDeg = trimsTarget - trimsDisplaced;
            stepAmplitude = max(abs(stepDeg));
            if stepAmplitude < 0.05
                warning("wt:hasta:testtype:noStep", "The elevator angles at the two pitches differ by less than 0.05 deg: there will be no step to record.");
                stepAmplitude = 0;
                stepGains = zeros(size(stepDeg));
            else
                stepGains = stepDeg / stepAmplitude;
            end
            hd.setMix(obj.Surfaces, excGain=stepGains);
            hd.setExcitation("step", amplitudeDeg=stepAmplitude, delayS=obj.PreStepS, armed=true);

            totalS = obj.PreStepS + obj.PostStepS;
            session.log("recording %.0f s; elevators step by %s deg after %.1f s ...", totalS, mat2str(round(stepDeg, 2)), obj.PreStepS);
            aborted = false;
            abortS = NaN;
            if session.HasForceSensor
                % the force sensor raises the trigger and blocks MATLAB for the record
                rec = session.recordDynamic(totalS, obj.Camera);
            else
                rec = struct("StartTime", datetime("now"), "Pxi", wt.pxi.ForceData());
                hd.run(totalS, session.SampleHz);          % MATLAB stays free to watch the model
                clk = tic;
                while toc(clk) < totalS
                    pitch = hd.getEncoderDeg();
                    if abs(pitch - target) > abs(obj.DeltaPitchDeg) + obj.OvershootAllowanceDeg
                        aborted = true;
                        abortS = toc(clk);
                        session.log("!!! pitch %.2f deg is %.1f deg from the target: switching the controller back on", pitch, abs(pitch - target));
                        session.Control.hold(hd, target, timeoutS=10);
                        break
                    end
                    pause(0.05);
                end
                hd.waitForDone(totalS + 30);
                rec.Hd = hd.readData();
            end
            hd.disarmExcitation();
            session.markDisturbed();

            % when did the elevators really step? (from the recorded angles, not the nominal delay)
            elevTrace = mean(rec.Hd.ServoAngles(:, columns), 2);
            before = median(elevTrace(rec.Hd.Time < 0.5 * obj.PreStepS));
            after = mean(trimsTarget);
            stepTimeS = NaN;   % stays NaN if the point was aborted before the step was due
            if ~(aborted && abortS < obj.PreStepS) && abs(after - before) > 0.05
                idx = find(abs(elevTrace - before) > 0.5 * abs(after - before), 1);
                if ~isempty(idx)
                    stepTimeS = rec.Hd.Time(idx);
                end
            end

            params = obj.conditionParameters();
            params.DeltaPitch_deg = obj.DeltaPitchDeg;
            params.DisplacedPitch_deg = displaced;
            params.StepSurfaces = [obj.Surfaces.WireName];
            params.StepFromDeg = trimsDisplaced;
            params.StepToDeg = trimsTarget;
            params.StepAmplitudeDeg = stepAmplitude;
            params.StepGains = stepGains;
            params.PreStepS = obj.PreStepS;
            params.PostStepS = obj.PostStepS;
            params.StepDelayS = obj.PreStepS;
            params.StepTimeS = stepTimeS;
            params.PitchExcursionDeg = max(abs(rec.Hd.EncoderDeg - target));
            params.Aborted = aborted;
            params.AbortS = abortS;
            params.ControllerOn = false;
            r = struct("Hd", rec.Hd, "Ohb", session.emptyOhb(), "Pxi", rec.Pxi, ...
                "StartTime", rec.StartTime, "Parameters", params);
            session.log("step at %.2f s, pitch %.2f -> %.2f deg%s", stepTimeS, rec.Hd.EncoderDeg(1), rec.Hd.EncoderDeg(end), abortedText(aborted));
        end

        function recover(obj, session)
            session.Hd.disarmExcitation();
            session.Control.hold(session.Hd, obj.PitchDeg, timeoutS=5);
        end
    end
end

function trims = meanAngles(data, surfaces)
% The average commanded angle of each surface over a capture, as a row.
    trims = zeros(1, numel(surfaces));
    for i = 1:numel(surfaces)
        trims(i) = mean(data.Angle(surfaces(i)), "omitnan");
    end
end

function str = abortedText(aborted)
    str = "";
    if aborted
        str = "  ABORTED";
    end
end

function str = settledText(settled)
    str = "NOT settled";
    if settled
        str = "settled";
    end
end
