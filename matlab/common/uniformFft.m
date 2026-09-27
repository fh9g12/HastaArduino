function [f, Yraw, n] = uniformFft(t_ms, x)
% UNIFORMFFT Resamples x onto a uniform time grid (real sample timestamps
% have a little jitter -- SPI read + loop overhead each sample -- and FFT
% assumes uniform sampling), demeans it, and returns the single-sided
% complex FFT. Deliberately NOT amplitude-scaled here: a Bode ratio
% cancels any consistent scaling factor, and toAmplitude() applies it for
% the cases (magnitude plots) that need real degrees on the y-axis.
    t_s = t_ms / 1000;
    n = numel(t_s);
    fs = (n - 1) / (t_s(end) - t_s(1));
    tUniform = linspace(t_s(1), t_s(end), n);
    xUniform = interp1(t_s, x, tUniform, "linear");

    nHalf = floor(n / 2) + 1;
    Yfull = fft(xUniform - mean(xUniform));
    Yraw = Yfull(1:nHalf);
    f = fs * (0:nHalf - 1) / n;
end
