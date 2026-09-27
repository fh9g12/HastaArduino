function sendConfig(t, configParams)
% SENDCONFIG Sends a CONFIG command with the given JSON body and prints
% the reply. The CONFIG mechanics (two-line JSON, "OK"/"ERR ..." reply)
% are identical between PWM and SBUS boards -- only the field names in
% configParams differ (carrierHz/pulseMinUs/pulseMaxUs for PWM vs
% chMin/chMax/broadcast/channel/fast/updateHz for SBUS), which is exactly
% why this takes a plain struct rather than named parameters.
%
% sendConfig(t, configParams)
    writeline(t, "CONFIG");
    writeline(t, jsonencode(configParams));
    disp("Config result: " + strtrim(readline(t)));
end
