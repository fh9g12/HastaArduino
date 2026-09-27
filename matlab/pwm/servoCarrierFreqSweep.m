% servoCarrierFreqSweep.m (PWM)
%
% Compares the servo's commanded-vs-achieved angle range across several
% PWM carrier frequencies, to check whether the "good" ~100-400Hz band
% seen on the bench is a servo characteristic or a PWM duty-cycle
% resolution/saturation artifact. With pulseMaxUs=3000, the pulse stops
% fitting inside one PWM period once period_us < pulseMaxUs -- i.e. above
% ~1e6/3000 = 333Hz -- which lines up with the observed upper edge. A
% narrower pulse range should push that ceiling up if that's really what's
% going on; this script makes that quick to check by re-running with
% different pulseMinUs/pulseMaxUs below. See ../sbus/servoUpdateRateSweep.m
% for the SBUS analog (no PWM carrier concept there -- updateHz is the
% closest equivalent).
%
% Runs one full-range SWEEP per carrier frequency in FREQS_HZ (one TCP
% connection reused throughout), then plots the calibration curves
% overlaid plus achieved angular range vs frequency.

addpath(fullfile(fileparts(mfilename("fullpath")), "..", "common"));

boardIP = "192.168.68.112";  % <-- set to your board's actual IP
port = 5025;

FREQS_HZ = [50 100 250 400 500];
pulseMinUs = 850;  % current best-known-good pulse range from bench testing --
pulseMaxUs = 2200; % see servoCalibrationTest.m for how this was derived

sweepParams = struct("startDeg", 0, "endDeg", 180, "halfPeriodS", 5, ...
                      "cycles", 1, "sampleHz", 100);

% SWEEP blocks for settle (2s) + the run duration (halfPeriodS*2*cycles =
% 10s here), so the timeout has to comfortably exceed that per read.
t = connectServo(boardIP, port, 30);
enableServo(t);

results = struct("label", {}, "t_ms", {}, "targetDeg", {}, "encoderDeg", {});

for i = 1:numel(FREQS_HZ)
    freqHz = FREQS_HZ(i);
    fprintf("Running sweep at carrier %d Hz...\n", freqHz);

    sendConfig(t, struct("carrierHz", freqHz, "pulseMinUs", pulseMinUs, "pulseMaxUs", pulseMaxUs));

    writeline(t, "SWEEP");
    writeline(t, jsonencode(sweepParams));
    disp("  Sweep: " + strtrim(readline(t))); % "OK <n_samples>", after settle + run duration

    [t_ms, targetDeg, encoderDeg] = readServoData(t);

    results(i).label = sprintf("%d Hz", freqHz); %#ok<SAGROW>
    results(i).t_ms = t_ms;
    results(i).targetDeg = targetDeg;
    results(i).encoderDeg = encoderDeg;
end

clear t % close the TCP connection

% --- calibration curves overlaid, one colour per frequency ---
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
title(sprintf("Calibration curve vs carrier frequency (pulse range %d-%dus)", pulseMinUs, pulseMaxUs));
legend(legendEntries, "Location", "southeast");
axis equal;
grid on;

% --- achieved angular range (peak-to-peak) vs carrier frequency ---
subplot(2, 1, 2);
achievedRangeDeg = arrayfun(@(r) max(r.encoderDeg) - min(r.encoderDeg), results);
plot(FREQS_HZ, achievedRangeDeg, "-o");
xlabel("carrier frequency (Hz)"); ylabel("achieved range (deg, peak-to-peak)");
title("Achieved angular range vs carrier frequency");
grid on;
