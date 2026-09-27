% servoCalibrationTest.m (SBUS)
%
% Quick bench check of the SbusServoCalibration SCPI interface (see
% SbusServoCalibration/SbusServoCalibration.ino) -- same idea as
% ../pwm/servoCalibrationTest.m, but with SBUS's own CONFIG fields
% (chMin/chMax/broadcast/channel/fast/updateHz -- no carrierHz, PWM-only).
% Connects over TCP, runs one SWEEP test, pulls back the captured (target
% vs encoder) time series via DATA?, and plots it.
%
% Get boardIP from the Serial Monitor at boot ("[WiFi] Connected, IP=...").
% This is a DIFFERENT physical board than ServoCalibration's PWM rig, so
% it'll have its own IP -- don't assume it's the same.

addpath(fullfile(fileparts(mfilename("fullpath")), "..", "common"));

boardIP = "192.168.68.107";  % <-- set to your board's actual IP
port = 5025;

% SWEEP blocks the connection for the run's full duration, so the
% tcpclient timeout has to comfortably exceed that (halfPeriodS*2*cycles
% below == 10s) or readline() on the "OK <n>" reply will error out.
t = connectServo(boardIP, port, 30);

% --- SBUS config -- broadcast:true (the firmware default) drives every
% channel identically, since the servo's bound channel isn't known yet.
% chMin/chMax = 0-2047 (the full 11-bit range) is confirmed empirically
% as this servo's real usable range (128deg) -- wider than the 172-1811
% "standard RC" convention (104deg). NEVER use 2048 as chMax: SBUS
% channels are 11-bit fields on the wire, so 2048 truncates to 0 and the
% servo snaps to zero instead of full-scale (confirmed on the bench).
% Sent explicitly here even though these match the firmware defaults, so
% this script stays correct if you change them. ---
sendConfig(t, struct("chMin", 0, "chMax", 2047, "broadcast", true, ...
                      "fast", false, "updateHz", 100));
enableServo(t);

% --- run a sweep: full 0-180deg range, 5s up + 5s down, 100 samples/sec ---
sweepParams = struct("startDeg", 0, "endDeg", 180, "halfPeriodS", 10, ...
                      "cycles", 1, "sampleHz", 50);
writeline(t, "SWEEP");
writeline(t, jsonencode(sweepParams));
disp("Sweep result: " + strtrim(readline(t)));  % "OK <n_samples>", after ~10s

[t_ms, targetDeg, encoderDeg] = readServoData(t);
clear t % close the TCP connection

figure;
subplot(2, 1, 1);
plot(t_ms, targetDeg, t_ms, encoderDeg);
xlabel("t (ms)"); ylabel("deg");
legend("target", "encoder"); title("SBUS sweep: target vs encoder over time");

subplot(2, 1, 2);
plot(targetDeg, encoderDeg, ".");
xlabel("commanded deg"); ylabel("encoder deg");
title("SBUS calibration curve: commanded vs actual angle");
axis equal;
