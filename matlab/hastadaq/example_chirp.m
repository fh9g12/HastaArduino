% example_chirp.m
%
% Excite both elevators with one chirp (frequency sweep f0 -> f1 over
% periodS) while logging the encoder, IMU and strain gauges, then plot.
%
% How it fits together: EXCITE configures one shared waveform; each
% channel's excGain (-1..1) sets how much of it that channel follows; RUN
% starts a capture AND triggers the armed waveform, which begins after
% delayS (so you log a quiet baseline first).
%
% THIS MOVES THE ELEVATORS. Make sure they are clear. Opposite excGain
% signs on the two elevators would drive them differentially instead.

CONFIRMED_AREA_CLEAR = true;  % <-- set true once the surfaces are clear
assert(CONFIRMED_AREA_CLEAR, "Set CONFIRMED_AREA_CLEAR = true once the surfaces are clear to move.");

boardIP = "192.168.1.107";  % <-- set to your board's actual IP

F0_HZ = 0.5;          % chirp start frequency
F1_HZ = 5;            % chirp end frequency
PERIOD_S = 15;        % sweep time
AMPLITUDE_DEG = 3;
DELAY_S = 1;          % baseline logged before the chirp starts
TAIL_S = 1;           % extra logging after it ends
SAMPLE_HZ = 100;

hd = HastaDaqClient(boardIP);

hd.disableControl(); % pure open-loop excitation
for ch = enumeration("HDCh")'
    hd.setChannel(ch, excGain=0, ctrlGain=0, trimDeg=0);
end
hd.setChannel(HDCh.ElevL, excGain=1);
hd.setChannel(HDCh.ElevR, excGain=1);

% cycles=1 -> run exactly one sweep, then stop by itself.
hd.setExcitation("chirp", f0=F0_HZ, f1=F1_HZ, periodS=PERIOD_S, ...
                 amplitudeDeg=AMPLITUDE_DEG, cycles=1, delayS=DELAY_S, armed=true);
disp(hd.getExcitation());

durationS = DELAY_S + PERIOD_S + TAIL_S;
hd.run(durationS, SAMPLE_HZ);         % returns immediately
fprintf("Capturing %.1f s ...\n", durationS);
hd.waitForDone(durationS + 15);
data = hd.readData();

hd.disarmExcitation(); % don't let a later trigger start it again
clear hd

t = data.t_ms / 1000; t = t - t(1);
names = string(enumeration("HDCh"));

figure("Name", "Chirp");
subplot(5, 1, 1);
plot(t, data.excitationDeg); grid on;
ylabel("excitation (deg)"); title("Chirp command");

subplot(5, 1, 2);
plot(t, data.servoDeg); grid on; legend(names, "Location", "best");
ylabel("servo command (deg)");

subplot(5, 1, 3);
plot(t, data.encoderDeg); grid on;
ylabel("encoder (deg)");

% Strain gauges: raw half-bridge ADC readings (mV) from the two ADS122C04s,
% one plot each so their different scales don't hide each other.
subplot(5, 1, 4);
plot(t, data.adc1Mv); grid on;
ylabel("strain 1 (mV)");

subplot(5, 1, 5);
plot(t, data.adc2Mv); grid on;
xlabel("t (s)"); ylabel("strain 2 (mV)");

linkaxes(findall(gcf, "Type", "axes"), "x"); % zoom/pan all five together
