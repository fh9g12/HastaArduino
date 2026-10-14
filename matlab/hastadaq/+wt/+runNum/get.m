function n = get()
% WT.RUNNUM.GET Current run number.
%   n = wt.runNum.get()
%
%   The run number is stored as a MATLAB preference (group "wt", name
%   "runNumber"), so it is per user and per MATLAB installation: it survives
%   restarts but is not shared between PCs. If it has never been set it is 1.
%   See wt.runNum.set and wt.runNum.increment.
    [group, name] = runNumPref();
    % NB: getpref(group, name, default) would CREATE the preference when it
    % is missing; a read must not write, so check for it first.
    n = 1;
    if ispref(group, name)
        n = getpref(group, name);
    end
    if ~isnumeric(n) || ~isscalar(n) || ~isfinite(n) || n < 0 || n ~= round(n)
        error("wt:runNum:badValue", ...
            "The stored run number (%s) is not a whole number >= 0. Fix it with wt.runNum.set(n).", ...
            string(n));
    end
    n = double(n);
end
