function offsetDeg = get()
% WT.HASTA.ENCODERZERO.GET The saved pitch-encoder zero offset (degrees).
%   offsetDeg = wt.hasta.encoderZero.get()
%
%   Send it to the board with hd.setEncoderZeroOffset(offsetDeg) instead
%   of zeroing again. Errors if no zero has been saved yet: run
%   scripts.ZeroEncoderRun (model at its zero position) first.
    saved = wt.hasta.encoderZero.info();
    if isempty(saved)
        error("wt:hasta:encoderZero:notSet", ...
            "No encoder zero has been saved yet. With the model at its zero position, run scripts.ZeroEncoderRun.");
    end
    offsetDeg = saved.OffsetDeg;
end
