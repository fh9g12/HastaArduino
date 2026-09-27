% strainGaugeTest.m
%
% Bench check for the StrainGaugeCalibration rig: runs a 10s capture at
% the ADS122C04's native 180SPS (turbo mode, DR=90SPS setting -- see
% StrainGaugeCalibration.ino/StrainGaugeBringup.ino for why that's the
% closest available rate to 200Hz, and why it's not independently
% configurable per run), then plots the bridge reading over time.
%
% Get boardIP from the Serial Monitor at boot ("[WiFi] Connected, IP=...").

addpath(fullfile(fileparts(mfilename("fullpath")), "..", "common"));

boardIP = "192.168.68.107";  % <-- set to your board's actual IP
port = 5025;

DURATION_S = 10;

% RUN blocks the connection for the full run duration, so the tcpclient
% timeout has to comfortably exceed that.
t = tcpclient(boardIP, port, "Timeout", DURATION_S + 15);
configureTerminator(t, "LF");

writeline(t, "*IDN?");
disp("IDN: " + readline(t));

runParams = struct("durationS", DURATION_S);
writeline(t, "RUN");
writeline(t, jsonencode(runParams));
disp("Run result: " + strtrim(readline(t)));  % "OK <n_samples>", after ~10s

[t_ms, bridgeMv, ratioMvPerV] = readStrainData(t);
clear t % close the TCP connection

actualSampleHz = (numel(t_ms) - 1) / ((t_ms(end) - t_ms(1)) / 1000);
fprintf("Captured %d samples over %.2fs (%.1f SPS actual).\n", ...
    numel(t_ms), (t_ms(end) - t_ms(1)) / 1000, actualSampleHz);
fprintf("Bridge: mean %.4f mV, peak-to-peak %.4f mV, std %.5f mV\n", ...
    mean(bridgeMv), max(bridgeMv) - min(bridgeMv), std(bridgeMv));

figure("Name", "Strain gauge test");

subplot(2, 1, 1);
plot(t_ms / 1000, bridgeMv);
xlabel("t (s)"); ylabel("bridge output (mV)");
title(sprintf("Bridge output over %ds (%.1f SPS actual)", DURATION_S, actualSampleHz));
grid on;

subplot(2, 1, 2);
plot(t_ms / 1000, ratioMvPerV);
xlabel("t (s)"); ylabel("ratio (mV/V of excitation)");
title("Bridge output as a ratio of excitation (industry-standard load-cell units)");
grid on;
