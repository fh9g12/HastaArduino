% servoFrequencyResponse.m (SBUS)
%
% SBUS mirror of ../pwm/servoFrequencyResponse.m -- runs the same
% 0.1-30Hz/60s chirp, but sweeps SBUS updateHz instead of PWM carrierHz
% (see ../sbus/servoUpdateRateSweep.m for why that's the closest
% equivalent parameter). Plots time history, FFT, and a Bode-style
% transfer-function estimate, all update rates overlaid per plot type.
%
% Needs firmware with MAX_SAMPLES raised to fit a 60s run at
% CHIRP_SAMPLE_HZ (12000 samples at the 200Hz default below) --
% SbusServoCalibration.ino inherits the same 15000-sample buffer as
% ServoCalibration.ino.

addpath(fullfile(fileparts(mfilename("fullpath")), "..", "common"));

boardIP = "192.168.68.107";  % <-- set to your board's actual IP
port = 5025;

UPDATE_HZS = [200 200];
chMin = 0;    % confirmed empirically: full 11-bit range gives the widest usable
chMax = 2047; % swing (128deg) -- see servoUpdateRateSweep.m. NEVER use 2048 (wraps to 0).

CHIRP_F0_HZ = 0.1;
CHIRP_F1_HZ = 30;
CHIRP_PERIOD_S = 70;
CHIRP_CENTER_DEG = 90;
CHIRP_AMPLITUDE_DEG = 30; % conservative -- tighten/widen once servoBacklashTest.m
                          % or servoCalibrationTest.m has established the real
                          % usable commanded-angle range
CHIRP_SAMPLE_HZ = 200;    % ~7x oversampling above the 30Hz top of the chirp

% Longest single blocking call is one CHIRP run (~2s settle + periodS), so
% the timeout needs comfortable margin above that.
t = connectServo(boardIP, port, CHIRP_PERIOD_S + 30);
enableServo(t);

chirpParams = struct("f0", CHIRP_F0_HZ, "f1", CHIRP_F1_HZ, "periodS", CHIRP_PERIOD_S, ...
                      "center", CHIRP_CENTER_DEG, "amplitude", CHIRP_AMPLITUDE_DEG, ...
                      "cycles", 1, "sampleHz", CHIRP_SAMPLE_HZ);

results = struct("label", {}, "t_ms", {}, "targetDeg", {}, "encoderDeg", {});

for i = 1:numel(UPDATE_HZS)
    updateHz = UPDATE_HZS(i);
    fprintf("Running %.1f-%.1fHz chirp over %ds at update rate %dHz...\n", ...
        CHIRP_F0_HZ, CHIRP_F1_HZ, CHIRP_PERIOD_S, updateHz);

    sendConfig(t, struct("chMin", chMin, "chMax", chMax, "broadcast", true, ...
                          "fast", updateHz<0, "updateHz", abs(updateHz)));

    writeline(t, "CHIRP");
    writeline(t, jsonencode(chirpParams));
    disp("  Chirp: " + strtrim(readline(t))); % "OK <n_samples>", after settle + periodS

    [t_ms, targetDeg, encoderDeg] = readServoData(t);

    results(i).label = sprintf("%d Hz", updateHz); %#ok<SAGROW>
    results(i).t_ms = t_ms;
    results(i).targetDeg = targetDeg;
    results(i).encoderDeg = encoderDeg;
end

clear t % close the TCP connection

plotTimeHistories(results, "SBUS update rate");
plotFftMagnitudes(results, "SBUS update rate");
plotBodePlots(results, "SBUS update rate");
