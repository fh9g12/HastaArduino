function [commandedDeg, encoderDeg] = stepAndHold(t, setpoints, settleS)
% STEPANDHOLD Moves to each setpoint in turn, waits settleS for it to
% physically arrive, then reads the encoder -- one (commanded, encoder)
% pair per setpoint, in the given order. Uses only POS/ANGLE?, identical
% on PWM and SBUS boards.
    commandedDeg = setpoints;
    encoderDeg = zeros(size(setpoints));
    for i = 1:numel(setpoints)
        writeline(t, sprintf("POS %.3f", setpoints(i)));
        readline(t); % "OK"
        pause(settleS);
        writeline(t, "ANGLE?");
        encoderDeg(i) = str2double(strtrim(readline(t)));
    end
end
