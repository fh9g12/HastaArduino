% example_moveServos.m
%
% Move individual control surfaces to set angles. Angles are centred on 0
% (travel +/-90 deg); each channel's commanded angle is
%   trimDeg + excGain*excitation + ctrlGain*controlOutput
% so for a plain static move we set trimDeg and make sure the other two
% terms are off.
%
% THIS MOVES THE CONTROL SURFACES. Make sure they are clear, and start
% with small angles. Positive/negative direction depends on how each servo
% is mounted - left/right surfaces may need opposite signs.

CONFIRMED_AREA_CLEAR = false;  % <-- set true once the surfaces are clear
assert(CONFIRMED_AREA_CLEAR, "Set CONFIRMED_AREA_CLEAR = true once the surfaces are clear to move.");

boardIP = "192.168.68.107";  % <-- set to your board's actual IP

hd = HastaDaqClient(boardIP);

% Make sure nothing else is driving the surfaces: PID off, no excitation
% armed, and no excitation/control mixed into any channel.
hd.disableControl();
hd.disarmExcitation();
for ch = enumeration("HastaDaqChannel")'
    hd.setChannel(ch, excGain=0, ctrlGain=0, trimDeg=0);
end
pause(1);

% Rudder out to +10, then -10, then back to centre.
hd.setChannel(HastaDaqChannel.Rudder, trimDeg=10);   pause(1.5);
hd.setChannel(HastaDaqChannel.Rudder, trimDeg=-10);  pause(1.5);
hd.setChannel(HastaDaqChannel.Rudder, trimDeg=0);    pause(1.5);

% Both elevators together by +5 (flip one sign if your servos are mirrored).
hd.setChannel(HastaDaqChannel.ElevL, trimDeg=5);
hd.setChannel(HastaDaqChannel.ElevR, trimDeg=5);
pause(1.5);

% Ailerons differentially: left up, right down.
hd.setChannel(HastaDaqChannel.AilL, trimDeg=5);
hd.setChannel(HastaDaqChannel.AilR, trimDeg=-5);
pause(1.5);

% Back to centre.
for ch = enumeration("HastaDaqChannel")'
    hd.setChannel(ch, trimDeg=0);
end
disp("Done - all surfaces returned to 0.");

clear hd % closes the TCP connection (surfaces hold their last command)
