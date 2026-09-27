% servoUpdateRateSweep.m (SBUS)
%
% SBUS analog of ../pwm/servoCarrierFreqSweep.m -- there's no PWM carrier
% concept over SBUS (the frame IS the signal, there's no separate
% continuous waveform underneath it), so the closest equivalent parameter
% is updateHz: how often a fresh SBUS frame is actually sent. Too slow and
% a moving SWEEP target could out-run the update rate (visible as reduced
% achieved range or a lagged/steppy calibration curve, similar in spirit
% to PWM's duty-cycle resolution loss at high carrier -- different
% mechanism, same kind of symptom); too fast doesn't cost anything on this
% CPU (see the earlier chat note: PWM carrier has no MCU-load effect since
% it's hardware-generated, and neither does a faster SBUS updateHz within
% reason, since retransmit() is just a cheap UART FIFO write).
%
% Runs one full-range SWEEP per update rate in UPDATE_HZS (one TCP
% connection reused throughout), then plots the calibration curves
% overlaid plus achieved angular range vs update rate.

addpath(fullfile(fileparts(mfilename("fullpath")), "..", "common"));

boardIP = "192.168.68.107";  % <-- set to your board's actual IP
port = 5025;

UPDATE_HZS = [200];
chMin = 0;
chMax = 2047;

sweepParams = struct("startDeg", 0, "endDeg", 180, "halfPeriodS", 5, ...
                      "cycles", 1, "sampleHz", 100);

% SWEEP blocks for settle (2s) + the run duration (halfPeriodS*2*cycles =
% 10s here), so the timeout has to comfortably exceed that per read.
t = connectServo(boardIP, port, 30);
enableServo(t);

results = struct("label", {}, "t_ms", {}, "targetDeg", {}, "encoderDeg", {});

for i = 1:numel(UPDATE_HZS)
    updateHz = UPDATE_HZS(i);
    fprintf("Running sweep at update rate %d Hz...\n", updateHz);

    sendConfig(t, struct("chMin", chMin, "chMax", chMax, "broadcast", true, ...
                          "fast", false, "updateHz", updateHz));

    writeline(t, "SWEEP");
    writeline(t, jsonencode(sweepParams));
    disp("  Sweep: " + strtrim(readline(t))); % "OK <n_samples>", after settle + run duration

    [t_ms, targetDeg, encoderDeg] = readServoData(t);

    results(i).label = sprintf("%d Hz", updateHz); %#ok<SAGROW>
    results(i).t_ms = t_ms;
    results(i).targetDeg = targetDeg;
    results(i).encoderDeg = encoderDeg;
end

clear t % close the TCP connection

% --- calibration curves overlaid, one colour per update rate ---
figure;
subplot(2, 1, 1);
hold on;
colors = lines(numel(results));
legendEntries = strings(1, numel(results));
for i = 1:numel(results)
    plot(results(i).targetDeg, results(i).encoderDeg, ".", "Color", colors(i, :));
    legendEntries(i) = results(i).label;
end
hold off;
xlabel("commanded deg"); ylabel("encoder deg");
title(sprintf("Calibration curve vs SBUS update rate (channel range %d-%d)", chMin, chMax));
legend(legendEntries, "Location", "southeast");
axis equal;
grid on;

% --- achieved angular range (peak-to-peak) vs update rate ---
subplot(2, 1, 2);
achievedRangeDeg = arrayfun(@(r) max(r.encoderDeg) - min(r.encoderDeg), results);
plot(UPDATE_HZS, achievedRangeDeg, "-o");
xlabel("SBUS update rate (Hz)"); ylabel("achieved range (deg, peak-to-peak)");
title("Achieved angular range vs SBUS update rate");
grid on;
