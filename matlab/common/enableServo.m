function enableServo(t)
% ENABLESERVO Sends "ENABLE 1" and prints the reply. Identical on both
% board types.
    writeline(t, "ENABLE 1");
    disp(readline(t));
end
