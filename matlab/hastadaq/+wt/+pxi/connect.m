function forceDaq = connect(hd, card, rate)
%CONNECT The PXI force sensor, ready to be triggered by the Hasta DAQ's input.
%   forceDaq = wt.pxi.connect(hd, "Dev5", 200)
%   Opens the NI card on the first call and reuses it afterwards (the card is
%   opened once per MATLAB session; "clear functions" forgets it). Drives the
%   trigger line LOW first, then sets the board to start on a rising edge, so
%   the line is never high when the board is armed.
%   hd is a wt.hasta.DaqClient; rate is the force-sensor samples per second.
    arguments
        hd (1,1) wt.hasta.DaqClient
        card (1,1) string
        rate (1,1) double {mustBePositive} = 200
    end
    persistent cached
    if isempty(cached) || ~isvalid(cached) || cached.Card ~= card || cached.Rate ~= rate
        cached = wt.pxi.ForceDaq(card, rate=rate);
    end
    cached.lowOutput();
    hd.setTrigger(inEdge="rising");
    forceDaq = cached;
end
