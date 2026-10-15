% testPxi.m
%
% Checks the PXI force sensor and its trigger line, one step at a time, with
% nothing moving. Run it before using USE_PXI / UsePxi in any other script.
%
%   1. PXI alone (the board is not needed): records DURATION_S seconds and
%      checks the trigger output loops back into the input at ~3.3 V, the
%      rising edge is found, the six gauge voltages are sane and quiet, and
%      shows the calibrated loads. Plots everything.
%   2. PXI + board: arms the board to start on the trigger input, records on
%      the PXI and checks the board's capture was started by the edge. If it
%      was not, it says what to check (the wire from the NI analogue output
%      AO0 to the board's trigger-in pin GP14, a common ground, the rising
%      edge setting, the pull-down) and fires the board by hand to clear it.
%
% Nothing is saved. To check the channel ORDER, load the sensor in a known
% direction while step 1 runs (press or hang a weight on it) and see which
% load moves in the plot: Fx, Fy, Fz, then Tx, Ty, Tz.
%
% Excitation is disarmed first, so the board cannot move any surface.

PXI_CARD = "PXI1Slot4_2";     % <-- the NI card with the analogue outputs (the PXIe-6363 in daqlist)
PXI_RATE_HZ = 200;
USE_CAMERA = false;           % true: also pulse the tracking camera around the PXI record
DURATION_S = 3;               % how long each test record is
TEST_BOARD = true;            % false: only test the PXI by itself
SAMPLE_HZ = 100;              % the board's sample rate for step 2

%% 1. the PXI by itself
fprintf("1. PXI alone: %s at %g Hz, %g s ...\n", PXI_CARD, PXI_RATE_HZ, DURATION_S);
pxi = wt.pxi.ForceDaq(PXI_CARD, rate=PXI_RATE_HZ);
pxi.lowOutput();
force = pxi.acquire(DURATION_S, camera=USE_CAMERA);

okTrigger = max(force.TriggerVolts) > 3 && min(force.TriggerVolts) < 0.5;
fprintf("  samples %d at %g Hz\n", force.NumSamples, force.Rate);
fprintf("  trigger loopback: %.2f V high, %.2f V low (expect ~%.1f V and ~0 V) -> %s\n", ...
    max(force.TriggerVolts), min(force.TriggerVolts), pxi.TriggerVolts, passText(okTrigger));
if isnan(force.TriggerIndex)
    fprintf("  rising edge: NOT FOUND -> FAIL (is AO0 looped back to ai6?)\n");
else
    fprintf("  rising edge at sample %d (%.3f s from the start; lead-in is %.3f s) -> PASS\n", ...
        force.TriggerIndex, force.Time(force.TriggerIndex), pxi.LeadInS);
end

quiet = std(force.Gauges, 0, 1) * 1e3;          % mV
level = mean(force.Gauges, 1);                  % V
fprintf("  gauge mean (V):  %s\n", mat2str(round(level, 4)));
fprintf("  gauge noise (mV): %s\n", mat2str(round(quiet, 3)));
if any(abs(level) > 9.5)
    fprintf("  !!! a gauge is near the +/-10 V limit: check the wiring and the input range\n");
end
loads = mean(force.mean().Forces(), 1);
fprintf("  mean loads (no tare): F = [%.2f %.2f %.2f] N, M = [%.3f %.3f %.3f] N.m\n", loads);

wt.pxi.plotForces(force, "PXI test: calibrated loads (untared)");
figure("Name", "PXI test: raw channels");
subplot(2, 1, 1);
plot(force.Time, force.Gauges); grid on; ylabel("gauges (V)");
legend("G0", "G1", "G2", "G3", "G4", "G5", "Location", "best");
subplot(2, 1, 2);
plot(force.Time, force.TriggerVolts); grid on; ylabel("trigger loopback (V)"); xlabel("t (s)");
linkaxes(findall(gcf, "Type", "axes"), "x");

%% 2. the PXI starting the board
if ~TEST_BOARD
    return
end
hd = wt.hasta.setupTestEnvironment(SendEncoderZero=false);
fprintf("\n2. PXI + board at %s ...\n", hd.BoardIP);
hd.disarmExcitation();                                    % nothing may move
forceDaq = wt.pxi.connect(hd, PXI_CARD, PXI_RATE_HZ);     % trigger low, board set to a rising edge
fprintf("  board trigger settings: %s\n", jsonencode(hd.getTrigger()));

hd.arm(DURATION_S, SAMPLE_HZ);
fprintf("  board armed; PXI recording %g s ...\n", DURATION_S);
pxiRecord = forceDaq.acquire(DURATION_S);

% give the board a moment to finish; do NOT wait the full timeout if it never started
t0 = tic;
status = hd.getStatus();
while status.state ~= "DONE" && toc(t0) < 3
    pause(0.2);
    status = hd.getStatus();
end
if status.state == "ARMED"
    fprintf("  board never started: FAIL. The trigger edge did not reach it. Check:\n");
    fprintf("    - the wire from the NI AO0 pin to the board's trigger-in (GP14), and a common ground\n");
    fprintf("    - that you have the right card/pin: the PXI's own test above saw ~%.1f V on its loopback\n", max(pxiRecord.TriggerVolts));
    fprintf("    - the board's trigger edge setting (rising) and that its trigger-in has a pull-down\n");
    hd.fire();                                    % clear the armed state (excitation is disarmed, nothing moves)
    hd.waitForDone(DURATION_S + 5);
    fprintf("  (board fired by hand to clear it)\n");
else
    hd.waitForDone(DURATION_S + 30);
    boardData = hd.readData();
    fprintf("  board capture started by the PXI edge: PASS (%d samples at %g Hz, expected %d)\n", ...
        boardData.NumSamples, SAMPLE_HZ, round(DURATION_S * SAMPLE_HZ));
    fprintf("  PXI record: %d samples, edge at sample %d\n", pxiRecord.NumSamples, pxiRecord.TriggerIndex);
end


%% local functions (must be at the end of a script)
function str = passText(ok)
    str = "FAIL";
    if ok
        str = "PASS";
    end
end
