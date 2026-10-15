% zero.m
%
% How the encoder zero works. Position the model where you want "0" BEFORE
% running this. Doesn't move anything.
%
% hd.zeroEncoder() makes the encoder's current position the new 0, but only
% in RAM on the board: it is lost on every reboot or reflash. The encoder is
% absolute, though, so the zero can be described by one number - the raw
% encoder angle that reads as 0 - and sent back later with
% hd.setEncoderZeroOffset(offset), without moving the model to zero again.
%
% This script only shows the calls on the board; it does NOT change the zero
% saved for the test scripts. To do that, put the model at zero and run
% scripts.ZeroEncoderRun: it zeroes, reads the offset and saves it as a
% MATLAB preference (wt.hasta.encoderZero) that ZeroRun, the sweeps and the
% free-pitch tests then send to the board.
%
% The board's address is a default of wt.hasta.setupTestEnvironment (see the
% Serial Monitor at boot, "[WiFi] Connected, IP=...", if it changes).

hd = wt.hasta.setupTestEnvironment(SendEncoderZero=false);   % the connection is kept for the next script

% ZERO (and the offset) are refused while the control loop is enabled
% (zeroing under it would step the PID error and make the elevators jump).
hd.disableControl();

fprintf("Encoder before zero: %.3f deg\n", hd.getEncoderDeg());
hd.zeroEncoder();
fprintf("Encoder after zero:  %.3f deg\n", hd.getEncoderDeg());

% the raw encoder angle that now reads as 0: this is the number to keep
offsetDeg = hd.getEncoderZeroOffset();
fprintf("Raw encoder angle at zero: %.4f deg\n", offsetDeg);

% putting a saved zero back (what the test scripts do at start-up)
hd.setEncoderZeroOffset(offsetDeg);
fprintf("Encoder after sending that offset back: %.3f deg\n", hd.getEncoderDeg());

saved = wt.hasta.encoderZero.info();
if isempty(saved)
    fprintf("No zero is saved for the test scripts yet: run scripts.ZeroEncoderRun.\n");
else
    fprintf("The zero saved for the test scripts is %.4f deg (saved %s).\n", saved.OffsetDeg, saved.SavedAt);
end

% hd stays open for the next script (`clear hd` closes the link)
