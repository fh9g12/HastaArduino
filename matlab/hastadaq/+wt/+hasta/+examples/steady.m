% steady.m
%
% Hold both elevators at a fixed angle for N seconds while logging, and
% plot the result - the encoder, IMU and strain readings at a steady
% condition (e.g. for a static calibration point or a noise floor).
%
% setSteady moves the surfaces (setAngle), disarms any armed excitation so
% nothing oscillates, and waits SETTLE_S for the surfaces to get there.
% capture then records DURATION_S and returns the data. For a steady point
% you only want the average of, call data.mean() on the result.
%
% THIS MOVES THE ELEVATORS. Make sure they are clear.

CONFIRMED_AREA_CLEAR = false;  % <-- set true once the surfaces are clear
assert(CONFIRMED_AREA_CLEAR, "Set CONFIRMED_AREA_CLEAR = true once the surfaces are clear to move.");

boardIP = "192.168.68.107";  % <-- set to your board's actual IP

ANGLE_DEG = 3;       % elevator angle to hold
DURATION_S = 10;     % how long to log
SETTLE_S = 2;        % wait for the surfaces to reach the angle first
SAMPLE_HZ = 100;

elevators = [wt.hasta.HDCh.ElevL wt.hasta.HDCh.ElevR];

% the board takes one client at a time, so reuse an existing connection
if ~exist("hd","var") || ~isvalid(hd)
    hd = wt.hasta.DaqClient(boardIP);
end
hd.disableControl(); % pure open-loop hold

hd.setSteady(elevators, ANGLE_DEG, settleS=SETTLE_S);

fprintf("Capturing %.1f s ...\n", DURATION_S);
data = hd.capture(DURATION_S, SAMPLE_HZ);   % record, wait, read back

hd.setAngle(elevators, 0); % back to centre
clear hd

t = data.Time;
names = string(enumeration("wt.hasta.HDCh"));

figure("Name", "Steady test");
subplot(4, 1, 1);
plot(t, data.ServoAngles); grid on; legend(names, "Location", "best");
ylabel("servo command (deg)"); title(sprintf("Held at %.3g deg for %.3g s", ANGLE_DEG, DURATION_S));

subplot(4, 1, 2);
plot(t, data.EncoderDeg); grid on;
ylabel("encoder (deg)");

subplot(4, 1, 3);
plot(t, data.Adc1Mv); grid on;
ylabel("strain 1 (mV)");

subplot(4, 1, 4);
plot(t, data.Adc2Mv); grid on;
xlabel("t (s)"); ylabel("strain 2 (mV)");

linkaxes(findall(gcf, "Type", "axes"), "x");

fprintf("Mean encoder %.4f deg (std %.4f)\n", mean(data.EncoderDeg), std(data.EncoderDeg));
fprintf("Mean strain  %.4f mV (std %.4f) / %.4f mV (std %.4f)\n", ...
    mean(data.Adc1Mv), std(data.Adc1Mv), mean(data.Adc2Mv), std(data.Adc2Mv));
