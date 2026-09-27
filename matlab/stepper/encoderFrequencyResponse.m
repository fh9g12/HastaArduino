% encoderFrequencyResponse.m
%
% Frequency-response check for the MT6835 encoder: commands a 0.1-10Hz
% position CHIRP on the stepper (real direction reversals throughout, not
% just one-way constant speed like encoderLinearityTest.m/RUN) and plots
% time history, FFT, and a Bode-style transfer-function estimate -- same
% pattern as ../pwm/servoFrequencyResponse.m and ../sbus/servoFrequencyResponse.m.
%
% Chicken-and-egg caveat: target logged is the IDEAL commanded chirp
% trajectory (see EncoderCalibration.ino's RunChirp), not the stepper's
% own realised position, so this measures the COMBINED stepper+encoder
% response, not the encoder in isolation -- there's no independent
% higher-bandwidth reference on this rig to separate the two. Top end is
% set to 10Hz on the assumption the NEMA17+A4988 can still keep up with a
% 90deg-amplitude sine that fast (unconfirmed above that -- if gain rolls
% off, encoderLinearityTest.m's within-cycle-shape plot at a slow constant
% speed is the way to check whether that rolloff is really the encoder or
% just the stepper running out of torque/speed).
%
% Get boardIP from the Serial Monitor at boot ("[WiFi] Connected, IP=...").

addpath(fullfile(fileparts(mfilename("fullpath")), "..", "common"));

boardIP = "192.168.68.107";  % <-- set to your board's actual IP
port = 5025;

CHIRP_F0_HZ = 0.1;
CHIRP_F1_HZ = 10;
CHIRP_PERIOD_S = 60;
CHIRP_AMPLITUDE_DEG = 90; % conservative -- well short of stalling territory at low
                          % frequency; encoderLinearityTest.m's per-rev shape plot
                          % is the tool for finding the stepper's real speed limit
CHIRP_SAMPLE_HZ = 200;    % 20x oversampling above the 10Hz top of the chirp

% Longest single blocking call is one CHIRP run (~seek time + periodS), so
% the timeout needs comfortable margin above that.
t = connectServo(boardIP, port, CHIRP_PERIOD_S + 30);

% "center" omitted -> firmware defaults to the stepper's current position
% (see RunChirp in EncoderCalibration.ino), avoiding an unnecessary seek.
chirpParams = struct("f0", CHIRP_F0_HZ, "f1", CHIRP_F1_HZ, "periodS", CHIRP_PERIOD_S, ...
                      "amplitude", CHIRP_AMPLITUDE_DEG, "cycles", 1, "sampleHz", CHIRP_SAMPLE_HZ);

fprintf("Running %.1f-%.1fHz chirp over %ds...\n", CHIRP_F0_HZ, CHIRP_F1_HZ, CHIRP_PERIOD_S);
writeline(t, "CHIRP");
writeline(t, jsonencode(chirpParams));
disp("Chirp result: " + strtrim(readline(t))); % "OK <n_samples>", after seek + periodS

[t_ms, targetDeg, encoderDeg] = readServoData(t);
clear t % close the TCP connection

results = struct("label", {"stepper+encoder"}, "t_ms", {t_ms}, ...
    "targetDeg", {targetDeg}, "encoderDeg", {encoderDeg});

plotTimeHistories(results, "test");
plotFftMagnitudes(results, "test");
plotBodePlots(results, "test");
