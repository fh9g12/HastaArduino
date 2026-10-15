classdef Zero < wt.hasta.testtype.Steady
    %ZERO Wind-off zeroing sample: incidence 0, elevators 0, wind must be off.
    %   wt.hasta.runTests(wt.hasta.testtype.Zero(), Name="ZeroRun", ...)
    %   Saved as TestType "Zero"; later runs record the file of the latest one
    %   (meta.ZeroRun) so the force sensors can be zeroed in post-processing.
    %   Stops if the wind is not off. Nothing is subtracted at acquisition.

    properties
        MaxWindMs (1,1) double = 0.25     % wind speed above this stops the run
        EncoderCheckDeg (1,1) double = 0.5
    end

    methods
        function s = typeName(~)
            s = "Zero";
        end

        function obj = Zero(varargin)
            obj@wt.hasta.testtype.Steady("IncidenceDeg", 0, "ElevatorDeg", 0, "DurationS", 5, varargin{:});
        end

        function precheck(obj, session)
            if isempty(session.Ohb)
                return
            end
            windSpeed = session.Ohb.readWindSpeed();
            assert(~isnan(windSpeed), "Could not read the wind speed from the OHB server.");
            assert(abs(windSpeed) <= obj.MaxWindMs, ...
                "Wind speed is %.2f m/s - turn the wind off before a zero run.", windSpeed);
        end

        function r = run(obj, session)
            encoderDeg = session.Hd.getEncoderDeg();
            session.log("the encoder reads %.3f deg at zero incidence", encoderDeg);
            if abs(encoderDeg) > obj.EncoderCheckDeg
                warning("wt:hasta:testtype:encoderOff", ...
                    "The encoder reads %.2f deg at zero incidence - has it moved? Re-run scripts.ZeroEncoderRun if so.", encoderDeg);
            end
            r = run@wt.hasta.testtype.Steady(obj, session);
            r.Parameters.EncoderDeg = encoderDeg;
        end
    end
end
