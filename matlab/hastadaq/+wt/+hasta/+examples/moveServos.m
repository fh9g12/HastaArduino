% moveServos.m
%
% Move individual control surfaces to set angles. Angles are centred on 0
% (travel +/-48.06 deg); each channel's commanded angle is
%   trimDeg + excGain*excitation + ctrlGain*controlOutput
% so for a plain static move we set trimDeg and make sure the other two
% terms are off.
%
% THIS MOVES THE CONTROL SURFACES. Make sure they are clear, and start
% with small angles. Positive/negative direction depends on how each servo
% is mounted - left/right surfaces may need opposite signs.

CONFIRMED_AREA_CLEAR = false;  % <-- set true once the surfaces are clear
assert(CONFIRMED_AREA_CLEAR, "Set CONFIRMED_AREA_CLEAR = true once the surfaces are clear to move.");

boardIP = "192.168.1.107";  % <-- set to your board's actual IP

% the board takes one client at a time, so reuse an existing connection
if ~exist("hd","var") || ~isvalid(hd)
    hd = wt.hasta.DaqClient(boardIP);
end

% setAngle sets a channel's trim AND zeroes its excitation/control gains,
% so nothing else is added on top of the angle you ask for. Several surfaces
% in one call go out as ONE command, so they start moving together. We still
% turn the PID and any armed excitation off so nothing else is running.
hd.disableControl();
hd.disarmExcitation();
allSurfaces = enumeration("wt.hasta.HDCh")';
hd.setAngle(allSurfaces, 0);
pause(1);

% Rudder out to +10, then -10, then back to centre.
hd.setAngle(wt.hasta.HDCh.Rudder, 10);   pause(1.5);
hd.setAngle(wt.hasta.HDCh.Rudder, -10);  pause(1.5);
hd.setAngle(wt.hasta.HDCh.Rudder, 0);    pause(1.5);

% Both elevators together by +5 (flip one sign if your servos are mirrored).
hd.setAngle([wt.hasta.HDCh.ElevL wt.hasta.HDCh.ElevR], 5);
pause(1.5);

% Ailerons differentially: left +5, right -5 (one angle per surface).
hd.setAngle([wt.hasta.HDCh.AilL wt.hasta.HDCh.AilR], [5 -5]);
pause(1.5);

% Back to centre.
hd.setAngle(allSurfaces, 0);
disp("Done - all surfaces returned to 0.");

% hd stays open for the next script (surfaces hold their last command; `clear hd` closes the link)
