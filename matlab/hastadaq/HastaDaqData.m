classdef HastaDaqData
    %HASTADAQDATA One HastaDAQ capture: sensors, excitation and the
    %commanded angle of each servo, one row per sample.
    %   Returned by HastaDaqClient.readData(). A plain value class, so an
    %   instance can be saved and loaded like any variable:
    %
    %   data = hd.readData();
    %   save("run01.mat", "data")            % HastaDaqData must be on the
    %                                        % path when you load it again
    %
    %   plot(data.Time, data.ELEV_L_Angle)
    %   plot(data.Time, data.ServoAngles)    % all five, N x 5
    %   data.Angle(HDCh.ElevL)               % same as data.ELEV_L_Angle
    %   T = data.ToTable();
    %
    %   Commanded servo angles are degrees from centre (the angle after the
    %   +/-48.06 deg clamp, not the raw request). There is one property
    %   per servo named <firmware name>_Angle. The board sends the angles
    %   in CHANNEL_DEFS order (HastaDAQ/ChannelMixer.h), which HDCh.m
    %   mirrors - FromBytes assigns them by that order.

    properties
        Datetime = NaT                              % when the data was fetched
        TimeMs (:,1) double = double.empty(0, 1)    % board time since boot (ms)
        Adc1Mv (:,1) double = double.empty(0, 1)    % strain bridge 1 (mV)
        Adc2Mv (:,1) double = double.empty(0, 1)    % strain bridge 2 (mV)
        EncoderDeg (:,1) double = double.empty(0, 1)
        Accel (:,3) double = zeros(0, 3)            % columns x, y, z
        Gyro (:,3) double = zeros(0, 3)             % columns x, y, z
        ExcitationDeg (:,1) double = double.empty(0, 1)      % shared waveform
        ControlOutputDeg (:,1) double = double.empty(0, 1)   % PID output, pre-mix

        % Commanded angle of each servo (deg from centre).
        RUDDER_Angle (:,1) double = double.empty(0, 1)
        ELEV_R_Angle (:,1) double = double.empty(0, 1)
        ELEV_L_Angle (:,1) double = double.empty(0, 1)
        AIL_R_Angle (:,1) double = double.empty(0, 1)
        AIL_L_Angle (:,1) double = double.empty(0, 1)
    end

    properties (Dependent)
        Time          % seconds since the first sample
        NumSamples
        ServoAngles   % N x 5, columns in HDCh declaration order
    end

    properties (Constant, Access = private)
        FixedBytes = 48   % t_us + 11 floats before the per-servo angles
    end

    methods (Static)
        function obj = FromBytes(raw, bytesPerSample)
            %FROMBYTES Build from the raw DATA? payload: a bytesPerSample
            %x N uint8 array (column k = sample k), little-endian, laid out
            %as HastaDaqSample in CaptureManager.h.
            arguments
                raw uint8
                bytesPerSample (1,1) double
            end
            surfaces = enumeration("HDCh");
            numChannels = (bytesPerSample - HastaDaqData.FixedBytes) / 4;
            if numChannels ~= numel(surfaces)
                error("HastaDaqData:badLayout", ...
                    "Board sent %g servo angles per sample but HDCh defines %d - " + ...
                    "keep HDCh.m in step with CHANNEL_DEFS in ChannelMixer.h.", ...
                    numChannels, numel(surfaces));
            end
            n = size(raw, 2);

            field = @(byteStart, count) double(typecast( ...
                reshape(raw(byteStart:byteStart + 4*count - 1, :), [], 1), "single"));

            obj = HastaDaqData();
            obj.Datetime = datetime("now");
            obj.TimeMs = double(typecast(reshape(raw(1:4, :), [], 1), "uint32")) / 1000;
            obj.Adc1Mv = field(5, 1);
            obj.Adc2Mv = field(9, 1);
            obj.EncoderDeg = field(13, 1);
            obj.Accel = reshape(field(17, 3), 3, n)';
            obj.Gyro = reshape(field(29, 3), 3, n)';
            obj.ExcitationDeg = field(41, 1);
            obj.ControlOutputDeg = field(45, 1);

            angles = reshape(field(49, numChannels), numChannels, n)';
            for k = 1:numel(surfaces)
                obj.(HastaDaqData.angleProperty(surfaces(k))) = angles(:, k);
            end
        end
    end

    methods
        function t = get.Time(obj)
            if isempty(obj.TimeMs)
                t = double.empty(0, 1);
            else
                t = (obj.TimeMs - obj.TimeMs(1)) / 1000;
            end
        end

        function n = get.NumSamples(obj)
            n = numel(obj.TimeMs);
        end

        function a = get.ServoAngles(obj)
            surfaces = enumeration("HDCh");
            a = zeros(obj.NumSamples, numel(surfaces));
            for k = 1:numel(surfaces)
                a(:, k) = obj.(HastaDaqData.angleProperty(surfaces(k)));
            end
        end

        function out = mean(obj)
            %MEAN Condense each capture to a single sample: the average of
            %every signal over the capture (NaNs ignored).
            %
            %   hdData = hd.readData();
            %   hdData = hdData.mean();
            %
            %   For steady tests, where the whole time series isn't worth
            %   keeping. It is explicit - readData() never does this itself.
            %   The result has one row (NumSamples is 1, Time is 0, TimeMs is
            %   the mean board time), Datetime is kept, and the original
            %   cannot be recovered from it. Works on an array too (each
            %   element condensed separately).
            out = obj;
            propList = metaclass(obj).PropertyList;
            propList = propList(~[propList.Dependent] & ~[propList.Constant]);
            names = string({propList.Name});
            names(names == "Datetime") = [];
            for e = 1:numel(obj)
                for name = names
                    out(e).(name) = mean(obj(e).(name), 1, "omitnan");
                end
            end
        end

        function a = Angle(obj, surface)
            %ANGLE Commanded angle of one servo, e.g. data.Angle(HDCh.ElevL).
            arguments
                obj
                surface (1,1) HDCh
            end
            a = obj.(HastaDaqData.angleProperty(surface));
        end

        function out = ToStruct(obj)
            %TOSTRUCT All properties (including Time, NumSamples,
            %ServoAngles) as a plain struct.
            names = properties(obj);
            out = struct();
            for k = 1:numel(names)
                out.(names{k}) = obj.(names{k});
            end
        end

        function T = ToTable(obj)
            %TOTABLE One row per sample; accel/gyro split into X/Y/Z columns.
            T = table(obj.Time, obj.TimeMs, obj.Adc1Mv, obj.Adc2Mv, obj.EncoderDeg, ...
                obj.Accel(:, 1), obj.Accel(:, 2), obj.Accel(:, 3), ...
                obj.Gyro(:, 1), obj.Gyro(:, 2), obj.Gyro(:, 3), ...
                obj.ExcitationDeg, obj.ControlOutputDeg, ...
                'VariableNames', ["Time", "TimeMs", "Adc1Mv", "Adc2Mv", "EncoderDeg", ...
                    "AccelX", "AccelY", "AccelZ", "GyroX", "GyroY", "GyroZ", ...
                    "ExcitationDeg", "ControlOutputDeg"]);
            surfaces = enumeration("HDCh");
            for k = 1:numel(surfaces)
                name = HastaDaqData.angleProperty(surfaces(k));
                T.(name) = obj.(name);
            end
        end
    end

    methods (Static, Access = private)
        function name = angleProperty(surface)
            %ANGLEPROPERTY Property holding a surface's angle, e.g.
            %HDCh.ElevL -> "ELEV_L_Angle".
            name = surface.WireName + "_Angle";
        end
    end
end
