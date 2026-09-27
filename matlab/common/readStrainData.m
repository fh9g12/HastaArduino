function [t_ms, bridgeMv, ratioMvPerV] = readStrainData(t)
% READSTRAINDATA Sends DATA? and parses the binary reply from
% StrainGaugeCalibration.ino. Same framing convention as readServoData.m
% (one ASCII header line "BIN <n> <bytesPerSample>", then the raw sample
% array as packed binary), but a single-channel payload --
% {uint32 t_us; float bridge_mV; float ratio_mV_per_V} per sample,
% little-endian.
    writeline(t, "DATA?");
    header = strtrim(readline(t)); % strtrim: println() sends CRLF, readline() only strips LF
    parsed = sscanf(header, "BIN %d %d");
    n = parsed(1);
    bytesPerSample = parsed(2);
    assert(bytesPerSample == 12, ...
        "Unexpected sample size (%d) from firmware -- this script's binary " + ...
        "layout (uint32 t_us; float bridge_mV; float ratio_mV_per_V) is out of sync.", ...
        bytesPerSample);

    raw = read(t, n * bytesPerSample, "uint8");
    raw = reshape(uint8(raw(:)), bytesPerSample, n); % column k = sample k's bytes

    t_us = typecast(reshape(raw(1:4, :), [], 1), "uint32");
    bridgeMv = double(typecast(reshape(raw(5:8, :), [], 1), "single"));
    ratioMvPerV = double(typecast(reshape(raw(9:12, :), [], 1), "single"));
    t_ms = double(t_us) / 1000;
end
