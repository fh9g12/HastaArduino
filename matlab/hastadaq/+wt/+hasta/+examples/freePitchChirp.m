% freePitchChirp.m
%
% Free-to-pitch CHIRP test: how does the aircraft respond to a frequency
% sweep of the elevators? On the Hasta DAQ alone (no tunnel computer,
% nothing saved):
%   1. the controller holds the model at a target pitch angle
%   2. a short capture gives the EQUILIBRIUM values (including the elevator
%      angles that hold that pitch)
%   3. the controller is switched off WITHOUT a jolt (the elevators keep
%      their equilibrium angles as fixed trim), or left running
%   4. a chirp is added to the elevators while the response is recorded
%   5. the controller is switched back on to hold the model
% then the frequency response from elevator excitation to pitch is
% estimated (FFT ratio over the chirp band; plain MATLAB, no toolbox) and
% plotted with the time histories. With the controller left running it is
% the CLOSED-LOOP response.
%
% Run scripts.ZeroEncoderRun once first: the pitch target is an angle on the
% encoder, so the encoder's zero must be the model's real zero.
%
% THIS MOVES THE ELEVATORS AND THE MODEL, WHICH IS FREE TO PITCH. Make sure
% the area is clear and the tunnel conditions are what you intend. Start with
% gentle controller gains, a small OUT_LIMIT_DEG and a small chirp amplitude.
% If the model runs away from the target instead of settling, the
% controller's sign is wrong: set CTRL_GAIN = -1.

CONFIRMED_AREA_CLEAR = true;  % <-- set true once the area is clear
assert(CONFIRMED_AREA_CLEAR, "Set CONFIRMED_AREA_CLEAR = true once the area is clear.");

boardIP = "192.168.1.107";  % <-- set to your board's actual IP

%% test settings
TARGET_PITCH_DEG = 5;          % pitch angle (encoder) to hold and excite around
KP = 0.1; KI = 0.2; KD = 0.05;      % <-- controller gains
OUT_LIMIT_DEG = 15;            % the controller can move the elevators at most this far
CTRL_GAIN = -1;                 % -1 if the controller pushes the wrong way
CONTROLLER_DURING_EXCITATION = false;   % true: leave the controller running during the chirp

F0_HZ = 0.2; F1_HZ = 1;        % the chirp sweeps F0 -> F1 once ...
PERIOD_S = 20;                 % ... taking this long
AMPLITUDE_DEG = 2.5;             % elevator excitation amplitude
DELAY_S = 2;                   % quiet recording before the chirp starts
TAIL_S = 3;                    % ... and after it ends, to see it settle
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
fprintf("Model is at %.2f deg. Holding %.2f deg ...\n", hd.getEncoderDeg(), TARGET_PITCH_DEG);

%% 1. hold the target pitch
r = hd.holdPitch(TARGET_PITCH_DEG, ctrlGain=CTRL_GAIN);
fprintf("  %s after %.1f s: pitch %.2f deg (error %+.2f)\n", settledText(r.settled), r.timeS, r.pitchDeg, r.errorDeg);

%% 2. equilibrium values
[equilibrium, forceEq] = wt.pxi.record(hd, forceDaq, STEADY_S, SAMPLE_HZ);
if USE_PXI
    fprintf("  force sensor at equilibrium: %s\n", forceText(forceEq));
end
eqMean = equilibrium.mean();
fprintf("Equilibrium: pitch %.2f deg, elevators R %.2f / L %.2f deg\n", ...
    eqMean.EncoderDeg, eqMean.ELEV_R_Angle, eqMean.ELEV_L_Angle);

%% 3. controller off at the equilibrium angles - or left on
if CONTROLLER_DURING_EXCITATION
    hd.setMix(elevators, excGain=1);                       % the chirp rides on top of the controller
    fprintf("Controller left ON for the chirp.\n");
else
    hd.openLoopAtEquilibrium(equilibrium, excGain=1);      % no jolt: same angles, now fixed
    fprintf("Controller OFF; elevators held at their equilibrium angles.\n");
end

%% 4. chirp, recording the response
hd.setExcitation("chirp", f0=F0_HZ, f1=F1_HZ, periodS=PERIOD_S, ...
    amplitudeDeg=AMPLITUDE_DEG, cycles=1, delayS=DELAY_S, armed=true);
durationS = DELAY_S + PERIOD_S + TAIL_S;
fprintf("Chirp %.2g -> %.2g Hz, %.2g deg, recording %.0f s ...\n", F0_HZ, F1_HZ, AMPLITUDE_DEG, durationS);
[response, force] = wt.pxi.record(hd, forceDaq, durationS, SAMPLE_HZ);
hd.disarmExcitation();

%% 5. back to holding the model (the settings you gave are kept)
hd.holdPitch(TARGET_PITCH_DEG, ctrlGain=CTRL_GAIN);
fprintf("Controller back on, holding %.2f deg (it is left running).\n", TARGET_PITCH_DEG);

%% frequency response: excitation -> pitch, over the chirp band
[freqHz, H] = responseEstimate(response.Time, response.ExcitationDeg, response.EncoderDeg, F0_HZ, F1_HZ);
loopText = "open loop";
if CONTROLLER_DURING_EXCITATION
    loopText = "closed loop (controller on)";
end

%% plots
figure("Name", "Free-to-pitch chirp");
subplot(3, 2, 1);
plot(response.Time, response.ExcitationDeg); grid on;
ylabel("excitation (deg)"); title("Chirp");
subplot(3, 2, 3);
plot(response.Time, response.ELEV_R_Angle, response.Time, response.ELEV_L_Angle); grid on;
ylabel("elevator (deg)"); legend("R", "L", "Location", "best");
subplot(3, 2, 5);
plot(response.Time, response.EncoderDeg); grid on;
xlabel("t (s)"); ylabel("pitch (deg)");

subplot(3, 2, 2);
semilogx(freqHz, 20 * log10(abs(H))); grid on;
ylabel("gain (dB)"); title("Pitch / elevator excitation, " + loopText);
subplot(3, 2, 4);
semilogx(freqHz, unwrap(angle(H)) * 180 / pi); grid on;
ylabel("phase (deg)");
subplot(3, 2, 6);
plot(equilibrium.Time, equilibrium.EncoderDeg); grid on;
xlabel("t (s)"); ylabel("pitch (deg)"); title("Equilibrium before the chirp");

if USE_PXI
    fprintf("Force sensor over the last record: %s\n", forceText(force));
    wt.pxi.plotForces(force, "Free-pitch chirp: force sensor, last record (untared)");
end


%% local functions (must be at the end of a script)
function [freqHz, H] = responseEstimate(t, u, y, fLo, fHi)
% FFT ratio H(f) = Y(f) / U(f): the pitch y against the excitation u, kept
% only inside [fLo, fHi] where the chirp actually has energy. Both signals
% are put on a uniform time grid and de-trended first. A plain, unwindowed
% estimate - fine for a first look, not a substitute for averaging.
    n = numel(t);
    fs = (n - 1) / (t(end) - t(1));
    tUniform = linspace(t(1), t(end), n)';
    uUniform = detrend(interp1(t, u, tUniform, "linear"));
    yUniform = detrend(interp1(t, y, tUniform, "linear"));
    nHalf = floor(n / 2) + 1;
    U = fft(uUniform); U = U(1:nHalf);
    Y = fft(yUniform); Y = Y(1:nHalf);
    f = fs * (0:nHalf - 1)' / n;
    keep = f >= fLo & f <= fHi & abs(U) > 0.05 * max(abs(U));
    freqHz = f(keep);
    H = Y(keep) ./ U(keep);
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
