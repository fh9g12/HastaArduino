% example_sinewave.m
%
% Drive both elevators with a fixed-frequency sine for a set number of
% cycles while logging, then plot the command and the encoder response.
%
% Same mechanism as example_chirp.m: EXCITE configures the shared
% waveform, each channel's excGain says how much of it that channel
% follows, and RUN starts a capture plus the armed waveform (after delayS).
%
% THIS MOVES THE ELEVATORS. Make sure they are clear.

CONFIRMED_AREA_CLEAR = false;  % <-- set true once the surfaces are clear
assert(CONFIRMED_AREA_CLEAR, "Set CONFIRMED_AREA_CLEAR = true once the surfaces are clear to move.");

boardIP = "192.168.68.107";  % <-- set to your board's actual IP

FREQ_HZ = 1;
AMPLITUDE_DEG = 3;
CYCLES = 5;
DELAY_S = 1;          % baseline logged before the sine starts
TAIL_S = 1;           % extra logging after it ends
SAMPLE_HZ = 100;

hd = HastaDaqClient(boardIP);

hd.disableControl(); % pure open-loop excitation
for ch = enumeration("HDCh")'
    hd.setChannel(ch, excGain=0, ctrlGain=0, trimDeg=0);
end
hd.setChannel(HDCh.ElevL, excGain=1);
hd.setChannel(HDCh.ElevR, excGain=1);

% cycles=CYCLES -> runs that many periods, then stops by itself
% (cycles=0 would run until disarmed).
hd.setExcitation("sine", freqHz=FREQ_HZ, amplitudeDeg=AMPLITUDE_DEG, ...
                 cycles=CYCLES, delayS=DELAY_S, armed=true);
disp(hd.getExcitation());

durationS = DELAY_S + CYCLES / FREQ_HZ + TAIL_S;
hd.run(durationS, SAMPLE_HZ);         % returns immediately
fprintf("Capturing %.1f s ...\n", durationS);
hd.waitForDone(durationS + 15);
data = hd.readData();

hd.disarmExcitation(); % don't let a later trigger start it again
clear hd

t = data.t_ms / 1000; t = t - t(1);
names = string(enumeration("HDCh"));

figure("Name", "Sine wave");
subplot(3, 1, 1);
plot(t, data.excitationDeg); grid on;
ylabel("excitation (deg)"); title(sprintf("%.3g Hz sine, %d cycles", FREQ_HZ, CYCLES));

subplot(3, 1, 2);
plot(t, data.servoDeg); grid on; legend(names, "Location", "best");
ylabel("servo command (deg)");

subplot(3, 1, 3);
plot(t, data.encoderDeg); grid on;
xlabel("t (s)"); ylabel("encoder (deg)");
