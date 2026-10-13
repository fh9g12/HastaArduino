function file = getLastZeroRun(dataDir)
% GETLASTZERORUN Path of the most recent zero run file (scripts.ZeroRun).
%   file = getLastZeroRun()            % looks in ./data
%   file = getLastZeroRun("somewhere") % looks in that folder
%
%   Returns "" if there isn't one. "Most recent" is by file date, so
%   deleting a bad zero run file makes the one before it current again.
%   Partial files (*_partial.mat) are ignored.
    arguments
        dataDir (1,1) string = "data"
    end
    file = "";
    if ~isfolder(dataDir)
        return
    end
    found = dir(fullfile(dataDir, "*_ZeroRun_*.mat"));
    found = found(~endsWith(string({found.name}), "_partial.mat"));
    if isempty(found)
        return
    end
    [~, newest] = max([found.datenum]);
    file = string(fullfile(found(newest).folder, found(newest).name));
end
