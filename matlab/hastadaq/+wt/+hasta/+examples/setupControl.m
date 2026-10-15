% setupControl.m
%
% Configure and enable the elevator PID loop (error = target - encoder
% angle), apply a target step, and plot the response. For a full tuning
% test with a logged capture see controlStepResponseTest.m.
%
% The PID has ONE output; each channel's ctrlGain (-1..1) sets how much of
% it that channel follows. Here both elevators follow it, everything else
% ignores it.
%
% The loop's target is an angle on the encoder, so the encoder's zero must
% be the model's real zero: this sends the zero saved by
% scripts.ZeroEncoderRun (run that once first) rather than zeroing wherever
% the model happens to be.
%
% THIS MOVES THE ELEVATORS. Make sure they are clear. Start with small
% gains and a small outLimitDeg - the output limit is the real safety cap
% on the loop's authority.

CONFIRMED_AREA_CLEAR = true;  % <-- set true once the surfaces are clear
assert(CONFIRMED_AREA_CLEAR, "Set CONFIRMED_AREA_CLEAR = true once the surfaces are clear to move.");

KP = 0; KI = 0.1; KD = 0;   % <-- tune these and re-run
OUT_LIMIT_DEG = 30;
TARGET_BEFORE_DEG = 0;
TARGET_AFTER_DEG = 5;
SETTLE_S = 2;                   % hold the first target this long
RESPONSE_S = 5;                 % then step and log this long

hd = wt.hasta.setupTestEnvironment(SendEncoderZero=false);   % the connection is kept for the next script

% Start with control off and no excitation, then wire up the channels.
hd.disableControl();
hd.disarmExcitation();
for ch = enumeration("wt.hasta.HDCh")'
    hd.setChannel(ch, excGain=0, ctrlGain=0, trimDeg=0);
end
% Flip one of these to -1 if an elevator servo is mounted mirrored.
hd.setChannel(wt.hasta.HDCh.ElevL, ctrlGain=-1);
hd.setChannel(wt.hasta.HDCh.ElevR, ctrlGain=-1);

% Send the saved encoder zero (control is off, so this is allowed).
hd.setEncoderZeroOffset(wt.hasta.encoderZero.get());
fprintf("Encoder reads %.3f deg with the saved zero applied.\n", hd.getEncoderDeg());

% Configure the loop, then enable it. Enabling resets the integral.
hd.setControl(Kp=KP, Ki=KI, Kd=KD, targetDeg=TARGET_BEFORE_DEG, ...
              outLimitDeg=OUT_LIMIT_DEG);
disp(hd.getControl());
hd.enableControl();

% % Poll the encoder, step the target part way through. If anything goes
% % wrong (e.g. the board stops answering) switch the loop off again before
% % the error is reported, so it isn't left driving the elevators.
% t = []; angle = []; stepped = false;
% clk = tic;
% try
%     while toc(clk) < SETTLE_S + RESPONSE_S
%         if ~stepped && toc(clk) >= SETTLE_S
%             hd.setControl(targetDeg=TARGET_AFTER_DEG);
%             stepTime = toc(clk);
%             stepped = true;
%         end
%         t(end+1) = toc(clk);                    %#ok<SAGROW>
%         angle(end+1) = hd.getEncoderDeg();      %#ok<SAGROW>
%     end
% catch ME
%     try
%         hd.disableControl();
%     catch
%         % board unreachable: nothing more can be done from here
%     end
%     rethrow(ME);
% end
% 
% hd.disableControl(); % elevators drop back to their trim
% clear hd
% 
% figure("Name", "Control step response");
% plot(t, angle, "DisplayName", "encoder"); hold on;
% yline(TARGET_BEFORE_DEG, "k--", "DisplayName", "target before");
% yline(TARGET_AFTER_DEG, "k:", "DisplayName", "target after");
% xline(stepTime, "r--", "DisplayName", "step applied");
% hold off; grid on; legend("Location", "best");
% xlabel("t (s)"); ylabel("encoder (deg)");
% title(sprintf("Kp=%.3g Ki=%.3g Kd=%.3g", KP, KI, KD));
