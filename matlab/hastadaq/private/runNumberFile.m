function path = runNumberFile()
% RUNNUMBERFILE Location of runNumber.txt: the matlab/hastadaq folder
% itself (not the current folder), so every script finds the same file.
    path = fullfile(fileparts(fileparts(mfilename("fullpath"))), "runNumber.txt");
end
