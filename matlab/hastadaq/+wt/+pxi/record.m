function [hdData, pxiData] = record(hd, forceDaq, durationS, sampleHz, opts)
%RECORD Record durationS seconds from the Hasta DAQ and, if given, the PXI.
%   [hdData, pxiData] = wt.pxi.record(hd, forceDaq, 10, 100)
%   With a force sensor, both start on the SAME hardware edge: the board is
%   armed to wait for it, then the PXI raises the trigger line and records
%   (this blocks MATLAB for the whole record). With forceDaq = [] the board
%   is simply run, as hd.capture, and pxiData is an empty placeholder
%   wt.pxi.ForceData so arrays of results stay parallel.
%   camera=true/false overrides the force sensor's Camera property (pulse the
%   tracking camera either side of the record).
    arguments
        hd (1,1) wt.hasta.DaqClient
        forceDaq
        durationS (1,1) double {mustBePositive}
        sampleHz (1,1) double {mustBePositive}
        opts.camera {mustBeScalarOrEmpty} = []
    end
    if isempty(forceDaq)
        hdData = hd.capture(durationS, sampleHz);
        pxiData = wt.pxi.ForceData();
    else
        hd.arm(durationS, sampleHz);
        pxiData = forceDaq.acquire(durationS, camera=opts.camera);
        hd.waitForDone(durationS + 30);
        hdData = hd.readData();
    end
end
