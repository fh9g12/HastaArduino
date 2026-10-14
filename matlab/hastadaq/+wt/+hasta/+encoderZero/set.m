function set(offsetDeg)
% WT.HASTA.ENCODERZERO.SET Save the pitch encoder's zero offset.
%   wt.hasta.encoderZero.set(offsetDeg)
%
%   offsetDeg is what hd.getEncoderZeroOffset() returns right after the
%   encoder was zeroed with the model at its zero position (the raw
%   encoder angle that reads as 0). scripts.ZeroEncoderRun does this.
%   Stored as a MATLAB preference (per user, per MATLAB install) together
%   with the time it was saved.
    arguments
        offsetDeg (1,1) double {mustBeFinite}
    end
    [group, name] = zeroPref();
    saved = struct("OffsetDeg", mod(offsetDeg, 360), ...
        "SavedAt", char(datetime("now", Format="yyyy-MM-dd HH:mm:ss")));
    setpref(group, name, saved);
end
