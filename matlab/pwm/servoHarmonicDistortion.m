% servoHarmonicDistortion.m (PWM)
%
% Checks how cleanly the servo excites at each of several fixed
% frequencies. For driving a wing/structure at a commanded frequency, what
% matters is spectral purity -- does the motion stay at f0, or does the
% servo distort the waveform (can't smoothly track the sine, so energy
% leaks into harmonics) -- and achieved amplitude, not control-loop
% bandwidth (gain/phase relative to a reference, see
% servoFrequencyResponse.m for that instead). See
% ../sbus/servoHarmonicDistortion.m for the SBUS mirror.
%
% Runs a fixed-frequency SINE (not CHIRP -- a chirp never settles into
% steady periodic motion at one frequency, so THD from chirp data isn't
% meaningful) at each frequency in TEST_FREQS_HZ, for an exact integer
% number of cycles -- that puts the fundamental and every harmonic exactly
% on an FFT bin (bin index = harmonic number * cycles), so THD comes out
% leakage-free with no windowing needed. For each frequency, finds the
% ACTUAL fundamental peak (not just trusting the commanded frequency --
% see analyseHarmonics.m) and computes:
%   - measured vs commanded frequency -- is the output actually
%     oscillating at the frequency you asked for?
%   - THD%: sqrt(sum of harmonic amplitudes^2) / fundamental amplitude,
%     harmonics 2..NUM_HARMONICS
%   - achieved/commanded amplitude ratio at the fundamental
% and plots all three vs commanded frequency.

addpath(fullfile(fileparts(mfilename("fullpath")), "..", "common"));

boardIP = "192.168.68.112";  % <-- set to your board's actual IP
port = 5025;

TEST_FREQS_HZ = 1:2:19;
pulseMinUs = 850;
pulseMaxUs = 2200;
carrierHz = 400; % one fixed carrier -- this is about excitation purity, not
                 % comparing carriers (see servoFrequencyResponse.m for that)

SINE_CENTER_DEG = 90;
SINE_AMPLITUDE_DEG = 20; % conservative -- tighten/widen once the backlash/
                         % setpoint test has established the real usable range
SINE_CYCLES = 10;        % integer -- keeps fundamental+harmonics exactly on FFT bins
SINE_SAMPLE_HZ = 200;
NUM_HARMONICS = 5;       % THD computed over the 2nd..NUM_HARMONICS-th harmonic

% Longest single blocking call is one SINE run (~2s settle + cycles/freqHz);
% worst case here is 1Hz * 10 cycles = 10s -- comfortable margin below 30s.
t = connectServo(boardIP, port, 30);
sendConfig(t, struct("carrierHz", carrierHz, "pulseMinUs", pulseMinUs, "pulseMaxUs", pulseMaxUs));
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
title(sprintf("Measured vs commanded frequency (%dHz carrier, %d-%dus pulse)", ...
    carrierHz, pulseMinUs, pulseMaxUs));
grid on;

subplot(3, 1, 2);
plot(TEST_FREQS_HZ, thdPercent, "-o");
xlabel("commanded frequency (Hz)"); ylabel("THD (%)");
title("Harmonic distortion vs frequency");
grid on;

subplot(3, 1, 3);
plot(TEST_FREQS_HZ, 100 * amplitudeRatio, "-o");
xlabel("commanded frequency (Hz)"); ylabel("achieved / commanded amplitude (%)");
title("Achieved amplitude vs frequency");
grid on;
