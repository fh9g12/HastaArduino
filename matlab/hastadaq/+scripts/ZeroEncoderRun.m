% ZeroEncoderRun: zero the pitch encoder and save the zero for later runs.
%
% Do this when the rig is first set up, or whenever the encoder or its
% magnet has been moved or re-seated:
%   1. put the model at its zero position by hand
%   2. set CONFIRMED_MODEL_AT_ZERO = true below and run this
%
% It zeroes the encoder on the board, reads back the raw encoder angle that
% now reads as 0, and saves it as a MATLAB preference (wt.hasta.encoderZero).
% ZeroRun and the sweeps then just SEND that saved offset to the board,
% instead of zeroing again: the board forgets its zero whenever it restarts,
% but the encoder is absolute, so the same offset puts the zero back.
%
% No data is recorded and the run number is untouched.

CONFIRMED_MODEL_AT_ZERO = true;  % <-- set true once the model is at its zero position
assert(CONFIRMED_MODEL_AT_ZERO, ...
    "Put the model at its zero position, then set CONFIRMED_MODEL_AT_ZERO = true.");

% not sending the saved zero: this script is what sets it
hd = wt.hasta.setupTestEnvironment(SendEncoderZero=false);

%% zero the encoder and save the offset
hd.disableControl();   % ZERO is refused while the PID is enabled
previous = wt.hasta.encoderZero.info();

hd.zeroEncoder();
offsetDeg = hd.getEncoderZeroOffset();
encoderDeg = hd.getEncoderDeg();
assert(abs(encoderDeg) < 0.1, "The encoder reads %.3f deg right after zeroing - try again.", encoderDeg);

wt.hasta.encoderZero.set(offsetDeg);

fprintf("Encoder zeroed. Raw angle at zero: %.4f deg (saved as the encoder zero preference).\n", offsetDeg);
if ~isempty(previous)
    change = mod(offsetDeg - previous.OffsetDeg + 180, 360) - 180;
    fprintf("Previous saved zero: %.4f deg (saved %s); this one differs by %+.4f deg.\n", ...
        previous.OffsetDeg, previous.SavedAt, change);
    if abs(change) > 0.5
        warning("ZeroEncoderRun:moved", ...
            "The zero has moved by %.2f deg since it was last saved: the encoder, its magnet, or the model's zero position has changed.", change);
    end
end
