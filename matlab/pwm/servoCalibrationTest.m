% servoCalibrationTest.m (PWM)
%
% Quick bench check of the ServoCalibration SCPI interface (see
% ServoCalibration/ServoCalibration.ino): connects over TCP, runs one
% SWEEP test, pulls back the captured (target vs encoder) time series via
% DATA?, and plots it. Needs no toolbox beyond base MATLAB -- tcpclient
% has been built in since R2019a. See ../sbus/servoCalibrationTest.m for
% the SBUS-driven mirror of this same check.
%
% Get boardIP from the Serial Monitor at boot ("[WiFi] Connected, IP=...").

addpath(fullfile(fileparts(mfilename("fullpath")), "..", "common"));

boardIP = "192.168.68.112";  % <-- set to your board's actual IP
port = 5025;

% SWEEP blocks the connection for the run's full duration, so the
% tcpclient timeout has to comfortably exceed that (halfPeriodS*2*cycles
% below == 10s) or readline() on the "OK <n>" reply will error out.
t = connectServo(boardIP, port, 30);

% --- carrier frequency + pulse-width range -- the three values this rig
% exists to help you find empirically. Current best-known-good combo from
% bench testing: 100-3000us over-drove past the servo's real endstops
% (full ~140deg swing but only across ~45-130 commanded deg) and clipped
% above ~333Hz (1e6/3000); 1000-2000us under-drove (only ~100deg of the
% servo's real range) but was frequency-clean up to 500Hz. 800-2200us
% splits the difference (linear extrapolation from the 1000-2000 result
% toward the full ~140deg), with 400Hz carrier keeping comfortable margin
% below the new ~454Hz (1e6/2200) clipping ceiling. Re-verify empirically
% -- this assumes the servo's response is roughly linear across the
% range, which is exactly what this rig exists to check, not assume.
sendConfig(t, struct("carrierHz", 400, "pulseMinUs", 800, "pulseMaxUs", 2200));
enableServo(t);

% --- run a sweep: full 0-180deg range, 5s up + 5s down, 100 samples/sec ---
sweepParams = struct("startDeg", 0, "endDeg", 180, "halfPeriodS", 5, ...
                      "cycles", 1, "sampleHz", 100);
writeline(t, "SWEEP");
writeline(t, jsonencode(sweepParams));
disp("Sweep result: " + strtrim(readline(t)));  % "OK <n_samples>", after ~10s

[t_ms, targetDeg, encoderDeg] = readServoData(t);
clear t % close the TCP connection

figure;
subplot(2, 1, 1);
plot(t_ms, targetDeg, t_ms, encoderDeg);
xlabel("t (ms)"); ylabel("deg");
legend("target", "encoder"); title("Sweep: target vs encoder over time");

subplot(2, 1, 2);
plot(targetDeg, encoderDeg, ".");
xlabel("commanded deg"); ylabel("encoder deg");
title("Calibration curve: commanded vs actual angle");
axis equal;
