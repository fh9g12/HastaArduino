% stepperSpinTest.m
%
% Bench check for the EncoderCalibration rig: spins the stepper at a
% constant commanded speed via RUN, logging (t, commanded, encoder) at
% 20Hz for the run's duration, then plots both. Same RUN/DATA? pattern as
% ../pwm/servoCalibrationTest.m and ../sbus/servoCalibrationTest.m --
% see EncoderCalibration.ino's header comment for the wire protocol.
%
% Get boardIP from the Serial Monitor at boot ("[WiFi] Connected, IP=...").

addpath(fullfile(fileparts(mfilename("fullpath")), "..", "common"));

boardIP = "192.168.68.107";  % <-- set to your board's actual IP
port = 5025;

SPEED_DEG_PER_S = 90; % moderate -- 4s per revolution at full step, more at
                       % microstepping; enough to clearly see it turning
SPIN_DURATION_S = 5;
SAMPLE_HZ = 20;

% RUN blocks the connection for the full run duration, so the tcpclient
% timeout has to comfortably exceed that.
t = connectServo(boardIP, port, 30);

runParams = struct("speedDegPerS", SPEED_DEG_PER_S, "durationS", SPIN_DURATION_S, "sampleHz", SAMPLE_HZ);
writeline(t, "RUN");
writeline(t, jsonencode(runParams));
disp("Run result: " + strtrim(readline(t)));  % "OK <n_samples>"

[t_ms, targetDeg, encoderDeg] = readServoData(t);
clear t % close the TCP connection

movedDeg = encoderDeg(end) - encoderDeg(1);
expectedDeg = SPEED_DEG_PER_S * SPIN_DURATION_S;
fprintf("Encoder saw %.1f deg of motion (commanded %.1f deg).\n", movedDeg, expectedDeg);

if abs(movedDeg) < 0.5 * abs(expectedDeg)
    warning("Encoder barely moved despite commanding the stepper to spin -- " + ...
        "check wiring (motor coils, STEP/DIR pins, motor power/common ground) " + ...
        "before trusting anything further.");
else
    disp("Looks like it's spinning and the encoder is tracking it.");
end

figure;
subplot(2, 1, 1);
plot(t_ms, targetDeg, t_ms, encoderDeg);
xlabel("t (ms)"); ylabel("deg");
legend("motor (commanded)", "encoder", "Location", "best");
title("Stepper spin test: motor vs encoder angle over time");

subplot(2, 1, 2);
plot(targetDeg, encoderDeg, ".");
xlabel("commanded deg"); ylabel("encoder deg");
title("Commanded vs actual angle");
axis equal;
