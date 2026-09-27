function plotHysteresisLoop(upCmd, upEnc, downCmd, downEnc, titleStr)
% PLOTHYSTERESISLOOP Plots the increasing/decreasing traces overlaid and
% reports the mean/max hysteresis gap (decreasing-direction encoder angle
% interpolated onto the increasing-direction's commanded-angle grid, then
% differenced).
    figure;
    plot(upCmd, upEnc, "-o", downCmd, downEnc, "-o");
    xlabel("commanded deg"); ylabel("encoder deg");
    title(titleStr);
    legend("increasing", "decreasing", "Location", "southeast");
    grid on;

    downEncOnUpGrid = interp1(downCmd, downEnc, upCmd, "linear", NaN);
    gapDeg = downEncOnUpGrid - upEnc;
    fprintf("%s: mean hysteresis %.3f deg, max %.3f deg\n", ...
        titleStr, mean(gapDeg, "omitnan"), max(abs(gapDeg), [], "omitnan"));
end
