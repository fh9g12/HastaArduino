function t = connectServo(boardIP, port, timeoutS)
% CONNECTSERVO Opens the SCPI TCP connection and does the common
% first steps every test script needs: *IDN?, ZERO. Identical over
% PWM (ServoCalibration) and SBUS (SbusServoCalibration) boards -- both
% expose the same *IDN?/ZERO commands.
%
% t = connectServo(boardIP, port, timeoutS)
    t = tcpclient(boardIP, port, "Timeout", timeoutS);
    configureTerminator(t, "LF");

    writeline(t, "*IDN?");
    disp("IDN: " + readline(t));

    writeline(t, "ZERO"); % zero the encoder at whatever position it's currently at
    disp(readline(t));
end
