classdef Chirp < wt.hasta.testtype.ExcitationTest
    %CHIRP A linear sweep F0Hz -> F1Hz over PeriodS (Cycles sweeps).
    %   wt.hasta.testtype.Chirp(PitchDeg=5, F0Hz=0.2, F1Hz=1, PeriodS=30, AmplitudeDeg=3)

    properties
        F0Hz (1,1) double {mustBePositive} = 0.2
        F1Hz (1,1) double {mustBePositive} = 1
        PeriodS (1,1) double {mustBePositive} = 30
        Cycles (1,1) double {mustBePositive} = 1
    end

    methods
        function s = typeName(~)
            s = "Chirp";
        end

        function obj = Chirp(varargin)
            obj@wt.hasta.testtype.ExcitationTest(varargin{:});
        end

        function s = describe(obj)
            s = sprintf("chirp %g->%g Hz over %g s, %g deg", obj.F0Hz, obj.F1Hz, obj.PeriodS, obj.AmplitudeDeg);
        end

        function args = excitationArgs(obj)
            args = {"f0", obj.F0Hz, "f1", obj.F1Hz, "periodS", obj.PeriodS, "amplitudeDeg", obj.AmplitudeDeg, ...
                "cycles", obj.Cycles, "delayS", obj.DelayS};
        end

        function s = excitationDurationS(obj)
            s = obj.DelayS + obj.Cycles * obj.PeriodS;
        end
    end
end
