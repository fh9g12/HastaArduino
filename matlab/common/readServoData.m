function [t_ms, targetDeg, encoderDeg] = readServoData(t)
% READSERVODATA Sends DATA? and parses the binary reply. Wire format is
% identical on PWM and SBUS boards: one ASCII header line
% "BIN <n> <bytesPerSample>", then the raw sample array as packed binary
% -- {uint32 t_us; float target_deg; float encoder_deg} per sample,
% little-endian (native RP2040/PC byte order, no byte-swap needed).
    writeline(t, "DATA?");
    header = strtrim(readline(t)); % strtrim: println() sends CRLF, readline() only strips LF
    parsed = sscanf(header, "BIN %d %d");
    n = parsed(1);
    bytesPerSample = parsed(2);
    assert(bytesPerSample == 12, ...
        "Unexpected sample size (%d) from firmware -- this script's binary " + ...
        "layout (uint32 t_us; float target_deg; float encoder_deg) is out of sync.", ...
        bytesPerSample);

    raw = read(t, n * bytesPerSample, "uint8");
    raw = reshape(uint8(raw(:)), bytesPerSample, n); % column k = sample k's bytes

    t_us = typecast(reshape(raw(1:4, :), [], 1), "uint32");
    targetDeg = double(typecast(reshape(raw(5:8, :), [], 1), "single"));
    encoderDeg = double(typecast(reshape(raw(9:12, :), [], 1), "single"));
    t_ms = double(t_us) / 1000;
end
