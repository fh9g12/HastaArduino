function [hd, ohb, pxi] = setupTestEnvironment(opts)
%SETUPTESTENVIRONMENT Connect to the Hasta DAQ, and the tunnel and force sensor if asked.
%   hd = wt.hasta.setupTestEnvironment()                    % just the board
%   [hd, ohb] = wt.hasta.setupTestEnvironment()             % + the tunnel computer (OHB)
%   [hd, ohb, pxi] = wt.hasta.setupTestEnvironment(UsePxi=true, UseCamera=true)
%
%   The addresses, the NI card and the sample rate rarely change, so they
%   are defaults here (and only here); override any of them by name:
%     HastaIP, OhbIP     board and tunnel-computer addresses (HastaPort: 5025)
%     PxiCard            the NI card ("PXI1Slot4_2", the PXIe-6363)
%     PxiRateHz          force-sensor sample rate
%     UsePxi             connect the force sensor (pxi = [] otherwise)
%     UseCamera          pulse the tracking camera around each force record
%     UseOhb             connect the tunnel computer (default: when ohb is asked for)
%     SendEncoderZero    send the saved encoder zero to the board (default true;
%                        skipped, with a note, if none is saved). Turns the
%                        controller off first - the zero is refused while it runs.
%
%   Live connections are kept between calls (the board and the NI card each
%   take one client), so calling this at the top of every script is cheap;
%   "clear functions" forgets them.
    arguments
        opts.HastaIP (1,1) string = "192.168.1.107"
        opts.HastaPort (1,1) double = 5025
        opts.OhbIP (1,1) string = "192.168.1.61"
        opts.PxiCard (1,1) string = "PXI1Slot4_2"
        opts.PxiRateHz (1,1) double {mustBePositive} = 200
        opts.UsePxi (1,1) logical = false
        opts.UseCamera (1,1) logical = false
        opts.UseOhb {mustBeScalarOrEmpty} = []
        opts.SendEncoderZero (1,1) logical = true
    end
    persistent hdKept ohbKept
    useOhb = nargout >= 2;
    if ~isempty(opts.UseOhb)
        useOhb = logical(opts.UseOhb);
    end

    % the board
    if isempty(hdKept) || ~isvalid(hdKept) || hdKept.BoardIP ~= opts.HastaIP || hdKept.Port ~= opts.HastaPort
        hdKept = wt.hasta.DaqClient(opts.HastaIP, opts.HastaPort);
    end
    hd = hdKept;

    % the tunnel computer
    ohb = [];
    if useOhb
        if isempty(ohbKept) || ~isvalid(ohbKept)
            ohbKept = wt.OHBControl();
        end
        if ~ohbKept.connected
            if ~ohbKept.connect(opts.OhbIP)
                error("wt:hasta:ohb", "Not connected to the OHB server at %s.", opts.OhbIP);
            end
            ohbKept.openLogFile();
        end
        ohb = ohbKept;
    end

    % the force sensor (also puts the board's trigger input on a rising edge)
    pxi = [];
    if opts.UsePxi
        pxi = wt.pxi.connect(hd, opts.PxiCard, opts.PxiRateHz);
        pxi.Camera = opts.UseCamera;
    end

    % the saved encoder zero (the board forgets it whenever it restarts)
    if opts.SendEncoderZero
        if isempty(wt.hasta.encoderZero.info())
            warning("wt:hasta:noEncoderZero", "No encoder zero is saved: run scripts.ZeroEncoderRun with the model at zero.");
        else
            hd.disableControl();
            hd.setEncoderZeroOffset(wt.hasta.encoderZero.get());
        end
    end
end
