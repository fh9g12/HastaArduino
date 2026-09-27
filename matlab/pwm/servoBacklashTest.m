% servoBacklashTest.m (PWM)
%
% Step-and-settle setpoint test to characterise the ~3deg hysteresis loop
% seen during continuous SWEEP runs. Unlike SWEEP (which logs WHILE
% moving), this moves to each setpoint, waits for it to physically settle,
% THEN reads the encoder -- so any hysteresis seen here can't be caused by
% dynamic follower/tracking lag (that only exists while actively moving).
% If this static test still shows the ~3deg loop, that points to genuine
% mechanical/encoder hysteresis (gearbox backlash or encoder measurement
% hysteresis); if it's smaller than what SWEEP showed, some of that 3deg
% was dynamic tracking lag rather than a static positional effect. This
% test can't further separate gearbox backlash from encoder hysteresis
% specifically -- both would show up identically here; that needs an
% independent position reference (e.g. a second sensor, or a dial
% indicator on the shaft). See ../sbus/servoBacklashTest.m for the SBUS
% mirror (same procedure -- only POS/ANGLE? are used, identical on both).
%
% Two runs:
%   1. Coarse, full range: 0:10:180 then back down -- overall shape of
%      the hysteresis loop across the servo's whole travel.
%   2. Fine, narrow range: 88:0.25:92 then back down -- zoomed in on one
%      spot to directly characterise the backlash "dead zone" size/shape.

addpath(fullfile(fileparts(mfilename("fullpath")), "..", "common"));

boardIP = "192.168.68.112";  % <-- set to your board's actual IP
port = 5025;

SETTLE_S = 0.5; % time to let the servo/encoder settle after each POS before reading ANGLE?

t = connectServo(boardIP, port, 30);
sendConfig(t, struct("carrierHz", 400, "pulseMinUs", 850, "pulseMaxUs", 2200));
enableServo(t);

% --- coarse, full range ---
[coarseUpCmd, coarseUpEnc] = stepAndHold(t, 0:10:180, SETTLE_S);
[coarseDownCmd, coarseDownEnc] = stepAndHold(t, 170:-10:0, SETTLE_S);
plotHysteresisLoop(coarseUpCmd, coarseUpEnc, coarseDownCmd, coarseDownEnc, ...
    "Coarse hysteresis loop (0-180deg)");

% --- fine, narrow range -- backlash "dead zone" shape ---
[fineUpCmd, fineUpEnc] = stepAndHold(t, 88:0.25:92, SETTLE_S);
[fineDownCmd, fineDownEnc] = stepAndHold(t, 91.75:-0.25:88, SETTLE_S);
plotHysteresisLoop(fineUpCmd, fineUpEnc, fineDownCmd, fineDownEnc, ...
    "Fine backlash characterisation (88-92deg)");

clear t % close the TCP connection
