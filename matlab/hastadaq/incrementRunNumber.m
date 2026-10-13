function n = incrementRunNumber()
% INCREMENTRUNNUMBER Move to the next run (wind turned off and on again).
%   n = incrementRunNumber()   % saves and returns the new run number
%
%   Do this by hand, once per wind-on/wind-off - scripts don't call it, so
%   running a script several times in one run keeps the same run number.
    n = getRunNumber() + 1;
    writelines(string(n), runNumberFile());
end
