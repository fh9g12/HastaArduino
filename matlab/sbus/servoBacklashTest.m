% servoBacklashTest.m (SBUS)
%
% SBUS mirror of ../pwm/servoBacklashTest.m -- identical procedure (only
% POS/ANGLE? are used, same on both boards), just SBUS's own CONFIG
% fields. See that file for the full rationale on what this test isolates
% (static/mechanical hysteresis vs dynamic follower lag) and what it can't
% (gearbox backlash vs encoder hysteresis specifically).
%
% Two runs:
%   1. Coarse, full range: 0:10:180 then back down.
%   2. Fine, narrow range: 88:0.25:92 then back down -- backlash "dead
%      zone" shape.

addpath(fullfile(fileparts(mfilename("fullpath")), "..", "common"));

boardIP = "192.168.1.50";  % <-- set to your board's actual IP
port = 5025;

SETTLE_S = 0.5; % time to let the servo/encoder settle after each POS before reading ANGLE?

t = connectServo(boardIP, port, 30);
% 0-2047 (full 11-bit range) confirmed empirically as this servo's real
% usable range (128deg) -- NEVER use 2048 (truncates to 0 on the wire).
sendConfig(t, struct("chMin", 0, "chMax", 2047, "broadcast", true, ...
                      "fast", false, "updateHz", 100));
enableServo(t);

% --- coarse, full range ---
[coarseUpCmd, coarseUpEnc] = stepAndHold(t, 0:10:180, SETTLE_S);
[coarseDownCmd, coarseDownEnc] = stepAndHold(t, 170:-10:0, SETTLE_S);
plotHysteresisLoop(coarseUpCmd, coarseUpEnc, coarseDownCmd, coarseDownEnc, ...
    "SBUS coarse hysteresis loop (0-180deg)");

% --- fine, narrow range -- backlash "dead zone" shape ---
[fineUpCmd, fineUpEnc] = stepAndHold(t, 88:0.25:92, SETTLE_S);
[fineDownCmd, fineDownEnc] = stepAndHold(t, 91.75:-0.25:88, SETTLE_S);
plotHysteresisLoop(fineUpCmd, fineUpEnc, fineDownCmd, fineDownEnc, ...
    "SBUS fine backlash characterisation (88-92deg)");

clear t % close the TCP connection
