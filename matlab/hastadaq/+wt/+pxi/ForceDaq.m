classdef ForceDaq < handle
    %FORCEDAQ The PXI/NI card that reads the 6-axis force sensor and starts the Arduino.
    %   One NI card (default "PXI1Slot4_2") with, on a single sample clock:
    %     ai0..ai5   the six strain-gauge voltages of the force/torque sensor
    %     ai6        the trigger line looped back (so the record carries its own marker)
    %     ao0        the trigger OUTPUT: 0 V, then 3.3 V for the record, then 0 V again.
    %                Wired to the Arduino's trigger-in pin, its rising edge starts a
    %                capture the Arduino has been ARMed for (hd.arm), and the excitation
    %                armed with it.
    %     ctr1       optional ~1 ms pulse to start/stop a tracking camera
    %
    %   pxi = wt.pxi.ForceDaq("PXI1Slot4_2");
    %   hd.arm(10, 100);                  % the Arduino waits for the edge ...
    %   f = pxi.acquire(10);              % ... and this raises it, then records 10 s
    %   d = hd.readData();                % both records start at the same edge
    %
    %   acquire BLOCKS MATLAB for the whole record (readwrite), so nothing else
    %   (such as polling the encoder) can run while it does.
    %
    %   The output ends every record at 0 V, so the line is low between runs and
    %   the next rising edge is a real edge. Keep it that way: make sure the
    %   output is low BEFORE arming the Arduino (the constructor and lowOutput
    %   do it).
    %
    %   NOT yet exercised against the real NI hardware (this was written
    %   against the Data Acquisition Toolbox calls in a colleague's script and
    %   tested with a stand-in): bench-check the trigger edge, the channel
    %   order against a known load, and the camera pulse width.

    properties (SetAccess = private)
        Card (1,1) string           % NI device name, e.g. "PXI1Slot4_2"
        Rate (1,1) double           % scans per second (set at construction)
        Calibration (1,1) struct    % wt.pxi.loadCalibration result
    end

    properties
        LeadInS (1,1) double {mustBeNonnegative} = 0.1      % output low for this long first, so the edge is inside the record
        TailLowS (1,1) double {mustBeNonnegative} = 0.05    % ... and low again at the end
        TriggerVolts (1,1) double {mustBePositive} = 3.3    % trigger level; must stay at what the Arduino pin tolerates
        CameraPulseS (1,1) double {mustBePositive} = 0.001  % camera pulse width
    end

    properties (Access = private)
        Dq          % the clocked input+output session
        DqCamera    % counter session for the camera pulse (created on first use)
    end

    methods
        function obj = ForceDaq(card, opts)
            %FORCEDAQ Open the session and drive the trigger output low.
            %   pxi = wt.pxi.ForceDaq("PXI1Slot4_2", rate=200, calibrationFile="FT78552.cal")
            arguments
                card (1,1) string = "PXI1Slot4_2"
                opts.rate (1,1) double {mustBePositive} = 200
                opts.calibrationFile (1,1) string = fullfile(fileparts(mfilename("fullpath")), "private", "FT78552.cal")
            end
            obj.Card = card;
            obj.Rate = opts.rate;
            obj.Calibration = wt.pxi.loadCalibration(opts.calibrationFile);

            obj.Dq = daq("ni");
            obj.Dq.Rate = obj.Rate;
            names = ["G0", "G1", "G2", "G3", "G4", "G5", "Trigger"];
            for i = 1:numel(names)
                ch = addinput(obj.Dq, card, "ai" + (i - 1), "Voltage");
                ch.Name = names(i);
            end
            addoutput(obj.Dq, card, "ao0", "Voltage");
            obj.lowOutput();
        end

        function lowOutput(obj)
            %LOWOUTPUT Drive the trigger output to 0 V (a short clocked write).
            readwrite(obj.Dq, zeros(max(2, round(0.05 * obj.Rate)), 1));
        end

        function data = acquire(obj, durationS, opts)
            %ACQUIRE Record durationS seconds of force data, raising the trigger.
            %   The output is low for LeadInS, high for durationS (this is the
            %   moment the Arduino's capture runs), then low for TailLowS and
            %   left at 0 V. Returns a wt.pxi.ForceData.
            %
            %   camera=true also sends the camera pulse just before the record
            %   starts and again just after it ends (start / stop tracking).
            arguments
                obj
                durationS (1,1) double {mustBePositive}
                opts.camera (1,1) logical = false
            end
            nLead = round(obj.LeadInS * obj.Rate);
            nHigh = round(durationS * obj.Rate);
            nTail = max(1, round(obj.TailLowS * obj.Rate));    % at least one sample, so it ends at 0 V
            out = [zeros(nLead, 1); obj.TriggerVolts * ones(nHigh, 1); zeros(nTail, 1)];
            if opts.camera
                obj.pulseCamera();
            end
            tt = readwrite(obj.Dq, out);
            if opts.camera
                obj.pulseCamera();
            end
            data = wt.pxi.ForceData.FromTimetable(tt, obj.Calibration);
        end

        function pulseCamera(obj)
            %PULSECAMERA One short pulse (CameraPulseS) on the camera counter output.
            %   Generated as a slow pulse train that is stopped before its second
            %   pulse, so exactly one pulse comes out.
            if isempty(obj.DqCamera)
                obj.DqCamera = daq("ni");
                ch = addoutput(obj.DqCamera, obj.Card, "ctr1", "PulseGeneration");
                periodS = 0.5;
                ch.Frequency = 1 / periodS;
                ch.DutyCycle = obj.CameraPulseS / periodS;
            end
            start(obj.DqCamera, "Duration", seconds(0.1));
            pause(0.15);
            if obj.DqCamera.Running
                stop(obj.DqCamera);
            end
        end
    end
end
