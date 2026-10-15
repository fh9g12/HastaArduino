% freePitchSine.m
%
% Free-to-pitch SINE test: the aircraft's response to the elevators moving
% sinusoidally, one frequency at a time. On the Hasta DAQ alone (no tunnel
% computer, nothing saved). For each frequency in FREQS_HZ:
%   1. the controller holds the model at a target pitch angle
%   2. a short capture gives the EQUILIBRIUM values (including the elevator
%      angles that hold that pitch)
%   3. the controller is switched off WITHOUT a jolt (the elevators keep
%      their equilibrium angles as fixed trim), or left running
%   4. a sine of CYCLES periods is added to the elevators while the response
%      is recorded
% then the pitch's response at that frequency (gain and phase) is fitted
% from the cycles after the first DISCARD_CYCLES, once the start-up
% transient has died away, and the results are listed and plotted. With the
% controller left running it is the CLOSED-LOOP response. At the end the
% controller is switched back on to hold the model.
%
% Run scripts.ZeroEncoderRun once first: the pitch target is an angle on the
% encoder, so the encoder's zero must be the model's real zero.
%
% THIS MOVES THE ELEVATORS AND THE MODEL, WHICH IS FREE TO PITCH. Make sure
% the area is clear and the tunnel conditions are what you intend. Start with
% gentle controller gains, a small OutLimitDeg and a small amplitude. If
% the model runs away from the target instead of settling, the controller's
% sign is wrong: set CtrlGain=1 in the ControlSettings.

CONFIRMED_AREA_CLEAR = true;  % <-- set true once the area is clear
assert(CONFIRMED_AREA_CLEAR, "Set CONFIRMED_AREA_CLEAR = true once the area is clear.");

%% test settings
TARGET_PITCH_DEG = 5;          % pitch angle (encoder) to hold and excite around
CONTROLLER_DURING_EXCITATION = false;   % true: leave the controller running during the sine

FREQS_HZ = 0.3:0.05:0.7;          % one sine test per frequency
AMPLITUDE_DEG = 2;             % elevator excitation amplitude
CYCLES = 8;                    % periods of sine per frequency
DISCARD_CYCLES = 3;            % ignore the first few when fitting (start-up transient)
DELAY_S = 1;                   % quiet recording before the sine starts
TAIL_S = 2;                    % ... and after it ends
STEADY_S = 4;                  % equilibrium sample time
SAMPLE_HZ = 100;
USE_PXI = true;      % true: also record the 6-axis force sensor (PXI), started by the same trigger edge
USE_CAMERA = false;    % true: pulse the tracking camera before and after the record (needs USE_PXI)

assert(CYCLES > DISCARD_CYCLES, "CYCLES must be larger than DISCARD_CYCLES.");
assert(all(FREQS_HZ > 0), "FREQS_HZ must be positive.");

elevators = [wt.hasta.HDCh.ElevR wt.hasta.HDCh.ElevL];   % flip a servo's sign by hand if it is mounted mirrored

[hd, ~, pxi] = wt.hasta.setupTestEnvironment(UsePxi=USE_PXI, UseCamera=USE_CAMERA);

%% set up: the controller's settings
control = wt.hasta.ControlSettings();   % Kp 0.1, Ki 0.2, Kd 0.05, limit 20, CtrlGain -1, tolerance 0.2: change by Name=Value
control.apply(hd);
fprintf("Model is at %.2f deg. %d frequencies around %.2f deg ...\n", ...
    hd.getEncoderDeg(), numel(FREQS_HZ), TARGET_PITCH_DEG);

gainOut = NaN(size(FREQS_HZ));     % pitch deg per elevator deg
phaseOut = NaN(size(FREQS_HZ));    % degrees; negative = pitch lags the elevator
responses = cell(size(FREQS_HZ));
try
    for fi = 1:numel(FREQS_HZ)
        freq = FREQS_HZ(fi);
        fprintf("\n=== %.3g Hz (%d/%d) ===\n", freq, fi, numel(FREQS_HZ));

        % 1. hold the target pitch
        r = control.hold(hd, TARGET_PITCH_DEG);
        fprintf("  holding: %s after %.1f s, pitch %.2f deg (error %+.2f)\n", ...
            settledText(r.settled), r.timeS, r.pitchDeg, r.errorDeg);

        % 2. equilibrium values
        [equilibrium, forceEq] = wt.pxi.record(hd, pxi, STEADY_S, SAMPLE_HZ, camera=false);
        if USE_PXI
            fprintf("  force sensor at equilibrium: %s\n", forceText(forceEq));
        end
        eqMean = equilibrium.mean();
        fprintf("  equilibrium: pitch %.2f deg, elevators R %.2f / L %.2f deg\n", ...
            eqMean.EncoderDeg, eqMean.ELEV_R_Angle, eqMean.ELEV_L_Angle);

        % 3. controller off at the equilibrium angles - or left on
        if CONTROLLER_DURING_EXCITATION
            hd.setMix(elevators, excGain=1);               % the sine rides on top of the controller
        else
            hd.openLoopAtEquilibrium(equilibrium, excGain=1);   % no jolt: same angles, now fixed
        end

        % 4. sine, recording the response
        hd.setExcitation("sine", freqHz=freq, amplitudeDeg=AMPLITUDE_DEG, ...
            cycles=CYCLES, delayS=DELAY_S, armed=true);
        durationS = DELAY_S + CYCLES / freq + TAIL_S;
        fprintf("  sine %.2g deg x %d cycles, recording %.0f s ...\n", AMPLITUDE_DEG, CYCLES, durationS);
        [response, force] = wt.pxi.record(hd, pxi, durationS, SAMPLE_HZ);
        hd.disarmExcitation();
        responses{fi} = response;

        % response at this frequency, from the settled cycles
        window = response.Time >= DELAY_S + DISCARD_CYCLES / freq & response.Time <= DELAY_S + CYCLES / freq;
        [gainOut(fi), phaseOut(fi)] = fitResponse(response.Time(window), ...
            response.ExcitationDeg(window), response.EncoderDeg(window), freq);
        fprintf("  response: gain %.3g deg/deg (%.1f dB), phase %.0f deg\n", ...
            gainOut(fi), 20 * log10(gainOut(fi)), phaseOut(fi));
    end
catch ME
    % leave the model held rather than free-running if something goes wrong
    fprintf("\n!!! %s\n", ME.message);
    try
        hd.disarmExcitation();
        control.hold(hd, TARGET_PITCH_DEG, timeoutS=5);
        fprintf("!!! Controller switched back on to hold the model.\n");
    catch
        fprintf("!!! Could not reach the board to put the controller back on.\n");
    end
    rethrow(ME);
end

%% back to holding the model (the settings you gave are kept)
control.hold(hd, TARGET_PITCH_DEG);
fprintf("\nController back on, holding %.2f deg (it is left running).\n", TARGET_PITCH_DEG);

%% results
loopText = "open loop";
if CONTROLLER_DURING_EXCITATION
    loopText = "closed loop (controller on)";
end
disp(table(FREQS_HZ(:), gainOut(:), 20 * log10(gainOut(:)), phaseOut(:), ...
    VariableNames=["Hz", "Gain_degPerDeg", "Gain_dB", "Phase_deg"]));

figure("Name", "Free-to-pitch sine: response");
subplot(2, 1, 1);
semilogx(FREQS_HZ, 20 * log10(gainOut), "o-"); grid on;
ylabel("gain (dB)"); title("Pitch / elevator excitation, " + loopText);
subplot(2, 1, 2);
semilogx(FREQS_HZ, phaseOut, "o-"); grid on;
xlabel("frequency (Hz)"); ylabel("phase (deg)");

figure("Name", "Free-to-pitch sine: time histories");
for fi = 1:numel(FREQS_HZ)
    resp = responses{fi};
    subplot(numel(FREQS_HZ), 2, 2 * fi - 1);
    plot(resp.Time, resp.ExcitationDeg); grid on;
    ylabel(sprintf("%.3g Hz: excitation (deg)", FREQS_HZ(fi)));
    subplot(numel(FREQS_HZ), 2, 2 * fi);
    plot(resp.Time, resp.EncoderDeg); grid on;
    ylabel("pitch (deg)");
end
subplot(numel(FREQS_HZ), 2, 2 * numel(FREQS_HZ) - 1); xlabel("t (s)");
subplot(numel(FREQS_HZ), 2, 2 * numel(FREQS_HZ)); xlabel("t (s)");

if USE_PXI
    fprintf("Force sensor over the last record: %s\n", forceText(force));
    wt.pxi.plotForces(force, "Free-pitch sine: force sensor, last record (untared)");
end


%% local functions (must be at the end of a script)
function [gain, phaseDeg] = fitResponse(t, u, y, freqHz)
% Fits a sine of freqHz (plus an offset and a linear drift) to the excitation
% u and the pitch y over the window, by least squares. gain = |pitch| /
% |excitation| (deg per deg); phaseDeg = how far the pitch is ahead of the
% excitation (negative = it lags).
    t = t(:);
    w = 2 * pi * freqHz;
    X = [sin(w * t), cos(w * t), ones(size(t)), t - mean(t)];
    cu = X \ u(:);
    cy = X \ y(:);
    % a sin(wt) + b cos(wt) = Re{(b - 1i a) e^{iwt}}
    Zu = cu(2) - 1i * cu(1);
    Zy = cy(2) - 1i * cy(1);
    gain = abs(Zy) / abs(Zu);
    phaseDeg = angle(Zy / Zu) * 180 / pi;
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
