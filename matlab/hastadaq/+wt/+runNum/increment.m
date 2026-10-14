function n = increment()
% WT.RUNNUM.INCREMENT Move to the next run: saves current+1 and returns it.
%   n = wt.runNum.increment()
%
%   Every call changes the saved value. The scripts that record data
%   (ZeroRun, the sweeps, the FreePitch* tests) call it when they start, so each of
%   their runs gets its own number; use wt.runNum.get() to read the current
%   one without changing it, or wt.runNum.set(n) to correct it.
    n = wt.runNum.get() + 1;
    wt.runNum.set(n);
end
