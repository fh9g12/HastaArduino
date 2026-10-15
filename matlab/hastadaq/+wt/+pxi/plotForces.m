function fig = plotForces(pxiData, titleText, biasVolts)
%PLOTFORCES Plot the six calibrated loads of a force record against time.
%   wt.pxi.plotForces(pxiData, "Step response")
%   wt.pxi.plotForces(pxiData, "Step response", zeroData.mean().Gauges)
%   Time is from the trigger edge (so it lines up with the Hasta DAQ's Time).
%   Without biasVolts nothing is tared, so a constant offset (the sensor's
%   own bias and the model's weight) is expected.
    arguments
        pxiData (1,1) wt.pxi.ForceData
        titleText (1,1) string = "Force sensor"
        biasVolts (1,6) double = zeros(1, 6)
    end
    fig = figure("Name", titleText);
    ft = pxiData.Forces(biasVolts);
    t = pxiData.TimeFromTrigger;
    if all(isnan(t)), t = pxiData.Time; end
    names = pxiData.Calibration.AxisNames;
    units = {pxiData.Calibration.ForceUnits, pxiData.Calibration.TorqueUnits};
    for i = 1:6
        subplot(3, 2, i);
        plot(t, ft(:, i)); grid on;
        ylabel(sprintf("%s (%s)", names(i), units{1 + (i > 3)}));
        if i >= 5, xlabel("t (s)"); end
    end
    sgtitle(titleText);
    linkaxes(findall(fig, "Type", "axes"), "x");
end
