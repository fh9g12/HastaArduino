function saved = info()
% WT.HASTA.ENCODERZERO.INFO The saved encoder zero as a struct, or [] if none.
%   saved = wt.hasta.encoderZero.info()
%   saved.OffsetDeg   the offset, degrees in [0, 360)
%   saved.SavedAt     when it was saved ("yyyy-MM-dd HH:mm:ss")
    [group, name] = zeroPref();
    % NB: getpref(group, name, default) would CREATE the preference when it
    % is missing, so a read-only lookup has to check for it first.
    saved = [];
    if ispref(group, name)
        saved = getpref(group, name);
    end
    if ~isempty(saved) && ~(isstruct(saved) && isfield(saved, "OffsetDeg") && isfield(saved, "SavedAt"))
        error("wt:hasta:encoderZero:badValue", ...
            "The stored encoder zero isn't valid. Save a new one with scripts.ZeroEncoderRun.");
    end
end
