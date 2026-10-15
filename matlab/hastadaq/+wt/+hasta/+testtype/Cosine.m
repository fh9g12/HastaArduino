classdef Cosine < wt.hasta.testtype.ExcitationTest
    %COSINE A 1-cosine pulse on the elevators: 0 -> AmplitudeDeg -> 0 over PeriodS.
    %   wt.hasta.testtype.Cosine(PitchDeg=5, PeriodS=2, AmplitudeDeg=-10)
    %   PeriodS is the whole pulse (it peaks at PeriodS/2): the matching
    %   frequency is 1/PeriodS. One pulse per record (Cycles = 1).

    properties
        PeriodS (1,1) double {mustBePositive} = 2
        Cycles (1,1) double {mustBePositive} = 1
    end

    methods
        function s = typeName(~)
            s = "Cosine";
        end

        function obj = Cosine(varargin)
            obj@wt.hasta.testtype.ExcitationTest("TailS", 8, varargin{:});
        end

        function s = describe(obj)
            s = sprintf("cosine pulse %g s, %g deg", obj.PeriodS, obj.AmplitudeDeg);
        end

        function args = excitationArgs(obj)
            args = {"periodS", obj.PeriodS, "amplitudeDeg", obj.AmplitudeDeg, "cycles", obj.Cycles, "delayS", obj.DelayS};
        end

        function s = excitationDurationS(obj)
            s = obj.DelayS + obj.Cycles * obj.PeriodS;
        end
    end
end
