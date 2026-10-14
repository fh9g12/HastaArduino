function set(n)
% WT.RUNNUM.SET Set the run number.
%   wt.runNum.set(5)
    arguments
        n (1,1) double {mustBeInteger, mustBeNonnegative}
    end
    [group, name] = runNumPref();
    setpref(group, name, n);
end
