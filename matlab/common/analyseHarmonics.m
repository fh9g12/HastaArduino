function [thdPercent, amplitudeRatio, measuredFreqHz] = analyseHarmonics(t_ms, encoderDeg, ...
        cycles, commandedAmplitudeDeg, numHarmonics)
% ANALYSEHARMONICS Finds the ACTUAL fundamental peak -- searching a wide
% band (0.5x-1.5x the commanded frequency) rather than just trusting the
% commanded value and tolerating only a couple of bins of slop, so a
% genuine frequency error shows up instead of being silently assumed away
% (a narrow "expected bin +/- jitter" search would either miss a real
% mistracked frequency, or accept it without ever reporting how far off it
% was). Harmonics are then found relative to that MEASURED fundamental,
% not the commanded frequency -- if the servo's real oscillation is at a
% slightly different frequency, its harmonics are integer multiples of
% that real frequency, not the commanded one.
%
% Assumes the run captured an exact integer number of `cycles` periods
% (SINE's contract), which puts the fundamental at FFT bin `cycles+1` --
% see the caller.
    [freqAxis, Yraw, n] = uniformFft(t_ms, encoderDeg);
    mag = toAmplitude(Yraw, n);

    nyquistBin = numel(freqAxis);
    expectedFundBin = round(cycles) + 1; % +1: MATLAB 1-indexing, bin 1 = DC

    searchLo = max(2, round(0.5 * (expectedFundBin - 1)) + 1);
    searchHi = min(nyquistBin, round(1.5 * (expectedFundBin - 1)) + 1);
    [fundamentalAmp, relIdx] = max(mag(searchLo:searchHi));
    fundBin = searchLo + relIdx - 1;
    measuredFreqHz = freqAxis(fundBin);

    binWindow = 2; % tolerate +/- this many bins of jitter around each harmonic
    harmonicAmp = zeros(1, numHarmonics);
    harmonicAmp(1) = fundamentalAmp;
    for h = 2:numHarmonics
        expectedBin = (fundBin - 1) * h + 1; % harmonic of the MEASURED fundamental
        loBin = max(2, expectedBin - binWindow);
        hiBin = min(nyquistBin, expectedBin + binWindow);
        if loBin > hiBin
            % This harmonic is above Nyquist for the achieved sample rate
            % (happens for high commanded frequencies * high harmonic
            % numbers) -- can't be measured, not evidence it's absent.
            % Treat as zero rather than erroring on an empty index range.
            harmonicAmp(h) = 0;
            continue;
        end
        harmonicAmp(h) = max(mag(loBin:hiBin));
    end

    thdPercent = 100 * sqrt(sum(harmonicAmp(2:end) .^ 2)) / fundamentalAmp;
    amplitudeRatio = fundamentalAmp / commandedAmplitudeDeg;
end
