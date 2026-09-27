function plotBodePlots(results, compareBy)
% PLOTBODEPLOTS Transfer function estimate H(f) = FFT(encoder)/FFT(target)
% per result, overlaid. Plain FFT-ratio estimate, not a windowed/averaged
% one (no Signal Processing Toolbox tfestimate/etc, matching the rest of
% this project's no-toolbox-required scripts) -- bins where the excitation
% itself has little energy are masked to NaN rather than plotted, since
% dividing by a near-zero input spectrum there would otherwise produce
% spurious gain spikes that swamp the genuinely informative part of the
% curve. See plotTimeHistories for the results/compareBy shape.
    figure("Name", "Bode vs " + compareBy);
    colors = lines(numel(results));
    legendEntries = strings(1, numel(results));

    subplot(2, 1, 1); hold on;
    subplot(2, 1, 2); hold on;

    for i = 1:numel(results)
        [f, Ytgt] = uniformFft(results(i).t_ms, results(i).targetDeg);
        [~, Yenc] = uniformFft(results(i).t_ms, results(i).encoderDeg);

        minEnergy = 0.05 * max(abs(Ytgt));
        valid = abs(Ytgt) > minEnergy;
        H = NaN(size(f));
        H(valid) = Yenc(valid) ./ Ytgt(valid);

        gainDb = 20 * log10(abs(H));
        phaseDeg = unwrap(angle(H)) * 180 / pi;

        subplot(2, 1, 1);
        semilogx(f, gainDb, "Color", colors(i, :));
        subplot(2, 1, 2);
        semilogx(f, phaseDeg, "Color", colors(i, :));

        legendEntries(i) = results(i).label;
    end

    subplot(2, 1, 1);
    hold off;
    xlabel("frequency (Hz)"); ylabel("gain (dB)");
    xlim([0.1, 30]);
    title("Bode: gain vs " + compareBy);
    legend(legendEntries, "Location", "best");
    grid on;

    subplot(2, 1, 2);
    hold off;
    xlabel("frequency (Hz)"); ylabel("phase (deg)");
    xlim([0.1, 30]);
    ylim([0, 200]);
    legend(legendEntries, "Location", "best");
    grid on;
end
