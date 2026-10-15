classdef SteppedChirp < wt.hasta.testtype.ExcitationTest
    %STEPPEDCHIRP A stepped square wave about a nominal angle with shrinking dwells.
    %   wt.hasta.testtype.SteppedChirp(PitchDeg=5, DeltaDeg=3, DeltaTS=2)
    %   wt.hasta.testtype.SteppedChirp(ElevatorDeg=0, NominalDeg=2, DeltaDeg=4, DeltaTS=1.5, SettleS=4)
    %
    %   From the nominal angle (the Datum's equilibrium when free to pitch,
    %   or NominalDeg) the surfaces go to nominal - DeltaDeg/2 and settle for
    %   SettleS, then step to nominal + DeltaDeg/2 and hold it for
    %   Dwells(1)*DeltaTS, step to nominal - DeltaDeg/2 for Dwells(2)*DeltaTS,
    %   and so on alternating, and finally return to nominal. With the default
    %   Dwells = [3 2 1 1] that is: +delta/2 for 3*deltaT, -delta/2 for
    %   2*deltaT, +delta/2 for 1*deltaT, -delta/2 for deltaT, then nominal -
    %   half-periods that shrink, so the sequence sweeps up in frequency. The
    %   steps are timed on the board.
    %
    %     DeltaDeg   total step size (peak to peak), elevator degrees
    %     DeltaTS    the dwell unit deltaT, s
    %     SettleS    time at the first level before the sequence (= DelayS)
    %     Dwells     multiples of DeltaTS, alternating up/down, up to 16
    %     TailS      recorded after it returns to nominal

    properties
        DeltaDeg (1,1) double = 2
        DeltaTS (1,1) double {mustBePositive} = 2
        Dwells (1,:) double {mustBePositive, mustBeFinite} = [3 2 1 1]
    end

    properties (Dependent)
        SettleS
    end

    methods
        function s = typeName(~)
            s = "SteppedChirp";
        end

        function obj = SteppedChirp(varargin)
            obj@wt.hasta.testtype.ExcitationTest("DelayS", 3, varargin{:});
        end

        function v = get.SettleS(obj)
            v = obj.DelayS;
        end

        function obj = set.SettleS(obj, v)
            obj.DelayS = v;
        end

        function t = firmwareType(~)
            t = "stepseq";
        end

        function validate(obj)
            validate@wt.hasta.testtype.ExcitationTest(obj);
            if numel(obj.Dwells) > 16
                error("wt:hasta:testtype:badDwells", "At most 16 dwells.");
            end
            if obj.DeltaDeg == 0
                error("wt:hasta:testtype:badDelta", "DeltaDeg is 0: there is nothing to step.");
            end
        end

        function s = describe(obj)
            s = sprintf("stepped chirp delta %g deg, deltaT %g s, dwells %s", obj.DeltaDeg, obj.DeltaTS, mat2str(obj.Dwells));
        end

        function args = excitationArgs(obj)
            args = {"periodS", obj.DeltaTS, "amplitudeDeg", obj.DeltaDeg / 2, "delayS", obj.DelayS, "dwells", obj.Dwells};
        end

        function s = excitationDurationS(obj)
            s = obj.DelayS + sum(obj.Dwells) * obj.DeltaTS;
        end
    end
end
