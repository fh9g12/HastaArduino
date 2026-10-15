classdef Random < wt.hasta.testtype.ExcitationTest
    %RANDOM A random gust: a slice of the board's stored von Karman turbulence record.
    %   wt.hasta.testtype.Random(PitchDeg=5, DurationS=20, AmplitudeDeg=3)
    %   wt.hasta.testtype.Random(PitchDeg=5, DurationS=20, StartOffsetS=12)
    %
    %   The board holds one 60 s turbulence position record (peak = 1, from
    %   matlab/hastadaq/tools/exportTurbulenceProfile.m). The test plays
    %   DurationS seconds of it starting StartOffsetS in (default 0, so the same
    %   settings always give the same gust), scaled by AmplitudeDeg (elevator
    %   degrees, or the Surfaces you give) and tapered smoothly to zero at both
    %   ends, after DelayS of quiet recording. Different StartOffsetS are
    %   different gusts, still repeatable: for a quasi-random series make one
    %   point per explicit offset, e.g. for off = [0 10 20 30]. Set
    %   StartOffsetS=NaN to draw a random offset when the point is created
    %   (saved in meta.Parameters.Excitation.startOffsetS).
    %
    %   StartOffsetS + DurationS must fit the record (59.98 s).

    properties
        DurationS (1,1) double {mustBePositive} = 20
        StartOffsetS (1,1) double = 0       % NaN = draw a random offset at creation
    end

    methods
        function s = typeName(~)
            s = "Random";
        end

        function obj = Random(varargin)
            obj@wt.hasta.testtype.ExcitationTest(varargin{:});
            if isnan(obj.StartOffsetS)
                room = wt.hasta.DaqClient.TurbulenceRecordS - obj.DurationS;
                if room < 0
                    error("wt:hasta:testtype:badRandom", "DurationS %g s is longer than the %g s turbulence record.", ...
                        obj.DurationS, wt.hasta.DaqClient.TurbulenceRecordS);
                end
                obj.StartOffsetS = round(rand * room, 2);
            end
        end

        function validate(obj)
            validate@wt.hasta.testtype.ExcitationTest(obj);
            if obj.StartOffsetS < 0 || obj.StartOffsetS + obj.DurationS > wt.hasta.DaqClient.TurbulenceRecordS
                error("wt:hasta:testtype:badRandom", "StartOffsetS + DurationS (%g s) is beyond the %g s turbulence record.", ...
                    obj.StartOffsetS + obj.DurationS, wt.hasta.DaqClient.TurbulenceRecordS);
            end
        end

        function s = describe(obj)
            s = sprintf("random gust %g s from %g s, %g deg", obj.DurationS, obj.StartOffsetS, obj.AmplitudeDeg);
        end

        function args = excitationArgs(obj)
            args = {"startOffsetS", obj.StartOffsetS, "durationS", obj.DurationS, ...
                "amplitudeDeg", obj.AmplitudeDeg, "delayS", obj.DelayS};
        end

        function s = excitationDurationS(obj)
            s = obj.DelayS + obj.DurationS;
        end
    end
end
