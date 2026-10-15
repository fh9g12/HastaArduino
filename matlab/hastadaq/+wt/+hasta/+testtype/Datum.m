classdef Datum < wt.hasta.testtype.Steady
    %DATUM Steady conditions at this attitude, the reference for dynamic points.
    %   Same measurement as Steady (OHB sampled, averages saved) but saved as
    %   TestType "Datum", and its equilibrium is what the dynamic tests start
    %   from. The runner takes one automatically before a dynamic point when
    %   there is none for that condition or it is older than DatumMaxAgeS
    %   (default 60 s); put one in the array yourself to take it at a chosen
    %   moment, or set ForceDatum=true on a point to refresh it before that point.

    methods
        function s = typeName(~)
            s = "Datum";
        end

        function obj = Datum(varargin)
            obj@wt.hasta.testtype.Steady("Camera", false, varargin{:});   % the reference is not filmed unless asked
        end
    end
end
