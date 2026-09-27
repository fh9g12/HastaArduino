% servoHarmonicDistortion.m (SBUS)
%
% SBUS mirror of ../pwm/servoHarmonicDistortion.m -- same procedure
% (fixed-frequency SINE at each of several frequencies, THD + achieved
% amplitude + measured-vs-commanded frequency), just SBUS's own CONFIG
% fields and a fixed update rate instead of a fixed carrier.

addpath(fullfile(fileparts(mfilename("fullpath")), "..", "common"));

boardIP = "192.168.1.50";  % <-- set to your board's actual IP
port = 5025;

TEST_FREQS_HZ = 1:2:19;
chMin = 0;    % confirmed empirically: full 11-bit range gives the widest usable
chMax = 2047; % swing (128deg) -- see servoUpdateRateSweep.m. NEVER use 2048 (wraps to 0).
updateHz = 100; % one fixed update rate -- this is about excitation purity, not
                % comparing rates (see servoFrequencyResponse.m for that)

SINE_CENTER_DEG = 90;
SINE_AMPLITUDE_DEG = 20; % conservative -- tighten/widen once the backlash/
                         % setpoint test has established the real usable range
SINE_CYCLES = 10;        % integer -- keeps fundamental+harmonics exactly on FFT bins
SINE_SAMPLE_HZ = 200;
NUM_HARMONICS = 5;       % THD computed over the 2nd..NUM_HARMONICS-th harmonic

% Longest single blocking call is one SINE run (~2s settle + cycles/freqHz);
% worst case here is 1Hz * 10 cycles = 10s -- comfortable margin below 30s.
t = connectServo(boardIP, port, 30);
sendConfig(t, struct("chMin", chMin, "chMax", chMax, "broadcast", true, ...
                      "fast", false, "updateHz", updateHz));
enableServo(t);

thdPercent = zeros(size(TEST_FREQS_HZ));
amplitudeRatio = zeros(size(TEST_FREQS_HZ));
measuredFreqHz = zeros(size(TEST_FREQS_HZ));

for i = 1:numel(TEST_FREQS_HZ)
    freqHz = TEST_FREQS_HZ(i);
    fprintf("Running %gHz sine (%d cycles)...\n", freqHz, SINE_CYCLES);

    sineParams = struct("freqHz", freqHz, "center", SINE_CENTER_DEG, ...
                         "amplitude", SINE_AMPLITUDE_DEG, "cycles", SINE_CYCLES, ...
                         "sampleHz", SINE_SAMPLE_HZ);
    writeline(t, "SINE");
    writeline(t, jsonencode(sineParams));
    disp("  Sine: " + strtrim(readline(t))); % "OK <n_samples>", after settle + run duration

    [t_ms, ~, encoderDeg] = readServoData(t);
    [thdPercent(i), amplitudeRatio(i), measuredFreqHz(i)] = analyseHarmonics(t_ms, encoderDeg, ...
        SINE_CYCLES, SINE_AMPLITUDE_DEG, NUM_HARMONICS);
end

clear t % close the TCP connection

figure;
subplot(3, 1, 1);
plot(TEST_FREQS_HZ, TEST_FREQS_HZ, "k--", TEST_FREQS_HZ, measuredFreqHz, "-o");
xlabel("commanded frequency (Hz)"); ylabel("measured frequency (Hz)");
legend("commanded (reference)", "measured", "Location", "best");
title(sprintf("SBUS: measured vs commanded frequency (%dHz update, %d-%d channel range)", ...
    updateHz, chMin, chMax));
grid on;

subplot(3, 1, 2);
plot(TEST_FREQS_HZ, thdPercent, "-o");
xlabel("commanded frequency (Hz)"); ylabel("THD (%)");
title("SBUS: harmonic distortion vs frequency");
grid on;

subplot(3, 1, 3);
plot(TEST_FREQS_HZ, 100 * amplitudeRatio, "-o");
xlabel("commanded frequency (Hz)"); ylabel("achieved / commanded amplitude (%)");
title("SBUS: achieved amplitude vs frequency");
grid on;
