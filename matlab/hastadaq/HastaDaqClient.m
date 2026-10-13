classdef HastaDaqClient < handle
    %HASTADAQCLIENT Client for the HastaDAQ rig's SCPI-over-TCP interface.
    %   Talks directly to HastaDAQ.ino (newline-terminated ASCII SCPI on
    %   TCP port 5025). Get the board's IP from the Serial Monitor at boot
    %   ("[WiFi] Connected, IP=...").
    %
    %   hd = HastaDaqClient("192.168.68.107");
    %   hd.setControl(Kp=1, targetDeg=0, outLimitDeg=15, enabled=true);
    %   hd.setExcitation("chirp", f0=1, f1=5, periodS=15, amplitudeDeg=3, armed=true);
    %   hd.run(15, 100);        % <-- moves the control surfaces
    %   hd.waitForDone();
    %   data = hd.readData();
    %   delete(hd)              % closes the TCP connection
    %
    %   Mirrors the firmware's own command set one-to-one (see the wire
    %   protocol comment at the top of HastaDAQ.ino) so the two stay easy
    %   to compare. Setters send only the fields you pass - everything
    %   else keeps its current value on the board, exactly like the
    %   firmware's JSON setters.
    %
    %   SAFETY: the board drives real SBUS control surfaces continuously.
    %   These calls move them: setChannel (trimDeg), setControl (enabled,
    %   targetDeg), setExcitation (armed=true, then run/fire/a trigger
    %   edge). Confirm the area is clear first. Nothing here is called
    %   implicitly by the constructor.
    %
    %   Any failure (an "ERR ..." reply, a timeout, a malformed reply)
    %   throws a normal MATLAB error.
    %
    %   NOTE: first draft, not yet run against MATLAB or a live board -
    %   start with identify() and the read-only getters (getChannel,
    %   getExcitation, getControl, getStatus) before anything that moves
    %   a surface.

    properties (SetAccess = private)
        BoardIP (1,1) string
        Port (1,1) double
    end

    properties (Constant)
        % Servo travel either side of centre - matches
        % SbusServoBank::TRAVEL_DEG in the firmware.
        MaxAngleDeg = 48.06
    end

    properties (Access = private)
        Conn   % tcpclient
        ChanArraySupported = true   % false once an old board rejects an array CHANCONFIG
    end

    methods
        function obj = HastaDaqClient(boardIP, port, timeoutS)
            %HASTADAQCLIENT Open the TCP connection and print *IDN?.
            arguments
                boardIP (1,1) string
                port (1,1) double = 5025
                timeoutS (1,1) double = 10
            end
            obj.BoardIP = boardIP;
            obj.Port = port;
            obj.Conn = tcpclient(boardIP, port, "Timeout", timeoutS);
            configureTerminator(obj.Conn, "LF");
            disp("IDN: " + obj.identify());
        end

        function delete(obj)
            %DELETE Close the connection (tcpclient closes when cleared).
            obj.Conn = [];
        end

        function idn = identify(obj)
            %IDENTIFY Return the *IDN? string.
            idn = obj.query("*IDN?");
        end

        % ---------------- channels ----------------

        function setChannel(obj, channel, opts)
            %SETCHANNEL Configure one servo channel's mix.
            %   channel: a HDCh member (Rudder, ElevR, ElevL,
            %   AilR, AilL). A firmware name string or 0-4 index also works.
            %   Options (all optional; omitted = unchanged):
            %     excGain, ctrlGain (-1..1), trimDeg, chMin, chMax
            %   Per-channel output is:
            %     trimDeg + excGain*excitation + ctrlGain*controlOutput
            %
            %   hd.setChannel(HDCh.ElevL, excGain=1, trimDeg=0)
            %
            %   Angles are centred on 0 (travel limited to +/-48.06 deg, default trim 0).
            %   chMin/chMax are raw SBUS counts (64..1984 = 920..2120 us)
            %   that clamp the output; the angle scale itself is fixed.
            arguments
                obj
                channel
                opts.excGain (1,1) double = NaN
                opts.ctrlGain (1,1) double = NaN
                opts.trimDeg (1,1) double = NaN
                opts.chMin (1,1) double = NaN
                opts.chMax (1,1) double = NaN
            end
            body = struct("channel", HastaDaqClient.channelId(channel));
            body = HastaDaqClient.addFields(body, opts);
            obj.sendJson("CHANCONFIG", body);
        end

        function setAngle(obj, surface, angleDeg)
            %SETANGLE Move surface(s) to a fixed angle, degrees from centre.
            %   hd.setAngle(HDCh.Rudder, 10)
            %   hd.setAngle(HDCh.ElevL, -5)
            %   hd.setAngle([HDCh.ElevL HDCh.ElevR], 3)
            %   hd.setAngle([HDCh.AilL HDCh.AilR], [5 -5])
            %
            %   Sets that channel's trimDeg to the angle AND zeroes its
            %   excGain and ctrlGain, so nothing else (excitation, PID) is
            %   added on top and the surface really goes to angleDeg. That
            %   changes the channel's mix settings: to get excitation or
            %   control back on it, call setChannel with excGain/ctrlGain.
            %   Other channels are untouched. THIS MOVES THE SURFACE.
            %
            %   angleDeg must be within +/-48.06 deg (the servos' travel);
            %   anything outside errors rather than silently clipping.
            %   One angle applies to every surface, or pass one per surface.
            arguments
                obj
                surface (1,:) HDCh
                angleDeg (1,:) double
            end
            if isscalar(angleDeg)
                angleDeg = repmat(angleDeg, size(surface));
            end
            if numel(angleDeg) ~= numel(surface)
                error("HastaDaqClient:badAngle", ...
                    "Give one angle for all surfaces, or one angle per surface.");
            end
            limit = HastaDaqClient.MaxAngleDeg;
            if any(abs(angleDeg) > limit)
                error("HastaDaqClient:badAngle", ...
                    "Angle must be within +/-%.2f deg.", limit);
            end
            % ONE command for all the surfaces (a JSON array), applied
            % together on the board so they start moving in the same SBUS
            % frame - separate commands would each cost a WiFi round trip
            % and the surfaces would start one after another.
            body = struct("channel", {}, "trimDeg", {}, "excGain", {}, "ctrlGain", {});
            for k = 1:numel(surface)
                body(k) = struct("channel", HastaDaqClient.channelId(surface(k)), ...
                    "trimDeg", angleDeg(k), "excGain", 0, "ctrlGain", 0);
            end
            % Older firmware only accepts one channel per CHANCONFIG and
            % answers a multi-surface array with "ERR unknown channel"
            % (changing nothing): fall back to one command per surface
            % (not synchronised) and remember it, so this warns only once.
            if obj.ChanArraySupported || isscalar(surface)
                try
                    obj.sendJson("CHANCONFIG", body);
                    return
                catch ME
                    if isscalar(surface) || ME.identifier ~= "HastaDaqClient:boardError" ...
                            || ~contains(ME.message, "unknown channel")
                        rethrow(ME);
                    end
                    obj.ChanArraySupported = false;
                    warning("HastaDaqClient:oldFirmware", ...
                        "The board's firmware can't move several surfaces in one command - " + ...
                        "update it for synchronised moves. Sending one at a time.");
                end
            end
            for k = 1:numel(surface)
                obj.sendJson("CHANCONFIG", body(k));
            end
        end

        function setSteady(obj, surface, angleDeg, opts)
            %SETSTEADY Set up a steady (no-excitation) test: move the
            %surface(s) to a fixed angle and make sure nothing will
            %oscillate, so the standard run()/waitForDone()/readData()
            %that follow log a steady condition.
            %
            %   hd.setSteady([HDCh.ElevL HDCh.ElevR], 3)
            %   hd.setSteady([HDCh.AilL HDCh.AilR], [5 -5], settleS=2)
            %   hd.run(10, 100); hd.waitForDone(); data = hd.readData();
            %
            %   Disarms any armed excitation (so run() can't start a
            %   waveform; it stays disarmed afterwards) and calls setAngle
            %   (one angle for all surfaces, or one per surface), which also
            %   zeroes those channels' excGain/ctrlGain. settleS (default
            %   0) waits that many seconds afterwards so the surfaces have
            %   arrived before you start logging. Does not touch the PID
            %   loop's own settings or other channels. THIS MOVES SURFACES.
            arguments
                obj
                surface (1,:) HDCh
                angleDeg (1,:) double
                opts.settleS (1,1) double {mustBeNonnegative} = 0
            end
            obj.disarmExcitation();
            obj.setAngle(surface, angleDeg);
            pause(opts.settleS);
        end

        function cfg = getChannel(obj, channel)
            %GETCHANNEL Return one channel's config as a struct.
            cfg = obj.queryJson("CHANCONFIG? " + string(HastaDaqClient.channelId(channel)));
        end

        % ---------------- excitation ----------------

        function setExcitation(obj, type, opts)
            %SETEXCITATION Configure the shared excitation waveform.
            %   type: "sine" | "cosine" | "chirp"
            %   Options (omitted = unchanged): freqHz (sine), f0, f1
            %   (chirp), periodS (cosine/chirp), amplitudeDeg, cycles
            %   (0 = run until disarmed), delayS (wait after a trigger
            %   before starting), armed (should the NEXT trigger start it).
            %
            %   Setting armed=true does not move anything by itself - the
            %   waveform starts at the next run()/fire()/trigger-pin edge.
            arguments
                obj
                type (1,1) string {mustBeMember(type, ["sine","cosine","chirp"])}
                opts.freqHz (1,1) double = NaN
                opts.f0 (1,1) double = NaN
                opts.f1 (1,1) double = NaN
                opts.periodS (1,1) double = NaN
                opts.amplitudeDeg (1,1) double = NaN
                opts.cycles (1,1) double = NaN
                opts.delayS (1,1) double = NaN
                opts.armed {mustBeScalarOrEmpty} = []
            end
            body = struct("type", type);
            body = HastaDaqClient.addFields(body, rmfield(opts, "armed"));
            if ~isempty(opts.armed)
                body.armed = logical(opts.armed); % must be a JSON bool, not 0/1
            end
            obj.sendJson("EXCITE", body);
        end

        function disarmExcitation(obj)
            %DISARMEXCITATION Set armed=false so the next trigger starts
            %no waveform. Leaves every other EXCITE setting untouched.
            cfg = obj.getExcitation();
            obj.sendJson("EXCITE", struct("type", cfg.type, "armed", false));
        end

        function cfg = getExcitation(obj)
            %GETEXCITATION Return the excitation config; .active is
            %read-only (is it oscillating right now).
            cfg = obj.queryJson("EXCITE?");
        end

        % ---------------- elevator control loop ----------------

        function setControl(obj, opts)
            %SETCONTROL Configure the PID control loop (error = encoder
            %angle - targetDeg). Options (omitted = unchanged): Kp, Ki,
            %Kd, targetDeg, outLimitDeg, enabled.
            %
            %   hd.setControl(Kp=1, Ki=0, Kd=0, targetDeg=5, enabled=true)
            arguments
                obj
                opts.Kp (1,1) double = NaN
                opts.Ki (1,1) double = NaN
                opts.Kd (1,1) double = NaN
                opts.targetDeg (1,1) double = NaN
                opts.outLimitDeg (1,1) double = NaN
                opts.enabled {mustBeScalarOrEmpty} = []
            end
            body = struct();
            names = ["Kp","Ki","Kd","targetDeg","outLimitDeg"];
            wire = ["kp","ki","kd","targetDeg","outLimitDeg"];
            for i = 1:numel(names)
                if ~isnan(opts.(names(i)))
                    body.(wire(i)) = opts.(names(i));
                end
            end
            if ~isempty(opts.enabled)
                body.enabled = logical(opts.enabled); % must be a JSON bool, not 0/1
            end
            obj.sendJson("CTRLCONFIG", body);
        end

        function enableControl(obj)
            %ENABLECONTROL Turn the PID loop on (moves the ctrlGain channels).
            obj.sendJson("CTRLCONFIG", struct("enabled", true));
        end

        function disableControl(obj)
            %DISABLECONTROL Turn the PID loop off.
            obj.sendJson("CTRLCONFIG", struct("enabled", false));
        end

        function cfg = getControl(obj)
            %GETCONTROL Return the PID config as a struct.
            cfg = obj.queryJson("CTRLCONFIG?");
        end

        % ---------------- capture ----------------

        function run(obj, durationS, sampleHz)
            %RUN Arm and immediately trigger a bounded capture. Returns
            %right away - the capture continues in the background; use
            %waitForDone() then readData(). If EXCITE is armed, the
            %waveform starts too (after its delayS) - THIS MOVES SURFACES.
            arguments
                obj
                durationS (1,1) double {mustBePositive}
                sampleHz (1,1) double {mustBePositive} = 100
            end
            obj.sendJson("RUN", struct("durationS", durationS, "sampleHz", sampleHz));
        end

        function arm(obj, durationS, sampleHz)
            %ARM Configure a capture but wait for fire() or a trigger-pin
            %edge instead of starting now.
            arguments
                obj
                durationS (1,1) double {mustBePositive}
                sampleHz (1,1) double {mustBePositive} = 100
            end
            obj.sendJson("ARM", struct("durationS", durationS, "sampleHz", sampleHz));
        end

        function fire(obj)
            %FIRE Software trigger for an armed capture (errors if nothing
            %is armed). Starts armed excitation too - MOVES SURFACES.
            reply = obj.query("FIRE");
            HastaDaqClient.checkReply(reply, "FIRE");
        end

        function s = getStatus(obj)
            %GETSTATUS Return capture status as a struct:
            %   .state    "ARMED" | "CAPTURING" | "DONE"
            %   .elapsedS, .durationS  (CAPTURING only, else NaN)
            %   .nSamples              (DONE only, else NaN)
            %   .raw                   the raw reply line
            raw = obj.query("STATUS?");
            s = struct("state", "", "elapsedS", NaN, "durationS", NaN, ...
                "nSamples", NaN, "raw", raw);
            if startsWith(raw, "ARMED")
                s.state = "ARMED";
            elseif startsWith(raw, "CAPTURING")
                s.state = "CAPTURING";
                v = sscanf(raw, "CAPTURING %f/%f");
                if numel(v) == 2, s.elapsedS = v(1); s.durationS = v(2); end
            elseif startsWith(raw, "DONE")
                s.state = "DONE";
                s.nSamples = sscanf(raw, "DONE %d");
            else
                error("HastaDaqClient:badReply", "Unexpected STATUS? reply: %s", raw);
            end
        end

        function s = waitForDone(obj, timeoutS)
            %WAITFORDONE Poll STATUS? until DONE (default timeout 60 s).
            %Throws on timeout. Note "DONE" is also the idle state, so
            %call this after run()/fire(), not before.
            arguments
                obj
                timeoutS (1,1) double = 60
            end
            t0 = tic;
            while toc(t0) < timeoutS
                s = obj.getStatus();
                if s.state == "DONE"
                    return
                end
                pause(0.2);
            end
            error("HastaDaqClient:timeout", ...
                "Capture did not finish within %g s (last status: %s)", timeoutS, s.raw);
        end

        function data = readData(obj)
            %READDATA Fetch the last completed capture (DATA?) as a
            %HastaDaqData object: one row per sample, with sensors,
            %excitation and each servo's commanded angle as its own
            %property (RUDDER_Angle, ELEV_R_Angle, ELEV_L_Angle,
            %AIL_R_Angle, AIL_L_Angle). See HastaDaqData.m.
            obj.flushInput();
            writeline(obj.Conn, "DATA?");
            header = strtrim(readline(obj.Conn));
            parsed = sscanf(header, "BIN %d %d");
            if numel(parsed) ~= 2
                error("HastaDaqClient:badReply", "Unexpected DATA? header: %s", header);
            end
            n = parsed(1);
            bytesPerSample = parsed(2);

            if n > 0
                raw = read(obj.Conn, n * bytesPerSample, "uint8");
            else
                raw = zeros(0, 1, "uint8");
            end
            raw = reshape(uint8(raw(:)), bytesPerSample, n); % column k = sample k's bytes
            data = HastaDaqData.FromBytes(raw, bytesPerSample);
        end

        function deg = getEncoderDeg(obj)
            %GETENCODERDEG Return the current encoder angle in degrees
            %(latest reading on the board, no capture needed).
            reply = obj.query("ENCODER?");
            deg = str2double(reply);
            if isnan(deg)
                error("HastaDaqClient:badReply", "ENCODER? -> %s", reply);
            end
        end

        function zeroEncoder(obj)
            %ZEROENCODER Make the encoder's current position the new 0.
            %Software zero only: it's held in RAM on the board and lost on
            %reboot/reflash, so re-zero after each power-up. Errors if the
            %PID loop is enabled (zeroing under it would step its error) -
            %call disableControl() first.
            reply = obj.query("ZERO");
            HastaDaqClient.checkReply(reply, "ZERO");
        end

        % ---------------- trigger I/O ----------------

        function setTrigger(obj, opts)
            %SETTRIGGER Configure trigger pins. Options (omitted =
            %unchanged): outPulseMs, inEdge ("rising"|"falling").
            arguments
                obj
                opts.outPulseMs (1,1) double = NaN
                opts.inEdge (1,1) string {mustBeMember(opts.inEdge, ["", "rising", "falling"])} = ""
            end
            body = struct();
            if ~isnan(opts.outPulseMs), body.outPulseMs = opts.outPulseMs; end
            if opts.inEdge ~= "", body.inEdge = opts.inEdge; end
            obj.sendJson("TRIGCONFIG", body);
        end

        function cfg = getTrigger(obj)
            %GETTRIGGER Return trigger config.
            cfg = obj.queryJson("TRIGCONFIG?");
        end

        % ---------------- UDP streaming ----------------

        function setUdp(obj, opts)
            %SETUDP Configure continuous UDP streaming (same per-sample
            %binary layout as DATA?, independent of RUN/ARM). Options
            %(omitted = unchanged): ip, port, rateHz, enabled. This class
            %only configures it - receiving the stream is up to you
            %(e.g. udpport).
            arguments
                obj
                opts.ip (1,1) string = ""
                opts.port (1,1) double = NaN
                opts.rateHz (1,1) double = NaN
                opts.enabled {mustBeScalarOrEmpty} = []
            end
            body = struct();
            if opts.ip ~= "", body.ip = opts.ip; end
            if ~isnan(opts.port), body.port = opts.port; end
            if ~isnan(opts.rateHz), body.rateHz = opts.rateHz; end
            if ~isempty(opts.enabled), body.enabled = logical(opts.enabled); end
            obj.sendJson("UDPCONFIG", body);
        end

        function cfg = getUdp(obj)
            %GETUDP Return UDP streaming config.
            cfg = obj.queryJson("UDPCONFIG?");
        end
    end

    methods (Access = private)
        function flushInput(obj)
            %FLUSHINPUT Drop stale bytes (e.g. from an earlier timeout) so
            %a reply can't be matched to the wrong command.
            if obj.Conn.NumBytesAvailable > 0
                read(obj.Conn, obj.Conn.NumBytesAvailable, "uint8");
            end
        end

        function reply = query(obj, command)
            %QUERY Send one command line, return the trimmed reply line
            %(strtrim: the firmware's println() sends CRLF, readline()
            %only strips the LF).
            obj.flushInput();
            writeline(obj.Conn, command);
            reply = strtrim(readline(obj.Conn));
        end

        function sendJson(obj, command, body)
            %SENDJSON Two-line JSON command: command line, then the JSON
            %body as a second raw line; expects "OK" back. Both lines go out
            %in ONE write: as two small writes, TCP's Nagle algorithm holds
            %the second until the first is acknowledged, adding latency to
            %every command.
            obj.flushInput();
            lines = command + newline + jsonencode(body) + newline;
            write(obj.Conn, uint8(char(lines)));
            reply = strtrim(readline(obj.Conn));
            HastaDaqClient.checkReply(reply, command);
        end

        function cfg = queryJson(obj, command)
            reply = obj.query(command);
            if startsWith(reply, "ERR")
                error("HastaDaqClient:boardError", "%s -> %s", command, reply);
            end
            cfg = jsondecode(reply);
        end
    end

    methods (Static, Access = private)
        function checkReply(reply, command)
            if reply ~= "OK"
                error("HastaDaqClient:boardError", "%s -> %s", command, reply);
            end
        end

        function id = channelId(channel)
            %CHANNELID HDCh member -> its firmware name;
            %a raw name string or 0-4 index is passed through as-is.
            if isa(channel, "HDCh")
                id = char(channel.WireName);
            elseif isstring(channel) || ischar(channel)
                id = char(channel);
            elseif isnumeric(channel) && isscalar(channel)
                id = channel;
            else
                error("HastaDaqClient:badChannel", "channel must be an index or a name.");
            end
        end

        function body = addFields(body, opts)
            %ADDFIELDS Copy every non-NaN option into the JSON body.
            names = fieldnames(opts);
            for i = 1:numel(names)
                v = opts.(names{i});
                if isnumeric(v) && ~isnan(v)
                    body.(names{i}) = v;
                end
            end
            for g = ["excGain", "ctrlGain"]
                if isfield(body, g) && abs(body.(g)) > 1
                    error("HastaDaqClient:badGain", "%s must be within [-1, 1].", g);
                end
            end
        end
    end
end
