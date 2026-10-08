% controlStepResponseTest.m
%
% Step-response test for HastaDAQ's elevator control loop -- plots how
% the encoder tracks a step change in target angle, to help tune
% Kp/Ki/Kd (control loop runs every loop() iteration on its own real
% elapsed dt -- no separate rate to tune, just the gains).
%
% Exploits HastaDAQ's non-blocking RUN (see HastaDAQ.ino: it returns "OK"
% immediately, the capture continues in the background): starts a
% capture, lets it log a moment at the STARTING target, then steps
% CTRLCONFIG's target MID-CAPTURE and keeps logging the response -- one
% continuous capture spanning both the pre-step baseline and the
% transient, rather than needing to stitch two separate runs together.
%
% Get boardIP from the Serial Monitor at boot ("[WiFi] Connected, IP=...").

addpath(fullfile(fileparts(mfilename("fullpath")), "..", "common"));

boardIP = "192.168.68.107";  % <-- set to your board's actual IP
port = 5025;

KP = 1.0; KI = 0.0; KD = 0.0; % <-- tune these and re-run
OUT_LIMIT_DEG = 15.0;
TARGET_BEFORE_DEG = 0.0;
TARGET_AFTER_DEG = 10.0;
PRE_STEP_S = 1.0;   % baseline logged before the step
POST_STEP_S = 4.0;  % response logged after the step
SAMPLE_HZ = 100;

durationS = PRE_STEP_S + POST_STEP_S;
t = tcpclient(boardIP, port, "Timeout", durationS + 15);
configureTerminator(t, "LF");

writeline(t, "*IDN?");
disp("IDN: " + readline(t));

% Configure & enable the control loop, then let it physically settle at
% the starting target BEFORE the timed capture begins -- otherwise the
% initial settle transient would contaminate the "before" baseline.
ctrlParams = struct("kp", KP, "ki", KI, "kd", KD, "targetDeg", TARGET_BEFORE_DEG, ...
                     "outLimitDeg", OUT_LIMIT_DEG, "enabled", true);
writeline(t, "CTRLCONFIG");
writeline(t, jsonencode(ctrlParams));
disp("CTRLCONFIG: " + strtrim(readline(t)));
pause(2);

runParams = struct("durationS", durationS, "sampleHz", SAMPLE_HZ);
writeline(t, "RUN");
writeline(t, jsonencode(runParams));
disp("Run result: " + strtrim(readline(t))); % "OK" immediately -- capture continues in the background

pause(PRE_STEP_S);
writeline(t, "CTRLCONFIG");
writeline(t, jsonencode(struct("targetDeg", TARGET_AFTER_DEG)));
disp("Step applied: " + strtrim(readline(t)));

% Poll until the background capture finishes.
while true
    writeline(t, "STATUS?");
    status = strtrim(readline(t));
    if startsWith(status, "DONE")
        break
    end
    pause(0.2);
end
disp("Status: " + status);

data = readHastaDaqData(t);
clear t % close the TCP connection

figure("Name", "Elevator control step response");

subplot(2, 1, 1);
plot(data.t_ms / 1000, data.encoderDeg, "DisplayName", "encoder (measured)");
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
plot(data.t_ms / 1000, data.controlOutputDeg);
xlabel("t (s)"); ylabel("control output (deg)");
title("PID output (pre-mix, before excGain/ctrlGain scaling)");
grid on;
