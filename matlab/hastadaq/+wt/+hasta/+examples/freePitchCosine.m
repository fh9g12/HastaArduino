% freePitchCosine.m
%
% Free-to-pitch 1-COSINE PULSE test: the aircraft's response to a smooth
% elevator pulse (up from its equilibrium angle and back over PERIODS_S, or
% down for a negative amplitude). On the Hasta DAQ alone (no tunnel computer,
% nothing saved). For each period in PERIODS_S:
%   1. the controller holds the model at a target pitch angle
%   2. a short capture gives the EQUILIBRIUM values (including the elevator
%      angles that hold that pitch)
%   3. the controller is switched off WITHOUT a jolt (the elevators keep
%      their equilibrium angles as fixed trim), or left running
%   4. one pulse is added to the elevators, timed on the board, and the
%      response is recorded: the model's free motion after the pulse
% then the peak pitch excursion, when it occurred and where the pitch ends up
% are listed and the responses are plotted together. With the controller
% left running it is the CLOSED-LOOP response. At the end the controller is
% switched back on to hold the model.
%
% Run scripts.ZeroEncoderRun once first: the pitch target is an angle on the
% encoder, so the encoder's zero must be the model's real zero. The tunnel
% version of this, which saves data, is scripts.FreePitchCosine.
%
% THIS MOVES THE ELEVATORS AND THE MODEL, WHICH IS FREE TO PITCH. Make sure
% the area is clear and the tunnel conditions are what you intend. Start with
% gentle controller gains, a small OUT_LIMIT_DEG and a small amplitude. If
% the model runs away from the target instead of settling, the controller's
% sign is wrong: set CTRL_GAIN = -1.

CONFIRMED_AREA_CLEAR = false;  % <-- set true once the area is clear
assert(CONFIRMED_AREA_CLEAR, "Set CONFIRMED_AREA_CLEAR = true once the area is clear.");

boardIP = "192.168.1.107";  % <-- set to your board's actual IP

%% test settings
TARGET_PITCH_DEG = 5;          % pitch angle (encoder) to hold and pulse around
KP = 0.1; KI = 0.2; KD = 0.05; % <-- controller gains
OUT_LIMIT_DEG = 15;            % the controller can move the elevators at most this far
CTRL_GAIN = -1;                % -1 if the controller pushes the wrong way
CONTROLLER_DURING_EXCITATION = false;   % true: leave the controller running during the pulse

PERIODS_S = [2 4];             % one pulse per period (how long the bump takes)
AMPLITUDE_DEG = 2;             % pulse size (elevator deg); negative = the other way
DELAY_S = 1;                   % quiet recording before the pulse starts
TAIL_S = 8;                    % recorded after the pulse ends: the free response
STEADY_S = 4;                  % equilibrium sample time
SAMPLE_HZ = 100;
USE_PXI = false;      % true: also record the 6-axis force sensor (PXI), started by the same trigger edge
PXI_CARD = "Dev5";    % the NI device
PXI_RATE_HZ = 200;    % force-sensor sample rate

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
fprintf("Model is at %.2f deg. %d pulse(s) of %+g deg around %.2f deg ...\n", ...
    hd.getEncoderDeg(), numel(PERIODS_S), AMPLITUDE_DEG, TARGET_PITCH_DEG);

peakDeg = NaN(size(PERIODS_S));      % largest pitch excursion from the pre-pulse pitch, signed
peakAtS = NaN(size(PERIODS_S));      % ... and when, after the pulse started
endDeg = NaN(size(PERIODS_S));       % pitch at the end of the record relative to before the pulse
responses = cell(size(PERIODS_S));
baselines = NaN(size(PERIODS_S));
try
    for pi_ = 1:numel(PERIODS_S)
        period = PERIODS_S(pi_);
        fprintf("\n=== pulse %d/%d: %.3g s ===\n", pi_, numel(PERIODS_S), period);

        % 1. hold the target pitch
        r = hd.holdPitch(TARGET_PITCH_DEG, ctrlGain=CTRL_GAIN);
        fprintf("  holding: %s after %.1f s, pitch %.2f deg (error %+.2f)\n", ...
            settledText(r.settled), r.timeS, r.pitchDeg, r.errorDeg);

        % 2. equilibrium values
        [equilibrium, forceEq] = wt.pxi.record(hd, forceDaq, STEADY_S, SAMPLE_HZ);
        if USE_PXI
            fprintf("  force sensor at equilibrium: %s\n", forceText(forceEq));
        end
        eqMean = equilibrium.mean();
        fprintf("  equilibrium: pitch %.2f deg, elevators R %.2f / L %.2f deg\n", ...
            eqMean.EncoderDeg, eqMean.ELEV_R_Angle, eqMean.ELEV_L_Angle);

        % 3. controller off at the equilibrium angles - or left on
        if CONTROLLER_DURING_EXCITATION
            hd.setMix(elevators, excGain=1);               % the pulse rides on top of the controller
        else
            hd.openLoopAtEquilibrium(equilibrium, excGain=1);   % no jolt: same angles, now fixed
        end

        % 4. the pulse, recording the response
        hd.setExcitation("cosine", periodS=period, amplitudeDeg=AMPLITUDE_DEG, cycles=1, delayS=DELAY_S, armed=true);
        durationS = DELAY_S + period + TAIL_S;
        fprintf("  pulse %+g deg over %.3g s, recording %.0f s ...\n", AMPLITUDE_DEG, period, durationS);
        [response, force] = wt.pxi.record(hd, forceDaq, durationS, SAMPLE_HZ);
        hd.disarmExcitation();
        responses{pi_} = response;

        % how the pitch moved relative to where it was just before the pulse
        before = mean(response.EncoderDeg(response.Time >= 0.2 * DELAY_S & response.Time < DELAY_S));
        baselines(pi_) = before;
        dev = response.EncoderDeg - before;
        afterPulse = response.Time >= DELAY_S;
        [~, iPeak] = max(abs(dev(afterPulse)));
        times = response.Time(afterPulse);
        devs = dev(afterPulse);
        peakDeg(pi_) = devs(iPeak);
        peakAtS(pi_) = times(iPeak) - DELAY_S;
        endDeg(pi_) = mean(dev(response.Time > response.Time(end) - 0.1 * TAIL_S));
        fprintf("  response: peak %+.2f deg at %.2f s after the pulse started, %+.2f deg left at the end\n", ...
            peakDeg(pi_), peakAtS(pi_), endDeg(pi_));
    end
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

%% back to holding the model (the settings you gave are kept)
hd.holdPitch(TARGET_PITCH_DEG, ctrlGain=CTRL_GAIN);
fprintf("\nController back on, holding %.2f deg (it is left running).\n", TARGET_PITCH_DEG);

%% results
loopText = "open loop";
if CONTROLLER_DURING_EXCITATION
    loopText = "closed loop (controller on)";
end
disp(table(PERIODS_S(:), peakDeg(:), peakAtS(:), endDeg(:), ...
    VariableNames=["Period_s", "Peak_deg", "PeakAt_s", "AtEnd_deg"]));

figure("Name", "Free-to-pitch 1-cosine pulse");
subplot(2, 1, 1);
hold on;
for pi_ = 1:numel(PERIODS_S)
    resp = responses{pi_};
    plot(resp.Time - DELAY_S, resp.ExcitationDeg, "DisplayName", sprintf("%.3g s", PERIODS_S(pi_)));
end
hold off; grid on; legend("Location", "best");
ylabel("pulse (deg)"); title("1-cosine pulse and pitch response, " + loopText);
subplot(2, 1, 2);
hold on;
for pi_ = 1:numel(PERIODS_S)
    resp = responses{pi_};
    plot(resp.Time - DELAY_S, resp.EncoderDeg - baselines(pi_), "DisplayName", sprintf("%.3g s", PERIODS_S(pi_)));
end
hold off; grid on;
xlabel("time since the pulse started (s)"); ylabel("pitch change (deg)");
linkaxes(findall(gcf, "Type", "axes"), "x");

if USE_PXI
    fprintf("Force sensor over the last record: %s\n", forceText(force));
    wt.pxi.plotForces(force, "Free-pitch 1-cosine: force sensor, last record (untared)");
end


%% local functions (must be at the end of a script)
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
