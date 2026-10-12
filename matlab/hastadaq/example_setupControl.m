% example_setupControl.m
%
% Configure and enable the elevator PID loop (error = target - encoder
% angle), apply a target step, and plot the response. For a full tuning
% test with a logged capture see controlStepResponseTest.m.
%
% The PID has ONE output; each channel's ctrlGain (-1..1) sets how much of
% it that channel follows. Here both elevators follow it, everything else
% ignores it.
%
% THIS MOVES THE ELEVATORS. Make sure they are clear. Start with small
% gains and a small outLimitDeg - the output limit is the real safety cap
% on the loop's authority.

CONFIRMED_AREA_CLEAR = false;  % <-- set true once the surfaces are clear
assert(CONFIRMED_AREA_CLEAR, "Set CONFIRMED_AREA_CLEAR = true once the surfaces are clear to move.");

boardIP = "192.168.68.107";  % <-- set to your board's actual IP

KP = 0.5; KI = 0.0; KD = 0.0;   % <-- tune these and re-run
OUT_LIMIT_DEG = 10;
TARGET_BEFORE_DEG = 0;
TARGET_AFTER_DEG = 5;
SETTLE_S = 2;                   % hold the first target this long
RESPONSE_S = 5;                 % then step and log this long

hd = HastaDaqClient(boardIP);

% Start with control off and no excitation, then wire up the channels.
hd.disableControl();
hd.disarmExcitation();
for ch = enumeration("HastaDaqChannel")'
    hd.setChannel(ch, excGain=0, ctrlGain=0, trimDeg=0);
end
% Flip one of these to -1 if an elevator servo is mounted mirrored.
hd.setChannel(HastaDaqChannel.ElevL, ctrlGain=1);
hd.setChannel(HastaDaqChannel.ElevR, ctrlGain=1);

% Zero the encoder where the model currently sits (control is off, so
% this is allowed). Remove if you've already zeroed.
hd.zeroEncoder();

% Configure the loop, then enable it. Enabling resets the integral.
hd.setControl(Kp=KP, Ki=KI, Kd=KD, targetDeg=TARGET_BEFORE_DEG, ...
              outLimitDeg=OUT_LIMIT_DEG);
disp(hd.getControl());
hd.enableControl();

% Poll the encoder, step the target part way through.
t = []; angle = []; stepped = false;
clk = tic;
while toc(clk) < SETTLE_S + RESPONSE_S
    if ~stepped && toc(clk) >= SETTLE_S
        hd.setControl(targetDeg=TARGET_AFTER_DEG);
        stepTime = toc(clk);
        stepped = true;
    end
    t(end+1) = toc(clk);                    %#ok<SAGROW>
    angle(end+1) = hd.getEncoderDeg();      %#ok<SAGROW>
end

hd.disableControl(); % elevators drop back to their trim
clear hd

figure("Name", "Control step response");
plot(t, angle, "DisplayName", "encoder"); hold on;
yline(TARGET_BEFORE_DEG, "k--", "DisplayName", "target before");
yline(TARGET_AFTER_DEG, "k:", "DisplayName", "target after");
xline(stepTime, "r--", "DisplayName", "step applied");
hold off; grid on; legend("Location", "best");
xlabel("t (s)"); ylabel("encoder (deg)");
title(sprintf("Kp=%.3g Ki=%.3g Kd=%.3g", KP, KI, KD));
