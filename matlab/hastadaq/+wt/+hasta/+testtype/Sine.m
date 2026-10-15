classdef Sine < wt.hasta.testtype.ExcitationTest
    %SINE A sine on the elevators: FreqHz, AmplitudeDeg, Cycles periods.
    %   wt.hasta.testtype.Sine(PitchDeg=5, FreqHz=0.5, AmplitudeDeg=2, Cycles=8)
    %   A stepped-sine sweep is one Sine per frequency:
    %   arrayfun(@(f) wt.hasta.testtype.Sine(PitchDeg=5, FreqHz=f), 0.2:0.05:1)
    %   (build the array with [...], see wt.hasta.testtype.BaseTestType).

    properties
        FreqHz (1,1) double {mustBePositive} = 0.5
        Cycles (1,1) double {mustBePositive} = 8
    end

    methods
        function s = typeName(~)
            s = "Sine";
        end

        function obj = Sine(varargin)
            obj@wt.hasta.testtype.ExcitationTest(varargin{:});
        end

        function s = describe(obj)
            s = sprintf("sine %g Hz, %g deg, %g cycles", obj.FreqHz, obj.AmplitudeDeg, obj.Cycles);
        end

        function args = excitationArgs(obj)
            args = {"freqHz", obj.FreqHz, "amplitudeDeg", obj.AmplitudeDeg, "cycles", obj.Cycles, "delayS", obj.DelayS};
        end

        function s = excitationDurationS(obj)
            s = obj.DelayS + obj.Cycles / obj.FreqHz;
        end
    end
end
