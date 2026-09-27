function mag = toAmplitude(Yraw, n)
% TOAMPLITUDE Standard single-sided amplitude spectrum scaling (same
% units as the original signal), applied to uniformFft()'s raw output.
    mag = abs(Yraw) / n;
    mag(2:end - 1) = 2 * mag(2:end - 1);
end
