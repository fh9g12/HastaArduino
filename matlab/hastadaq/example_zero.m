% example_zero.m
%
% Zero the encoder at its current position. Position the surface/rig where
% you want "0" BEFORE running this. Doesn't move anything.
%
% The zero is a software offset held in RAM on the board: it is lost on
% every reboot or reflash, so run this after each power-up.
%
% Get boardIP from the Serial Monitor at boot ("[WiFi] Connected, IP=...").

boardIP = "192.168.68.107";  % <-- set to your board's actual IP

hd = HastaDaqClient(boardIP);

% ZERO is refused while the control loop is enabled (zeroing under it
% would step the PID error and make the elevators jump).
hd.disableControl();

fprintf("Encoder before zero: %.3f deg\n", hd.getEncoderDeg());
hd.zeroEncoder();
fprintf("Encoder after zero:  %.3f deg\n", hd.getEncoderDeg());

clear hd % closes the TCP connection
