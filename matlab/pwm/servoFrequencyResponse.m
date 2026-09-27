% servoFrequencyResponse.m (PWM)
%
% Frequency-response check: runs a 0.1-30Hz chirp over 60s at each of
% several PWM carrier frequencies, and plots time history, FFT, and a
% Bode-style transfer-function estimate -- all carrier frequencies
% overlaid on the same axes per plot type, so they're directly comparable.
% See ../sbus/servoFrequencyResponse.m for the SBUS mirror (sweeps
% updateHz instead of carrierHz -- no PWM carrier concept over SBUS).
%
% Needs firmware with MAX_SAMPLES raised to fit a 60s run at
% CHIRP_SAMPLE_HZ (12000 samples at the 200Hz default below) --
% ServoCalibration.ino was bumped from 4000 to 15000 samples for exactly
% this. Reflash first if you're still on the old firmware, or DATA? will
% silently hand back a run truncated to ~20s -- only the low-frequency
% start of the chirp, with the whole point (response up near 30Hz) missing
% and no error to tell you so.

addpath(fullfile(fileparts(mfilename("fullpath")), "..", "common"));

boardIP = "192.168.68.112";  % <-- set to your board's actual IP
port = 5025;

CARRIER_FREQS_HZ = [100 200 300 400];
pulseMinUs = 850;
pulseMaxUs = 2200;

CHIRP_F0_HZ = 0.1;
CHIRP_F1_HZ = 30;
CHIRP_PERIOD_S = 60;
CHIRP_CENTER_DEG = 90;
CHIRP_AMPLITUDE_DEG = 30; % conservative -- tighten/widen once servoBacklashTest.m
                          % or servoCalibrationTest.m has established the real
                          % usable commanded-angle range for pulseMinUs/pulseMaxUs above
CHIRP_SAMPLE_HZ = 200;    % ~7x oversampling above the 30Hz top of the chirp

% Longest single blocking call is one CHIRP run (~2s settle + periodS), so
% the timeout needs comfortable margin above that.
t = connectServo(boardIP, port, CHIRP_PERIOD_S + 30);
enableServo(t);

chirpParams = struct("f0", CHIRP_F0_HZ, "f1", CHIRP_F1_HZ, "periodS", CHIRP_PERIOD_S, ...
                      "center", CHIRP_CENTER_DEG, "amplitude", CHIRP_AMPLITUDE_DEG, ...
                      "cycles", 1, "sampleHz", CHIRP_SAMPLE_HZ);

results = struct("label", {}, "t_ms", {}, "targetDeg", {}, "encoderDeg", {});

for i = 1:numel(CARRIER_FREQS_HZ)
    carrierHz = CARRIER_FREQS_HZ(i);
    fprintf("Running %.1f-%.1fHz chirp over %ds at carrier %dHz...\n", ...
        CHIRP_F0_HZ, CHIRP_F1_HZ, CHIRP_PERIOD_S, carrierHz);

    sendConfig(t, struct("carrierHz", carrierHz, "pulseMinUs", pulseMinUs, "pulseMaxUs", pulseMaxUs));

    writeline(t, "CHIRP");
    writeline(t, jsonencode(chirpParams));
    disp("  Chirp: " + strtrim(readline(t))); % "OK <n_samples>", after settle + periodS

    [t_ms, targetDeg, encoderDeg] = readServoData(t);

    results(i).label = sprintf("%d Hz", carrierHz); %#ok<SAGROW>
    results(i).t_ms = t_ms;
    results(i).targetDeg = targetDeg;
    results(i).encoderDeg = encoderDeg;
end

clear t % close the TCP connection

plotTimeHistories(results, "carrier frequency");
plotFftMagnitudes(results, "carrier frequency");
plotBodePlots(results, "carrier frequency");
