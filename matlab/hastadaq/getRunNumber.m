function n = getRunNumber()
% GETRUNNUMBER Current run number, read from runNumber.txt.
%   n = getRunNumber()
%
%   The run number goes up once each time the wind is turned on and off
%   (see incrementRunNumber). The file lives in the matlab/hastadaq folder
%   and holds a single whole number. If it doesn't exist yet it is created
%   with the value 1.
    file = runNumberFile();
    if ~isfile(file)
        writelines("1", file);
    end
    n = str2double(strtrim(readlines(file)));
    n = n(~isnan(n));
    if isempty(n) || ~isscalar(n) || n < 0 || n ~= round(n)
        error("getRunNumber:badFile", ...
            "%s should contain a single whole number (e.g. 1).", file);
    end
end
