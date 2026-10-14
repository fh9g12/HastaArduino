% sinewave.m
%
% Drive both elevators with a fixed-frequency sine for a set number of
% cycles while logging, then plot the command and the encoder response.
%
% Same mechanism as chirp.m: EXCITE configures the shared
% waveform, each channel's excGain says how much of it that channel
% follows, and a capture (RUN) records plus starts the armed waveform
% (after delayS).
%
% For the same thing with the model free to pitch, held by the controller
% first, see freePitchSine.
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

elevators = [wt.hasta.HDCh.ElevL wt.hasta.HDCh.ElevR];

% the board takes one client at a time, so reuse an existing connection
if ~exist("hd","var") || ~isvalid(hd)
    hd = wt.hasta.DaqClient(boardIP);
end

hd.disableControl(); % pure open-loop excitation
% every surface at 0 with nothing mixed in, then the elevators follow the sine
hd.setMix(enumeration("wt.hasta.HDCh")', trimDeg=0, excGain=0, ctrlGain=0);
hd.setMix(elevators, excGain=1);       % one command, so the elevators change together

% cycles=CYCLES -> runs that many periods, then stops by itself
% (cycles=0 would run until disarmed).
hd.setExcitation("sine", freqHz=FREQ_HZ, amplitudeDeg=AMPLITUDE_DEG, ...
                 cycles=CYCLES, delayS=DELAY_S, armed=true);
disp(hd.getExcitation());

durationS = DELAY_S + CYCLES / FREQ_HZ + TAIL_S;
fprintf("Capturing %.1f s ...\n", durationS);
data = hd.capture(durationS, SAMPLE_HZ);   % record, wait, read back

hd.disarmExcitation(); % don't let a later trigger start it again
clear hd

t = data.Time;
names = string(enumeration("wt.hasta.HDCh"));

figure("Name", "Sine wave");
subplot(3, 1, 1);
plot(t, data.ExcitationDeg); grid on;
ylabel("excitation (deg)"); title(sprintf("%.3g Hz sine, %d cycles", FREQ_HZ, CYCLES));

subplot(3, 1, 2);
plot(t, data.ServoAngles); grid on; legend(names, "Location", "best");
ylabel("servo command (deg)");

subplot(3, 1, 3);
plot(t, data.EncoderDeg); grid on;
xlabel("t (s)"); ylabel("encoder (deg)");
