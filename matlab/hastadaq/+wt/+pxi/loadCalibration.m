function cal = loadCalibration(file)
% WT.PXI.LOADCALIBRATION Read an ATI force/torque sensor calibration file.
%   cal = wt.pxi.loadCalibration()            % the Mini40 file shipped in private/
%   cal = wt.pxi.loadCalibration("other.cal")
%
%   The .cal file is XML. As the file itself says, only the "UserAxis" rows
%   should be used to build the matrix. Returns a struct:
%     Matrix      6 x 6: rows Fx Fy Fz Tx Ty Tz, columns the six strain-gauge
%                 channels in order. [Fx..Tz] = Matrix * (gaugeVolts - biasVolts)
%     AxisNames   ["Fx" "Fy" "Fz" "Tx" "Ty" "Tz"]
%     MaxLoad     full-scale load of each axis, in the units below
%     ForceUnits, TorqueUnits   e.g. "N", "N-m"
%     Serial, PartNumber, CalDate, File
    arguments
        file (1,1) string = fullfile(fileparts(mfilename("fullpath")), "private", "FT78552.cal")
    end
    s = readstruct(file, FileType="xml");
    c = s.Calibration;
    axes = c.UserAxis;
    if numel(axes) ~= 6
        error("wt:pxi:badCalibration", "%s should have 6 UserAxis rows, found %d.", file, numel(axes));
    end
    matrix = zeros(6, 6);
    for i = 1:6
        row = str2double(split(strtrim(string(axes(i).valuesAttribute))))';
        if numel(row) ~= 6 || any(isnan(row))
            error("wt:pxi:badCalibration", "UserAxis %s in %s doesn't hold six numbers.", string(axes(i).NameAttribute), file);
        end
        matrix(i, :) = row;
    end
    cal = struct( ...
        "Matrix", matrix, ...
        "AxisNames", string({axes.NameAttribute}), ...
        "MaxLoad", double([axes.maxAttribute]), ...
        "ForceUnits", string(c.ForceUnitsAttribute), ...
        "TorqueUnits", string(c.TorqueUnitsAttribute), ...
        "Serial", string(s.SerialAttribute), ...
        "PartNumber", string(c.PartNumberAttribute), ...
        "CalDate", string(c.CalDateAttribute), ...
        "File", file);
end
