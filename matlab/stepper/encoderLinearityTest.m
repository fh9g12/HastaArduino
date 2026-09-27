% encoderLinearityTest.m
%
% Characterises MT6835 linearity using the stepper as a mechanical
% reference: spin at a slow constant speed for several revolutions via
% RUN, then look at encoderDeg relative to a best-fit line through
% targetDeg (removes any constant scale error -- e.g. if the real
% degPerStep isn't exactly nominal).
%
% That global fit still leaves each revolution's residual curve sitting
% at a different vertical offset from the others, because the stepper's
% own per-step error accumulates slightly differently each revolution
% (it doesn't necessarily land back on an exact multiple of 360deg) --
% that's stepper imprecision, not encoder nonlinearity. So each
% revolution is additionally re-referenced to ITS OWN first sample
% (assume the encoder reading at the start of each cycle is correct,
% whatever the stepper's cumulative error did to get there), isolating
% the within-cycle shape -- which is what "linearity" actually means --
% from cycle-to-cycle stepper drift. Bottom plot below is this
% per-revolution-zeroed version; top plot keeps the raw (non-zeroed)
% residual over time so cycle-to-cycle drift is still visible if you
% want to eyeball how much of it there is.
%
% Caveat on reference quality: full NEMA17 steps are typically accurate
% to ~5% of a step (~0.09deg for this 1.8deg motor), fine for spotting
% gross nonlinearity/ripple but not tight enough to independently verify
% MT6835's own post-User-Auto-Calibration ±0.07deg INL spec -- treat this
% as "does the encoder look sane and repeatable", not a metrology-grade
% INL measurement. Also note the stepper is currently jumpered for 1/8
% microstep (see EncoderCalibration.ino / wiring diagram) -- microstep
% positions carry more inherent error than full steps, so some of the
% within-cycle shape seen here can still be the stepper's own
% microstepping error, not necessarily the encoder's.
%
% Get boardIP from the Serial Monitor at boot ("[WiFi] Connected, IP=...").

addpath(fullfile(fileparts(mfilename("fullpath")), "..", "common"));

boardIP = "192.168.68.107";  % <-- set to your board's actual IP
port = 5025;

SPEED_DEG_PER_S = 30; % slow -- 12s/rev, minimises dynamic lag between
                       % commanded step and settled encoder reading
NUM_REVS = 5;
SAMPLE_HZ = 50;

durationS = NUM_REVS * 360 / SPEED_DEG_PER_S;

t = connectServo(boardIP, port, max(30, durationS + 15));

runParams = struct("speedDegPerS", SPEED_DEG_PER_S, "durationS", durationS, "sampleHz", SAMPLE_HZ);
writeline(t, "RUN");
writeline(t, jsonencode(runParams));
disp("Run result: " + strtrim(readline(t)));  % "OK <n_samples>"

[t_ms, targetDeg, encoderDeg] = readServoData(t);
clear t % close the TCP connection

% --- linear fit removes constant scale error, leaving nonlinearity + drift ---
p = polyfit(targetDeg, encoderDeg, 1);
fitDeg = polyval(p, targetDeg);
residualDeg = encoderDeg - fitDeg;

% revIndex counts laps SINCE THIS RUN STARTED, not from an absolute
% multiple of 360 -- StepperDriver's step count carries over between
% RUN calls (no reset between runs), so targetDeg(1) is whatever was
% left over from any earlier run, not necessarily near 0.
revIndex = floor((targetDeg - targetDeg(1)) / 360);
wrappedDeg = mod(targetDeg, 360);

% --- resample each full lap onto a common angle grid, then zero every
% lap at EXACTLY wrappedDeg=0 -- isolates within-cycle shape from
% cycle-to-cycle stepper drift, and makes laps actually comparable
% point-by-point (not just visually close), unlike zeroing each lap at
% "whatever sample happened to come first", which lands at a different
% angle each lap since RUN samples on a fixed time interval, not synced
% to lap boundaries. First and last laps are dropped -- they're partial
% (this run started/stopped mid-lap relative to the stepper's carried-
% over position from any earlier run), so they don't span the full grid.
revs = unique(revIndex)';
fullLaps = revs;
if numel(revs) >= 3
    fullLaps = revs(2:end - 1);
else
    warning("Fewer than 3 laps captured -- can't drop partial first/last lap, using all of them.");
end

angleGrid = (0:1:360)';
cycleResidualGrid = nan(numel(angleGrid), numel(fullLaps));
for i = 1:numel(fullLaps)
    mask = revIndex == fullLaps(i);
    interpResidual = interp1(wrappedDeg(mask), residualDeg(mask), angleGrid, "linear", "extrap");
    cycleResidualGrid(:, i) = interpResidual - interpResidual(1); % zero at angleGrid=0
end

peakToPeakDeg = max(cycleResidualGrid(:)) - min(cycleResidualGrid(:));
rmsDeg = sqrt(mean(cycleResidualGrid(:) .^ 2));

fprintf("Fit: encoderDeg = %.5f * targetDeg + %.4f (ideal slope=1.0)\n", p(1), p(2));
fprintf("Within-cycle residual (per-revolution zeroed): peak-to-peak %.4f deg, RMS %.4f deg\n", peakToPeakDeg, rmsDeg);
fprintf("(Datasheet reference: factory-cal INL typ +/-0.5deg max +/-1.0deg; " + ...
    "post-User-Auto-Cal typ +/-0.07deg -- this rig's stepper reference isn't " + ...
    "precise enough to confirm the auto-cal figure, but a peak-to-peak well " + ...
    "above +/-0.5deg would suggest a real problem, not just measurement noise.)\n");

figure("Name", "Encoder linearity");

subplot(2, 1, 1);
plot(t_ms / 1000, residualDeg);
xlabel("t (s)"); ylabel("residual (deg)");
title("Raw residual (encoder - linear fit) over time -- includes stepper cycle-to-cycle drift");
grid on;

subplot(2, 1, 2);
plot(angleGrid, cycleResidualGrid);
xlabel("commanded angle within revolution (deg)"); ylabel("residual (deg), zeroed at 0deg");
title("Per-revolution nonlinearity (resampled onto a common grid, each zeroed at 0deg -- repeatable pattern = real encoder nonlinearity)");
legend(compose("lap %d", 1:numel(fullLaps)), "Location", "best");
grid on;
