% controlStepResponseTest.m
%
% Step-response test for HastaDAQ's pitch controller - plots how the
% encoder tracks a step change in target angle, to help tune Kp/Ki/Kd (the
% controller runs every loop() iteration on its own real elapsed dt - there
% is no separate rate to tune, just the gains).
%
% The capture is non-blocking: it is started, the target is stepped part way
% through, and the response is read back afterwards - one continuous record
% spanning both the quiet baseline before the step and the transient, rather
% than two runs to stitch together. For a rougher look that just polls the
% encoder, see wt.hasta.examples.setupControl.
%
% Run scripts.ZeroEncoderRun once first: the targets are angles on the
% encoder, so the encoder's zero must be the model's real zero.
%
% THIS MOVES THE ELEVATORS (AND THE MODEL, IF IT IS FREE TO PITCH). Make sure
% the area is clear, and start with gentle gains and a small OUT_LIMIT_DEG.
% If the model runs away from the target instead of settling, the
% controller's sign is wrong: set CTRL_GAIN = -1.
%
% Get boardIP from the Serial Monitor at boot ("[WiFi] Connected, IP=...").

CONFIRMED_AREA_CLEAR = false;  % <-- set true once the area is clear
assert(CONFIRMED_AREA_CLEAR, "Set CONFIRMED_AREA_CLEAR = true once the area is clear.");

boardIP = "192.168.68.107";  % <-- set to your board's actual IP

KP = 1.0; KI = 0.0; KD = 0.0; % <-- tune these and re-run
OUT_LIMIT_DEG = 15.0;
CTRL_GAIN = 1;                % -1 if the controller pushes the wrong way
TARGET_BEFORE_DEG = 0.0;
TARGET_AFTER_DEG = 10.0;
PRE_STEP_S = 1.0;   % baseline logged before the step
POST_STEP_S = 4.0;  % response logged after the step
SAMPLE_HZ = 100;

durationS = PRE_STEP_S + POST_STEP_S;

% the board takes one client at a time, so reuse an existing connection
if ~exist("hd","var") || ~isvalid(hd)
    hd = wt.hasta.DaqClient(boardIP);
end

% the real zero, then the controller's settings
hd.disableControl();                                      % the zero is refused while the PID runs
hd.setEncoderZeroOffset(wt.hasta.encoderZero.get());
hd.setControl(Kp=KP, Ki=KI, Kd=KD, outLimitDeg=OUT_LIMIT_DEG);

% Hold the starting target and let it settle BEFORE the timed capture
% begins - otherwise the initial settle transient would contaminate the
% "before" baseline. holdPitch also wires the elevators to the controller
% and enables it.
r = hd.holdPitch(TARGET_BEFORE_DEG, ctrlGain=CTRL_GAIN);
fprintf("Holding %.2f deg: pitch %.2f deg (error %+.2f) after %.1f s\n", ...
    TARGET_BEFORE_DEG, r.pitchDeg, r.errorDeg, r.timeS);

hd.run(durationS, SAMPLE_HZ);          % returns at once; the capture continues on the board
pause(PRE_STEP_S);
hd.setControl(targetDeg=TARGET_AFTER_DEG);
fprintf("Step to %.2f deg applied.\n", TARGET_AFTER_DEG);

hd.waitForDone(durationS + 30);
data = hd.readData();
hd.disableControl();                   % the elevators drop back to their trim
clear hd % close the TCP connection

figure("Name", "Pitch control step response");

subplot(2, 1, 1);
plot(data.Time, data.EncoderDeg, "DisplayName", "encoder (measured)");
hold on;
yline(TARGET_BEFORE_DEG, "k--", "DisplayName", "target before");
yline(TARGET_AFTER_DEG, "k:", "DisplayName", "target after");
xline(PRE_STEP_S, "r--", "DisplayName", "step applied");
hold off;
xlabel("t (s)"); ylabel("deg");
title(sprintf("Step response: Kp=%.3g Ki=%.3g Kd=%.3g", KP, KI, KD));
legend("Location", "best");
grid on;

subplot(2, 1, 2);
plot(data.Time, data.ControlOutputDeg);
xlabel("t (s)"); ylabel("control output (deg)");
title("PID output (pre-mix, before excGain/ctrlGain scaling)");
grid on;
