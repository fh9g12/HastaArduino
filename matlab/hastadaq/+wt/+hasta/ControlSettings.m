classdef ControlSettings
    %CONTROLSETTINGS The pitch controller's settings, in one place.
    %   control = wt.hasta.ControlSettings();                 % the defaults
    %   control = wt.hasta.ControlSettings(Kp=0.2, OutLimitDeg=10);
    %
    %   control.apply(hd);                    % send the gains and limit to the board
    %   r = control.hold(hd, 5);              % controller on, hold 5 deg, wait to settle
    %
    %   Kp, Ki, Kd     PID gains (error = target - encoder angle)
    %   OutLimitDeg    most the controller can move the elevators, deg
    %   CtrlGain       -1 if a positive controller output makes the pitch
    %                  error worse (depends how the elevators are mounted)
    %   ToleranceDeg   "settled" = within this of the target for 1 s
    %   Surfaces       the surfaces the controller drives
    %
    %   A value class: it is saved with each test point (ToStruct) so a data
    %   file records the gains that were used.

    properties
        Kp (1,1) double = 0.1
        Ki (1,1) double = 0.2
        Kd (1,1) double = 0.05
        OutLimitDeg (1,1) double {mustBePositive} = 20
        CtrlGain (1,1) double {mustBeInRange(CtrlGain, -1, 1)} = -1
        ToleranceDeg (1,1) double {mustBePositive} = 0.2
        Surfaces (1,:) wt.hasta.HDCh = [wt.hasta.HDCh.ElevR wt.hasta.HDCh.ElevL]
    end

    methods
        function obj = ControlSettings(opts)
            %CONTROLSETTINGS Construct, optionally with Name=Value property settings.
            arguments
                opts.Kp (1,1) double = 0.1
                opts.Ki (1,1) double = 0.2
                opts.Kd (1,1) double = 0.05
                opts.OutLimitDeg (1,1) double {mustBePositive} = 20
                opts.CtrlGain (1,1) double {mustBeInRange(opts.CtrlGain, -1, 1)} = -1
                opts.ToleranceDeg (1,1) double {mustBePositive} = 0.2
                opts.Surfaces (1,:) wt.hasta.HDCh = [wt.hasta.HDCh.ElevR wt.hasta.HDCh.ElevL]
            end
            for name = string(fieldnames(opts))'
                obj.(name) = opts.(name);
            end
        end

        function apply(obj, hd)
            %APPLY Send the gains and output limit to the board (the controller stays as it is).
            arguments
                obj
                hd (1,1) wt.hasta.DaqClient
            end
            hd.setControl(Kp=obj.Kp, Ki=obj.Ki, Kd=obj.Kd, outLimitDeg=obj.OutLimitDeg);
        end

        function result = hold(obj, hd, targetDeg, opts)
            %HOLD Controller on, hold targetDeg and wait for it to settle (hd.holdPitch).
            %   Returns hd.holdPitch's struct: settled, pitchDeg, errorDeg, timeS.
            %   THIS MOVES THE ELEVATORS AND THE MODEL.
            arguments
                obj
                hd (1,1) wt.hasta.DaqClient
                targetDeg (1,1) double {mustBeFinite}
                opts.timeoutS (1,1) double {mustBePositive} = 30
            end
            result = hd.holdPitch(targetDeg, surfaces=obj.Surfaces, ctrlGain=obj.CtrlGain, ...
                toleranceDeg=obj.ToleranceDeg, timeoutS=opts.timeoutS);
        end

        function out = ToStruct(obj)
            %TOSTRUCT The settings as a plain struct (surfaces as wire names).
            out = struct("Kp", obj.Kp, "Ki", obj.Ki, "Kd", obj.Kd, ...
                "OutLimitDeg", obj.OutLimitDeg, "CtrlGain", obj.CtrlGain, ...
                "ToleranceDeg", obj.ToleranceDeg, "Surfaces", [obj.Surfaces.WireName]);
        end
    end
end
