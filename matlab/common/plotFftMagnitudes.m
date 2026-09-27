function plotFftMagnitudes(results, compareBy)
% PLOTFFTMAGNITUDES Target FFT plotted once (dashed reference), encoder
% FFT overlaid per result. See plotTimeHistories for the results/compareBy
% shape.
    figure("Name", "FFT vs " + compareBy);
    colors = lines(numel(results));
    hold on;
    [fTarget, YtgtRaw, nTarget] = uniformFft(results(1).t_ms, results(1).targetDeg);
    plot(fTarget, toAmplitude(YtgtRaw, nTarget), "k--");
    legendEntries = strings(1, numel(results) + 1);
    legendEntries(1) = "target";
    for i = 1:numel(results)
        [fEnc, YencRaw, nEnc] = uniformFft(results(i).t_ms, results(i).encoderDeg);
        plot(fEnc, toAmplitude(YencRaw, nEnc), "Color", colors(i, :));
        legendEntries(i + 1) = results(i).label;
    end
    hold off;
    xlabel("frequency (Hz)"); ylabel("magnitude (deg)");
    xlim([0, 35]);
    title("FFT magnitude: encoder response vs " + compareBy);
    legend(legendEntries, "Location", "best");
    grid on;
end
