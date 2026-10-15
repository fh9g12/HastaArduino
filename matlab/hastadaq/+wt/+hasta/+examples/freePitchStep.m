% freePitchStep.m
%
% Free-to-pitch STEP RESPONSE: how does the aircraft respond when the
% elevators step from the angles that hold it DELTA_PITCH_DEG away from its
% target back to the angles that hold the target? On the Hasta DAQ alone (no
% tunnel computer, nothing saved):
%   1. the controller holds the model at the target pitch; a short capture
%      gives the elevator angles that hold it
%   2. the controller moves the model DELTA_PITCH_DEG away and holds it there;
%      a short capture gives the elevator angles that hold THAT
%   3. the controller is switched off WITHOUT a jolt (the elevators stay at
%      the displaced angles) and a "step" is ARMED on the board: PRE_STEP_S
%      after the capture is triggered the elevators step to the target's
%      angles. The step is timed on the board, with no command from MATLAB,
%      and the response is recorded for POST_STEP_S after it
%   4. the controller is switched back on to hold the model
% then the response is measured (time to 63% of the change, overshoot, 5%
% settling time) and plotted.
%
% While recording, the encoder is polled and, if the model strays more than
% |DELTA_PITCH_DEG| + OVERSHOOT_ALLOWANCE_DEG from the target (an unstable or
% lightly damped model), the controller is switched straight back on.
%
% Run scripts.ZeroEncoderRun once first: the pitch target is an angle on the
% encoder, so the encoder's zero must be the model's real zero. The tunnel
% version of this, which saves data, is scripts.FreePitchStep.
%
% THIS MOVES THE ELEVATORS AND THE MODEL, WHICH IS FREE TO PITCH. Make sure
% the area is clear and the tunnel conditions are what you intend. Start with
% a small DELTA_PITCH_DEG and gentle controller gains. If the model runs away
% from the target instead of settling, the controller's sign is wrong: set
% CTRL_GAIN = -1.

CONFIRMED_AREA_CLEAR = false;  % <-- set true once the area is clear
assert(CONFIRMED_AREA_CLEAR, "Set CONFIRMED_AREA_CLEAR = true once the area is clear.");

boardIP = "192.168.68.107";  % <-- set to your board's actual IP

%% test settings
TARGET_PITCH_DEG = 5;          % pitch angle (encoder) the step returns to
DELTA_PITCH_DEG = 3;           % <-- start this far from the target (negative = the other side)
KP = 0.1; KI = 0.2; KD = 0.05; % <-- controller gains
OUT_LIMIT_DEG = 15;            % the controller can move the elevators at most this far
CTRL_GAIN = -1;                % -1 if the controller pushes the wrong way
OVERSHOOT_ALLOWANCE_DEG = 3;   % abort if pitch strays more than |delta| + this from the target

STEADY_S = 4;                  % sample at the target
DISPLACED_S = 2;               % sample at the displaced pitch
PRE_STEP_S = 2;                % recorded at the displaced pitch before the step
POST_STEP_S = 10;              % recorded after the step
SAMPLE_HZ = 100;
USE_PXI = false;      % true: also record the 6-axis force sensor (PXI), started by the same trigger edge
PXI_CARD = "Dev5";    % the NI device
PXI_RATE_HZ = 200;    % force-sensor sample rate (while it records, MATLAB cannot watch the model, so no abort)

elevators = [wt.hasta.HDCh.ElevR wt.hasta.HDCh.ElevL];   % flip a servo's sign by hand if it is mounted mirrored

% the board takes one client at a time, so reuse an existing connection
if ~exist("hd","var") || ~isvalid(hd)
    hd = wt.hasta.DaqClient(boardIP);
end

% the force sensor, if used (needs the PXI wired to the board's trigger input)
forceDaq = [];
if USE_PXI
    forceDaq = wt.pxi.connect(hd, PXI_CARD, PXI_RATE_HZ);   % trigger line low, board set to a rising-edge start
end

%% set up: the real zero, and the controller's settings
hd.disableControl();                                      % the zero is refused while the PID runs
hd.setEncoderZeroOffset(wt.hasta.encoderZero.get());
hd.setControl(Kp=KP, Ki=KI, Kd=KD, outLimitDeg=OUT_LIMIT_DEG);
fprintf("Model is at %.2f deg. Step from %.2f deg back to %.2f deg ...\n", ...
    hd.getEncoderDeg(), TARGET_PITCH_DEG + DELTA_PITCH_DEG, TARGET_PITCH_DEG);

try
    %% 1. hold the target; the elevator angles that hold it
    r = hd.holdPitch(TARGET_PITCH_DEG, ctrlGain=CTRL_GAIN);
    fprintf("  holding the target: %s after %.1f s, pitch %.2f deg\n", settledText(r.settled), r.timeS, r.pitchDeg);
    atTarget = hd.capture(STEADY_S, SAMPLE_HZ);
    anglesTarget = meanAngles(atTarget, elevators);
    fprintf("  elevators that hold the target: %s deg\n", mat2str(round(anglesTarget, 2)));

    %% 2. move delta away; the elevator angles that hold that
    displacedPitch = TARGET_PITCH_DEG + DELTA_PITCH_DEG;
    r = hd.holdPitch(displacedPitch, ctrlGain=CTRL_GAIN);
    fprintf("  holding the displaced pitch: %s after %.1f s, pitch %.2f deg\n", settledText(r.settled), r.timeS, r.pitchDeg);
    displaced = hd.capture(DISPLACED_S, SAMPLE_HZ);
    anglesDisplaced = meanAngles(displaced, elevators);
    fprintf("  elevators that hold the displaced pitch: %s deg\n", mat2str(round(anglesDisplaced, 2)));

    %% 3. controller off at those angles, a step armed on the board, record
    hd.openLoopAtEquilibrium(displaced, surfaces=elevators, excGain=0);
    stepDeg = anglesTarget - anglesDisplaced;
    stepAmplitude = max(abs(stepDeg));
    if stepAmplitude < 0.05
        error("The elevator angles at the two pitches differ by less than 0.05 deg: there is no step to apply. Try a larger DELTA_PITCH_DEG.");
    end
    % each surface takes its share of one common step: excGain = its step / the largest step
    hd.setMix(elevators, excGain=stepDeg / stepAmplitude);
    hd.setExcitation("step", amplitudeDeg=stepAmplitude, delayS=PRE_STEP_S, armed=true);

    totalS = PRE_STEP_S + POST_STEP_S;
    fprintf("  recording %.0f s; the elevators step by %s deg after %.1f s ...\n", totalS, mat2str(round(stepDeg, 2)), PRE_STEP_S);
    aborted = false;
    if USE_PXI
        % the PXI record blocks MATLAB, so the model cannot be watched (no abort) until it ends
        [response, force] = wt.pxi.record(hd, forceDaq, totalS, SAMPLE_HZ);
    else
        hd.run(totalS, SAMPLE_HZ);              % the trigger: the board times the step itself
        clk = tic;
        while toc(clk) < totalS
            pitch = hd.getEncoderDeg();
            if abs(pitch - TARGET_PITCH_DEG) > abs(DELTA_PITCH_DEG) + OVERSHOOT_ALLOWANCE_DEG
                aborted = true;
                fprintf("  !!! pitch %.2f deg is %.1f deg from the target: switching the controller back on\n", ...
                    pitch, abs(pitch - TARGET_PITCH_DEG));
                break
            end
            pause(0.05);
        end
        if aborted
            hd.holdPitch(TARGET_PITCH_DEG, ctrlGain=CTRL_GAIN, timeoutS=10);   % also disarms the step
        end
        hd.waitForDone(totalS + 30);
        response = hd.readData();
    end
    hd.disarmExcitation();
catch ME
    % leave the model held rather than free-running if something goes wrong
    fprintf("\n!!! %s\n", ME.message);
    try
        hd.disarmExcitation();
        hd.holdPitch(TARGET_PITCH_DEG, ctrlGain=CTRL_GAIN, timeoutS=5);
        fprintf("!!! Controller switched back on to hold the model.\n");
    catch
        fprintf("!!! Could not reach the board to put the controller back on.\n");
    end
    rethrow(ME);
end

%% 4. back to holding the model (the settings you gave are kept)
hd.holdPitch(TARGET_PITCH_DEG, ctrlGain=CTRL_GAIN);
fprintf("Controller back on, holding %.2f deg (it is left running).\n", TARGET_PITCH_DEG);

%% the response
elevTrace = mean(response.ServoAngles(:, arrayfun(@(s) s.column(), elevators)), 2);
before = median(elevTrace(response.Time < 0.5 * PRE_STEP_S));
idx = find(abs(elevTrace - before) > 0.5 * stepAmplitude, 1);
stepTimeS = NaN;
if ~isempty(idx)
    stepTimeS = response.Time(idx);
end
m = stepMetrics(response.Time, response.EncoderDeg, stepTimeS);
fprintf("\nStep at %.2f s (armed for %.1f s). Pitch %.2f -> %.2f deg", stepTimeS, PRE_STEP_S, m.start, m.final);
fprintf(" | time to 63%%: %.2f s | overshoot: %.0f%% | 5%% settling: %.2f s%s\n", m.t63, m.overshootPct, m.settleS, abortedText(aborted));

figure("Name", "Free-to-pitch step response");
subplot(3, 1, 1);
plot(response.Time, response.ServoAngles); grid on; legend(string(enumeration("wt.hasta.HDCh")), "Location", "best");
xline(stepTimeS, "r--"); ylabel("elevator command (deg)"); title("Step from the displaced to the target elevator angles");
subplot(3, 1, 2);
plot(response.Time, response.EncoderDeg); grid on; hold on;
yline(TARGET_PITCH_DEG, "k--", "target"); yline(displacedPitch, "k:", "start"); xline(stepTimeS, "r--");
hold off; ylabel("pitch (deg)");
subplot(3, 1, 3);
plot(response.Time, response.ExcitationDeg); grid on;
xlabel("t (s)"); ylabel("step excitation (deg)");
linkaxes(findall(gcf, "Type", "axes"), "x");

if USE_PXI
    fprintf("Force sensor over the record: %s\n", forceText(force));
    wt.pxi.plotForces(force, "Free-pitch step: force sensor (untared)");
end


%% local functions (must be at the end of a script)
function trims = meanAngles(data, surfaces)
% The average commanded angle of each surface over a capture, as a row.
    trims = zeros(1, numel(surfaces));
    for i = 1:numel(surfaces)
        trims(i) = mean(data.Angle(surfaces(i)), "omitnan");
    end
end

function m = stepMetrics(t, y, tStep)
% How the pitch y responds to a step at tStep: its value before and at the end,
% the time to cover 63% of the change, the overshoot past the final value and
% the time after which it stays within 5% of the change. NaN where it doesn't apply.
    m = struct("start", NaN, "final", NaN, "t63", NaN, "overshootPct", NaN, "settleS", NaN);
    if isnan(tStep)
        return
    end
    m.start = mean(y(t >= 0.2 * tStep & t < tStep));
    tail = t > t(end) - 0.1 * (t(end) - tStep);
    m.final = mean(y(tail));
    change = m.final - m.start;
    if abs(change) < 0.05
        return
    end
    frac = (y - m.start) / change;          % 0 at the start value, 1 at the final value
    after = t >= tStep;
    i63 = find(after & frac >= 0.632, 1);
    if ~isempty(i63)
        m.t63 = t(i63) - tStep;
    end
    m.overshootPct = max(0, 100 * (max(frac(after)) - 1));
    outside = find(after & abs(frac - 1) > 0.05, 1, "last");
    if isempty(outside)
        m.settleS = 0;
    elseif outside < numel(t)
        m.settleS = t(outside + 1) - tStep;
    end
end

function str = abortedText(aborted)
    str = "";
    if aborted
        str = "  ABORTED (the controller was switched back on)";
    end
end

function str = settledText(settled)
    str = "NOT settled";
    if settled
        str = "settled";
    end
end

function str = forceText(force)
% The mean loads of a force record (no tare), as text.
    f = force.mean().Forces();
    str = sprintf("F = [%.2f %.2f %.2f] N, M = [%.3f %.3f %.3f] N.m (untared)", f);
end
