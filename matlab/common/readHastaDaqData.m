function data = readHastaDaqData(t)
% READHASTADAQDATA Sends DATA? and parses the binary reply from
% HastaDAQ.ino. Same framing convention as readServoData.m/readStrainData.m
% (one ASCII header line "BIN <n> <bytesPerSample>", then the raw sample
% array as packed binary), but a much wider per-sample struct (see
% CaptureManager.h's HastaDaqSample):
%   {uint32 t_us; float adc1_mV; float adc2_mV; float encoder_deg;
%    float accel_x,y,z; float gyro_x,y,z; float excitation_deg;
%    float control_output_deg; float servo_deg[NUM_CHANNELS]}
%
% Returns a single struct (not a long list of output args, given how many
% fields this rig has) with fields:
%   t_ms, adc1Mv, adc2Mv, encoderDeg  -- Nx1 each
%   accel, gyro                       -- Nx3 each (columns x,y,z)
%   excitationDeg, controlOutputDeg   -- Nx1 each
%   servoDeg                          -- NxNUM_CHANNELS
%
% NUM_CHANNELS is inferred from the reported bytesPerSample (48 fixed
% bytes + 4*NUM_CHANNELS), so this doesn't need updating if
% ChannelMixer.h's CHANNEL_DEFS ever gains/loses a channel.
    writeline(t, "DATA?");
    header = strtrim(readline(t)); % strtrim: println() sends CRLF, readline() only strips LF
    parsed = sscanf(header, "BIN %d %d");
    n = parsed(1);
    bytesPerSample = parsed(2);

    numChannels = (bytesPerSample - 48) / 4;
    assert(numChannels == round(numChannels) && numChannels > 0, ...
        "Unexpected sample size (%d) from firmware -- doesn't match the " + ...
        "48-fixed-bytes-plus-4-per-channel HastaDaqSample layout.", bytesPerSample);

    raw = read(t, n * bytesPerSample, "uint8");
    raw = reshape(uint8(raw(:)), bytesPerSample, n); % column k = sample k's bytes

    field = @(byteStart, count) double(typecast(reshape(raw(byteStart:byteStart + 4 * count - 1, :), [], 1), "single"));

    t_us = typecast(reshape(raw(1:4, :), [], 1), "uint32");
    data.t_ms = double(t_us) / 1000;
    data.adc1Mv = field(5, 1);
    data.adc2Mv = field(9, 1);
    data.encoderDeg = field(13, 1);
    data.accel = reshape(field(17, 3), 3, n)';
    data.gyro = reshape(field(29, 3), 3, n)';
    data.excitationDeg = field(41, 1);
    data.controlOutputDeg = field(45, 1);
    data.servoDeg = reshape(field(49, numChannels), numChannels, n)';
end
