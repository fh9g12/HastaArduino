% chirp.m
%
% Excite both elevators with one chirp (frequency sweep f0 -> f1 over
% periodS) while logging the encoder, IMU and strain gauges, then plot.
%
% How it fits together: EXCITE configures one shared waveform; each
% channel's excGain (-1..1) sets how much of it that channel follows; a
% capture (RUN) starts recording AND triggers the armed waveform, which
% begins after delayS (so you log a quiet baseline first).
%
% For the same thing with the model free to pitch, held by the controller
% first, see freePitchChirp.
%
% THIS MOVES THE ELEVATORS. Make sure they are clear. Opposite excGain
% signs on the two elevators would drive them differentially instead.

CONFIRMED_AREA_CLEAR = true;  % <-- set true once the surfaces are clear
assert(CONFIRMED_AREA_CLEAR, "Set CONFIRMED_AREA_CLEAR = true once the surfaces are clear to move.");

boardIP = "192.168.1.107";  % <-- set to your board's actual IP

F0_HZ = 0.25;          % chirp start frequency
F1_HZ = 2;            % chirp end frequency
PERIOD_S = 15;        % sweep time
AMPLITUDE_DEG = 5;
DELAY_S = 1;          % baseline logged before the chirp starts
TAIL_S = 1;           % extra logging after it ends
SAMPLE_HZ = 100;

elevators = [wt.hasta.HDCh.ElevL wt.hasta.HDCh.ElevR];

% the board takes one client at a time, so reuse an existing connection
if ~exist("hd","var") || ~isvalid(hd)
    hd = wt.hasta.DaqClient(boardIP);
end

% Un-comment these to start from a clean slate: controller off, and every
% surface at 0 with no excitation or controller mixed in. (Left as they were
% so the surfaces keep whatever state an earlier script gave them.)
% hd.disableControl(); % pure open-loop excitation
% hd.setMix(enumeration("wt.hasta.HDCh")', trimDeg=0, excGain=0, ctrlGain=0);
hd.setMix(elevators, excGain=1);       % the elevators follow the chirp (one command, so together)

% cycles=1 -> run exactly one sweep, then stop by itself.
hd.setExcitation("chirp", f0=F0_HZ, f1=F1_HZ, periodS=PERIOD_S, ...
                 amplitudeDeg=AMPLITUDE_DEG, cycles=1, delayS=DELAY_S, armed=true);
disp(hd.getExcitation());

durationS = DELAY_S + PERIOD_S + TAIL_S;
fprintf("Capturing %.1f s ...\n", durationS);
data = hd.capture(durationS, SAMPLE_HZ);   % record, wait, read back

hd.disarmExcitation(); % don't let a later trigger start it again
clear hd

t = data.Time;
names = string(enumeration("wt.hasta.HDCh"));

figure("Name", "Chirp");
subplot(5, 1, 1);
plot(t, data.ExcitationDeg); grid on;
ylabel("excitation (deg)"); title("Chirp command");

subplot(5, 1, 2);
plot(t, data.ServoAngles); grid on; legend(names, "Location", "best");
ylabel("servo command (deg)");

subplot(5, 1, 3);
plot(t, data.EncoderDeg); grid on;
ylabel("encoder (deg)");

% Strain gauges: raw half-bridge ADC readings (mV) from the two ADS122C04s,
% one plot each so their different scales don't hide each other.
subplot(5, 1, 4);
plot(t, data.Adc1Mv); grid on;
ylabel("strain 1 (mV)");

subplot(5, 1, 5);
plot(t, data.Adc2Mv); grid on;
xlabel("t (s)"); ylabel("strain 2 (mV)");

linkaxes(findall(gcf, "Type", "axes"), "x"); % zoom/pan all five together
