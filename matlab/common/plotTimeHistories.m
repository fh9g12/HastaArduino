function plotTimeHistories(results, compareBy)
% PLOTTIMEHISTORIES Target plotted once (dashed reference -- same
% commanded chirp/sine every run), encoder response overlaid per result.
% results: struct array with fields label (string), t_ms, targetDeg,
% encoderDeg. compareBy: short phrase for titles, e.g. "carrier frequency"
% or "update rate".
    figure("Name", "Time history vs " + compareBy);
    colors = lines(numel(results));
    hold on;
    plot(results(1).t_ms / 1000, results(1).targetDeg, "k--");
    legendEntries = strings(1, numel(results) + 1);
    legendEntries(1) = "target";
    for i = 1:numel(results)
        plot(results(i).t_ms / 1000, results(i).encoderDeg, "Color", colors(i, :));
        legendEntries(i + 1) = results(i).label;
    end
    hold off;
    xlabel("t (s)"); ylabel("deg");
    title("Time history: encoder response vs " + compareBy);
    legend(legendEntries, "Location", "best");
    grid on;
end
