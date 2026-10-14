% pitchTest.m
%
% A free-to-pitch test, start to finish, on the Hasta DAQ alone (no tunnel
% computer, nothing saved):
%   1. the controller holds the model at a target pitch angle, and we wait
%      for it to settle
%   2. a short capture of the steady condition gives the EQUILIBRIUM values
%      (including the elevator angles needed to hold that pitch)
%   3. the controller is switched off WITHOUT a jolt (the elevators keep
%      their equilibrium angles as fixed trim) - or left running, see
%      CONTROLLER_DURING_EXCITATION
%   4. a chirp is applied to the elevators while the response is recorded
%   5. the controller is switched back on to hold the model again
% and the results are plotted. For the same sequence at several pitch
% angles, with the tunnel computer and data saved, see scripts.FreePitchSine / FreePitchChirp / FreePitchStep.
%
% Run scripts.ZeroEncoderRun once first: the controller's target is an angle
% on the encoder, so the encoder's zero must be the model's real zero.
%
% THIS MOVES THE ELEVATORS AND THE MODEL, WHICH IS FREE TO PITCH. Make sure
% the area is clear and the tunnel conditions are what you intend. Start with
% gentle gains, a small OUT_LIMIT_DEG and a small chirp amplitude. If the
% model runs away from the target instead of settling, the controller's sign
% is wrong: set CTRL_GAIN = -1.

CONFIRMED_AREA_CLEAR = false;  % <-- set true once the area is clear
assert(CONFIRMED_AREA_CLEAR, "Set CONFIRMED_AREA_CLEAR = true once the area is clear.");

boardIP = "192.168.68.107";  % <-- set to your board's actual IP

TARGET_PITCH_DEG = 5;          % pitch angle (encoder) to hold
KP = 1; KI = 0.2; KD = 0;      % <-- tune these
OUT_LIMIT_DEG = 15;            % the controller can move the elevators at most this far
CTRL_GAIN = 1;                 % -1 if the controller pushes the wrong way
STEADY_S = 4;                  % equilibrium sample time, s
SAMPLE_HZ = 100;
CONTROLLER_DURING_EXCITATION = false;   % true: leave the controller running during the chirp

% the chirp: sweeps F0 -> F1 over PERIOD_S, once, after DELAY_S of quiet
F0_HZ = 0.5; F1_HZ = 4; PERIOD_S = 10; AMPLITUDE_DEG = 1; DELAY_S = 1; TAIL_S = 2;

elevators = [wt.hasta.HDCh.ElevR wt.hasta.HDCh.ElevL];   % flip a servo's sign by hand if it is mounted mirrored

% the board takes one client at a time, so reuse an existing connection
if ~exist("hd","var") || ~isvalid(hd)
    hd = wt.hasta.DaqClient(boardIP);
end

%% set up: the real zero, and the controller's settings
hd.disableControl();                                      % the zero is refused while the PID runs
hd.setEncoderZeroOffset(wt.hasta.encoderZero.get());
hd.setControl(Kp=KP, Ki=KI, Kd=KD, outLimitDeg=OUT_LIMIT_DEG);
fprintf("Model is at %.2f deg. Holding %.2f deg ...\n", hd.getEncoderDeg(), TARGET_PITCH_DEG);

%% 1. hold the target pitch
r = hd.holdPitch(TARGET_PITCH_DEG, ctrlGain=CTRL_GAIN);
status = "NOT settled";
if r.settled
    status = "settled";
end
fprintf("  %s after %.1f s: pitch %.2f deg (error %+.2f)\n", status, r.timeS, r.pitchDeg, r.errorDeg);

%% 2. equilibrium values
equilibrium = hd.capture(STEADY_S, SAMPLE_HZ);
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
response = hd.capture(durationS, SAMPLE_HZ);
hd.disarmExcitation();

%% 5. back to holding the model (the settings you gave are kept)
r = hd.holdPitch(TARGET_PITCH_DEG, ctrlGain=CTRL_GAIN);
fprintf("Controller back on, holding %.2f deg (it is left running).\n", TARGET_PITCH_DEG);

%% plots
figure("Name", "Free-to-pitch test");
subplot(3, 2, 1);
plot(equilibrium.Time, equilibrium.EncoderDeg); grid on;
ylabel("pitch (deg)"); title("Equilibrium (controller holding)");
subplot(3, 2, 3);
plot(equilibrium.Time, equilibrium.ELEV_R_Angle, equilibrium.Time, equilibrium.ELEV_L_Angle); grid on;
ylabel("elevator (deg)"); legend("R", "L", "Location", "best");
subplot(3, 2, 5);
plot(equilibrium.Time, equilibrium.ControlOutputDeg); grid on;
xlabel("t (s)"); ylabel("controller output (deg)");

subplot(3, 2, 2);
plot(response.Time, response.EncoderDeg); grid on;
ylabel("pitch (deg)"); title("Chirp response");
subplot(3, 2, 4);
plot(response.Time, response.ELEV_R_Angle, response.Time, response.ELEV_L_Angle); grid on;
ylabel("elevator (deg)"); legend("R", "L", "Location", "best");
subplot(3, 2, 6);
plot(response.Time, response.ExcitationDeg); grid on;
xlabel("t (s)"); ylabel("excitation (deg)");
