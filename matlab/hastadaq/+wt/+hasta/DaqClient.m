classdef DaqClient < handle
    %DAQCLIENT Client for the HastaDAQ rig's SCPI-over-TCP interface.
    %   Talks directly to HastaDAQ.ino (newline-terminated ASCII SCPI on
    %   TCP port 5025). Get the board's IP from the Serial Monitor at boot
    %   ("[WiFi] Connected, IP=...").
    %
    %   hd = wt.hasta.DaqClient("192.168.68.107");
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
        ReconnectCount (1,1) double = 0   % times the connection was re-opened after a missing reply
        LastHealth = []                   % result of the latest getHealth(), [] until one succeeds
    end

    properties (Constant)
        % Servo travel either side of centre - matches
        % SbusServoBank::TRAVEL_DEG in the firmware.
        MaxAngleDeg = 48.06
    end

    properties
        % How long to wait for each reply, seconds. WiFi to the board can
        % stall for many seconds, hence the generous default.
        TimeoutS (1,1) double {mustBePositive} = 20
        % How many times a command is tried before giving up (each failed
        % attempt reconnects first). Worst case, a dead board stalls a call
        % for about MaxAttempts * TimeoutS seconds.
        MaxAttempts (1,1) double {mustBeInteger, mustBePositive} = 5
    end

    properties (Access = private)
        Conn   % tcpclient
        ChanArraySupported = true   % false once an old board rejects an array CHANCONFIG
        ControlSettings = struct()  % PID settings last sent from MATLAB (kp, ki, kd, targetDeg, outLimitDeg)
    end

    methods
        function obj = DaqClient(boardIP, port, timeoutS)
            %DAQCLIENT Open the TCP connection and print *IDN?.
            %   hd = wt.hasta.DaqClient(ip)            % port 5025, 20 s timeout
            %   hd.MaxAttempts = 8;                    % optional: try harder
            arguments
                boardIP (1,1) string
                port (1,1) double = 5025
                timeoutS (1,1) double = 20
            end
            obj.BoardIP = boardIP;
            obj.Port = port;
            obj.TimeoutS = timeoutS;
            obj.connect();
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

        function rttS = ping(obj)
            %PING Round-trip time to the board in seconds (a *IDN? query).
            %Doubles as a connection check: if the board doesn't answer it
            %reconnects and retries like any other command, and errors if it
            %still can't be reached.
            t0 = tic;
            obj.identify();
            rttS = toc(t0);
        end

        function health = getHealth(obj)
            %GETHEALTH Link health reported by the board (SYS?), as a struct:
            %   uptimeS        seconds since boot (small = it just rebooted)
            %   resetReason    why the chip last reset (power-on, brownout, ...)
            %   wifiConnected, rssi   WiFi state and signal strength (dBm)
            %   freeHeap       bytes
            %   connects, disconnects, wifiDrops   counted since boot
            %   maxLoopMs      longest main-loop pass since SYS? was last read
            %                  (a big number means the board stalled)
            %   needs firmware with SYS?; an older board gives no reply.
            %   Also stored in LastHealth. Print it with
            %   wt.hasta.DaqClient.formatHealth(health).
            health = obj.queryJson("SYS?");
            obj.LastHealth = health;
        end

        % ---------------- channels ----------------

        function setChannel(obj, channel, opts)
            %SETCHANNEL Configure one servo channel's mix.
            %   channel: a wt.hasta.HDCh member (Rudder, ElevR, ElevL,
            %   AilR, AilL). A firmware name string or 0-4 index also works.
            %   Options (all optional; omitted = unchanged):
            %     excGain, ctrlGain (-1..1), trimDeg, chMin, chMax
            %   Per-channel output is:
            %     trimDeg + excGain*excitation + ctrlGain*controlOutput
            %
            %   hd.setChannel(wt.hasta.HDCh.ElevL, excGain=1, trimDeg=0)
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
            body = struct("channel", wt.hasta.DaqClient.channelId(channel));
            body = wt.hasta.DaqClient.addFields(body, opts);
            obj.sendJson("CHANCONFIG", body);
        end

        function setAngle(obj, surface, angleDeg)
            %SETANGLE Move surface(s) to a fixed angle, degrees from centre.
            %   hd.setAngle(wt.hasta.HDCh.Rudder, 10)
            %   hd.setAngle(wt.hasta.HDCh.ElevL, -5)
            %   hd.setAngle([wt.hasta.HDCh.ElevL wt.hasta.HDCh.ElevR], 3)
            %   hd.setAngle([wt.hasta.HDCh.AilL wt.hasta.HDCh.AilR], [5 -5])
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
                surface (1,:) wt.hasta.HDCh
                angleDeg (1,:) double
            end
            if isscalar(angleDeg)
                angleDeg = repmat(angleDeg, size(surface));
            end
            if numel(angleDeg) ~= numel(surface)
                error("DaqClient:badAngle", ...
                    "Give one angle for all surfaces, or one angle per surface.");
            end
            limit = wt.hasta.DaqClient.MaxAngleDeg;
            if any(abs(angleDeg) > limit)
                error("DaqClient:badAngle", ...
                    "Angle must be within +/-%.2f deg.", limit);
            end
            % ONE command for all the surfaces (a JSON array), applied
            % together on the board so they start moving in the same SBUS
            % frame - separate commands would each cost a WiFi round trip
            % and the surfaces would start one after another.
            body = struct("channel", {}, "trimDeg", {}, "excGain", {}, "ctrlGain", {});
            for k = 1:numel(surface)
                body(k) = struct("channel", wt.hasta.DaqClient.channelId(surface(k)), ...
                    "trimDeg", angleDeg(k), "excGain", 0, "ctrlGain", 0);
            end
            obj.sendChannelBodies(body);
        end

        function setMix(obj, surface, opts)
            %SETMIX Set the mix of several surfaces in ONE command, so they
            %all change in the same SBUS frame. Each surface's output is
            %   trimDeg + excGain*excitation + ctrlGain*controlOutput
            %
            %   hd.setMix([wt.hasta.HDCh.ElevL wt.hasta.HDCh.ElevR], excGain=1)
            %   hd.setMix([wt.hasta.HDCh.ElevL wt.hasta.HDCh.ElevR], trimDeg=[2.5 2.7], ctrlGain=0)
            %
            %   Options (omitted = unchanged): trimDeg (+/-48.06 deg), excGain
            %   and ctrlGain (-1..1). Each is one value for all the surfaces,
            %   or one value per surface. THIS CAN MOVE SURFACES.
            arguments
                obj
                surface (1,:) wt.hasta.HDCh
                opts.trimDeg (1,:) double = NaN
                opts.excGain (1,:) double = NaN
                opts.ctrlGain (1,:) double = NaN
            end
            n = numel(surface);
            names = ["trimDeg", "excGain", "ctrlGain"];
            limits = [wt.hasta.DaqClient.MaxAngleDeg, 1, 1];
            given = false(1, 3);
            for i = 1:3
                v = opts.(names(i));
                if isscalar(v) && isnan(v)
                    continue   % omitted
                end
                if isscalar(v)
                    v = repmat(v, 1, n);
                end
                if numel(v) ~= n || any(isnan(v))
                    error("DaqClient:badMix", "%s: give one value for all surfaces, or one per surface.", names(i));
                end
                if any(abs(v) > limits(i))
                    error("DaqClient:badMix", "%s must be within +/-%g.", names(i), limits(i));
                end
                opts.(names(i)) = v;
                given(i) = true;
            end
            if ~any(given)
                error("DaqClient:badMix", "Nothing to set: give trimDeg, excGain and/or ctrlGain.");
            end
            items = cell(1, n);
            for k = 1:n
                item = struct("channel", wt.hasta.DaqClient.channelId(surface(k)));
                for i = find(given)
                    item.(names(i)) = opts.(names(i))(k);
                end
                items{k} = item;
            end
            obj.sendChannelBodies([items{:}]);
        end

        function setSteady(obj, surface, angleDeg, opts)
            %SETSTEADY Set up a steady (no-excitation) test: move the
            %surface(s) to a fixed angle and make sure nothing will
            %oscillate, so the standard run()/waitForDone()/readData()
            %that follow log a steady condition.
            %
            %   hd.setSteady([wt.hasta.HDCh.ElevL wt.hasta.HDCh.ElevR], 3)
            %   hd.setSteady([wt.hasta.HDCh.AilL wt.hasta.HDCh.AilR], [5 -5], settleS=2)
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
                surface (1,:) wt.hasta.HDCh
                angleDeg (1,:) double
                opts.settleS (1,1) double {mustBeNonnegative} = 0
            end
            obj.disarmExcitation();
            obj.setAngle(surface, angleDeg);
            pause(opts.settleS);
        end

        function cfg = getChannel(obj, channel)
            %GETCHANNEL Return one channel's config as a struct.
            cfg = obj.queryJson("CHANCONFIG? " + string(wt.hasta.DaqClient.channelId(channel)));
        end

        % ---------------- excitation ----------------

        function setExcitation(obj, type, opts)
            %SETEXCITATION Configure the shared excitation waveform.
            %   type: "sine" | "cosine" | "chirp" | "step"
            %   Options (omitted = unchanged): freqHz (sine), f0, f1
            %   (chirp), periodS (cosine/chirp), amplitudeDeg, cycles
            %   (0 = run until disarmed), delayS (wait after a trigger
            %   before starting), armed (should the NEXT trigger start it).
            %
            %   "cosine" is the 1-cosine pulse: 0 -> amplitudeDeg -> 0,
            %   smoothly, over periodS (cycles=1 for a single pulse; a
            %   negative amplitude gives a pulse the other way). "step" holds
            %   amplitudeDeg from delayS after the trigger until disarmed;
            %   periodS and cycles are ignored. Both are timed on the board,
            %   so a step or pulse starts at a known time after the trigger
            %   (an external edge or run()/fire()) with no host command.
            %   "step" needs firmware that knows it (older boards reply ERR).
            %
            %   Setting armed=true does not move anything by itself - the
            %   waveform starts at the next run()/fire()/trigger-pin edge.
            arguments
                obj
                type (1,1) string {mustBeMember(type, ["sine","cosine","chirp","step"])}
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
            body = wt.hasta.DaqClient.addFields(body, rmfield(opts, "armed"));
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
            % remember what the board accepted (never the on/off state)
            for field = string(fieldnames(body))'
                if field ~= "enabled"
                    obj.ControlSettings.(field) = body.(field);
                end
            end
        end

        function enableControl(obj)
            %ENABLECONTROL Turn the PID loop on (moves the ctrlGain channels),
            %keeping the settings you last gave setControl: Kp, Ki, Kd, the
            %target and the output limit are sent again along with the
            %enable, so a disable/enable cycle never changes them. If the
            %board's own values had drifted from yours (it restarted, say)
            %that is reported and your values are restored.
            body = obj.ControlSettings;
            fields = string(fieldnames(body))';
            if ~isempty(fields)
                board = obj.getControl();
                for field = fields
                    if abs(board.(field) - body.(field)) > 1e-4 * max(1, abs(body.(field)))
                        warning("DaqClient:controlSettingsLost", ...
                            "The board's control settings (%s=%g) differ from the ones last set from MATLAB (%s=%g) - did the board restart? Re-applying yours.", ...
                            field, board.(field), field, body.(field));
                        break
                    end
                end
            end
            body.enabled = true;
            obj.sendJson("CTRLCONFIG", body);
        end

        function disableControl(obj)
            %DISABLECONTROL Turn the PID loop off.
            obj.sendJson("CTRLCONFIG", struct("enabled", false));
        end

        function cfg = getControl(obj)
            %GETCONTROL Return the PID config as a struct.
            cfg = obj.queryJson("CTRLCONFIG?");
        end

        % ---------------- free-to-pitch tests ----------------

        function result = holdPitch(obj, targetDeg, opts)
            %HOLDPITCH Use the controller to hold the model at a target
            %pitch angle (the encoder angle) and wait for it to settle.
            %
            %   hd.setControl(Kp=1, Ki=0.5, Kd=0, outLimitDeg=20);   % tune once
            %   r = hd.holdPitch(8);          % controller on, waits to settle
            %
            %   The surfaces (default both elevators) are set to follow the
            %   controller alone: no excitation (any armed excitation is
            %   disarmed), trim 0, ctrlGain = opts.ctrlGain. The gains are
            %   whatever you last gave setControl. "Settled" means within
            %   toleranceDeg of the target for stableS seconds; if that
            %   isn't reached in timeoutS a warning is issued and
            %   result.settled is false (the controller is left running).
            %
            %   Returns a struct: settled, pitchDeg, errorDeg, timeS.
            %
            %   ctrlGain's SIGN must make a positive controller output
            %   reduce the error. If the model runs away from the target
            %   instead, flip it (-1). THIS MOVES THE SURFACES AND THE MODEL.
            arguments
                obj
                targetDeg (1,1) double {mustBeFinite}
                opts.surfaces (1,:) wt.hasta.HDCh = [wt.hasta.HDCh.ElevR wt.hasta.HDCh.ElevL]
                opts.ctrlGain (1,1) double {mustBeInRange(opts.ctrlGain, -1, 1)} = 1
                opts.toleranceDeg (1,1) double {mustBePositive} = 0.25
                opts.stableS (1,1) double {mustBePositive} = 1
                opts.timeoutS (1,1) double {mustBePositive} = 30
                opts.pollS (1,1) double {mustBePositive} = 0.1
            end
            cfg = obj.getControl();
            if cfg.kp == 0 && cfg.ki == 0 && cfg.kd == 0
                warning("DaqClient:noGains", ...
                    "Kp, Ki and Kd are all 0 - the controller won't do anything. Set them with setControl first.");
            end
            obj.disarmExcitation();
            obj.setMix(opts.surfaces, trimDeg=0, excGain=0, ctrlGain=opts.ctrlGain);
            obj.setControl(targetDeg=targetDeg);
            obj.enableControl();

            t0 = tic;
            inBandSince = NaN;
            settled = false;
            pitchDeg = NaN;
            errorDeg = NaN;
            while toc(t0) < opts.timeoutS
                pitchDeg = obj.getEncoderDeg();
                errorDeg = targetDeg - pitchDeg;
                if abs(errorDeg) <= opts.toleranceDeg
                    if isnan(inBandSince)
                        inBandSince = toc(t0);
                    end
                    if toc(t0) - inBandSince >= opts.stableS
                        settled = true;
                        break
                    end
                else
                    inBandSince = NaN;
                end
                pause(opts.pollS);
            end
            result = struct("settled", settled, "pitchDeg", pitchDeg, ...
                "errorDeg", errorDeg, "timeS", toc(t0));
            if ~settled
                warning("DaqClient:notSettled", ...
                    "Pitch did not settle within %g deg of %g in %g s (it is at %.2f deg).", ...
                    opts.toleranceDeg, targetDeg, opts.timeoutS, pitchDeg);
            end
        end

        function data = capture(obj, durationS, sampleHz)
            %CAPTURE Record for durationS seconds and return the data: run,
            %wait for it to finish, read it back (a wt.hasta.DaqData).
            %Anything armed (see setExcitation) starts at the trigger, so
            %THIS CAN MOVE SURFACES. Call data.mean() for just the averages.
            arguments
                obj
                durationS (1,1) double {mustBePositive}
                sampleHz (1,1) double {mustBePositive} = 100
            end
            obj.run(durationS, sampleHz);
            obj.waitForDone(durationS + 30);
            data = obj.readData();
        end

        function trims = openLoopAtEquilibrium(obj, equilibrium, opts)
            %OPENLOOPATEQUILIBRIUM Switch the controller off without
            %jolting the model: the surfaces keep the angles they averaged
            %over a hold (equilibrium, from capture(...) while holding),
            %now as fixed trim. The trim change and ctrlGain = 0 go out in
            %ONE command, and only then is the controller disabled.
            %
            %   hd.holdPitch(8);
            %   eq = hd.capture(4);                        % equilibrium values
            %   hd.openLoopAtEquilibrium(eq, excGain=1);   % ready to excite
            %
            %   excGain (default 0) is set on the surfaces too, so the next
            %   excitation can ride on the equilibrium. Returns the trims.
            arguments
                obj
                equilibrium (1,1) wt.hasta.DaqData
                opts.surfaces (1,:) wt.hasta.HDCh = [wt.hasta.HDCh.ElevR wt.hasta.HDCh.ElevL]
                opts.excGain (1,1) double {mustBeInRange(opts.excGain, -1, 1)} = 0
            end
            trims = zeros(1, numel(opts.surfaces));
            for k = 1:numel(opts.surfaces)
                trims(k) = mean(equilibrium.Angle(opts.surfaces(k)), "omitnan");
            end
            if any(isnan(trims))
                error("DaqClient:noEquilibrium", "The equilibrium data has no angles for the surfaces.");
            end
            obj.setMix(opts.surfaces, trimDeg=trims, excGain=opts.excGain, ctrlGain=0);
            obj.disableControl();
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
            wt.hasta.DaqClient.checkReply(reply, "FIRE");
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
                error("DaqClient:badReply", "Unexpected STATUS? reply: %s", raw);
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
            error("DaqClient:timeout", ...
                "Capture did not finish within %g s (last status: %s)", timeoutS, s.raw);
        end

        function data = readData(obj)
            %READDATA Fetch the last completed capture (DATA?) as a
            %wt.hasta.DaqData object: one row per sample, with sensors,
            %excitation and each servo's commanded angle as its own
            %property (RUDDER_Angle, ELEV_R_Angle, ELEV_L_Angle,
            %AIL_R_Angle, AIL_L_Angle). See DaqData.m.
            % reading the capture is repeatable, so a stalled link is retried
            data = obj.withRetries("DATA?", true, @(~) obj.fetchData());
        end

        function deg = getEncoderDeg(obj)
            %GETENCODERDEG Return the current encoder angle in degrees
            %(latest reading on the board, no capture needed).
            reply = obj.query("ENCODER?");
            deg = str2double(reply);
            if isnan(deg)
                error("DaqClient:badReply", "ENCODER? -> %s", reply);
            end
        end

        function zeroEncoder(obj)
            %ZEROENCODER Make the encoder's current position the new 0.
            %Software zero only: it's held in RAM on the board and lost on
            %reboot/reflash, so re-zero after each power-up. Errors if the
            %PID loop is enabled (zeroing under it would step its error) -
            %call disableControl() first.
            reply = obj.query("ZERO");
            wt.hasta.DaqClient.checkReply(reply, "ZERO");
        end

        function offsetDeg = getEncoderZeroOffset(obj)
            %GETENCODERZEROOFFSET The raw encoder angle (0-360 deg) that
            %currently reads as 0. Call it once, right after zeroEncoder(),
            %and save the number: setEncoderZeroOffset puts the same zero
            %back later without moving the model to zero again.
            %
            %   hd.zeroEncoder();                      % model at zero
            %   offset = hd.getEncoderZeroOffset();    % keep this
            reply = obj.query("ZEROOFFSET?");
            offsetDeg = str2double(reply);
            if isnan(offsetDeg)
                error("DaqClient:badReply", "ZEROOFFSET? -> %s", reply);
            end
        end

        function setEncoderZeroOffset(obj, offsetDeg)
            %SETENCODERZEROOFFSET Re-apply a zero saved from
            %getEncoderZeroOffset, instead of zeroing again.
            %
            %   hd.setEncoderZeroOffset(offset);
            %
            %   The MT6835 is an absolute encoder, so this is valid across
            %   power cycles as long as the encoder hasn't moved relative to
            %   the model since the offset was taken, and the shaft is within
            %   +/-180 deg of that zero. Software only (RAM on the board).
            %   Errors if the PID loop is enabled - disableControl() first.
            arguments
                obj
                offsetDeg (1,1) double {mustBeFinite}
            end
            reply = obj.query("ZEROOFFSET " + sprintf("%.6f", offsetDeg));
            wt.hasta.DaqClient.checkReply(reply, "ZEROOFFSET");
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

        function sendChannelBodies(obj, body)
            %SENDCHANNELBODIES Send channel config(s) (a struct array, one
            %element per channel) as ONE CHANCONFIG command, applied together
            %on the board so the surfaces change in the same SBUS frame.
            %Older firmware only accepts one channel per CHANCONFIG and
            %answers a multi-channel array with "ERR unknown channel"
            %(changing nothing): fall back to one command per channel (not
            %synchronised) and remember it, so this warns only once.
            if obj.ChanArraySupported || isscalar(body)
                try
                    obj.sendJson("CHANCONFIG", body);
                    return
                catch ME
                    if isscalar(body) || ME.identifier ~= "DaqClient:boardError" ...
                            || ~contains(ME.message, "unknown channel")
                        rethrow(ME);
                    end
                    obj.ChanArraySupported = false;
                    warning("DaqClient:oldFirmware", ...
                        "The board's firmware can't move several surfaces in one command - " + ...
                        "update it for synchronised moves. Sending one at a time.");
                end
            end
            for k = 1:numel(body)
                obj.sendJson("CHANCONFIG", body(k));
            end
        end

        function connect(obj)
            %CONNECT (Re)open the TCP connection to the board.
            obj.Conn = [];   % drop any old connection first
            obj.Conn = tcpclient(obj.BoardIP, obj.Port, "Timeout", obj.TimeoutS);
            configureTerminator(obj.Conn, "LF");
        end

        function reply = readReply(obj, command)
            %READREPLY Read one reply line, or throw a clear error if the
            %board didn't answer within the timeout (readline then returns
            %empty and warns, which otherwise surfaces as a cryptic
            %error further on).
            reply = readline(obj.Conn);
            if isempty(reply) || ~isstring(reply) || ismissing(reply)
                error("DaqClient:noReply", ...
                    "No reply from the board to %s within %g s - WiFi dropped, board reset, or the connection went stale?", ...
                    command, obj.TimeoutS);
            end
        end

        function out = withRetries(obj, label, retriable, attemptFcn)
            %WITHRETRIES Run attemptFcn(attemptNumber) up to MaxAttempts
            %times. Any transport failure (no reply within TimeoutS, a dead
            %socket, a failed reconnect) reconnects and tries again after a
            %short pause; the final failure throws DaqClient:noReply.
            %Errors the client raises itself (DaqClient:* other than
            %noReply, e.g. a malformed reply) are not retried. If retriable
            %is false there is only the one attempt.
            lastMsg = "";
            for attempt = 1:obj.MaxAttempts
                try
                    if isempty(obj.Conn)
                        obj.connect();
                    end
                    obj.Conn.Timeout = obj.TimeoutS;   % pick up any change to TimeoutS
                    out = attemptFcn(attempt);
                    return
                catch ME
                    transport = ~startsWith(ME.identifier, "DaqClient:") ...
                        || ME.identifier == "DaqClient:noReply";
                    if ~transport
                        rethrow(ME);
                    end
                    lastMsg = ME.message;
                    if ~retriable || attempt == obj.MaxAttempts
                        break
                    end
                    warning("DaqClient:reconnect", ...
                        "%s: no reply (attempt %d of %d) - reconnecting and trying again.", ...
                        label, attempt, obj.MaxAttempts);
                    obj.Conn = [];             % forces a fresh connection next time round
                    obj.ReconnectCount = obj.ReconnectCount + 1;
                    pause(min(attempt, 5));    % brief back-off
                end
            end
            error("DaqClient:noReply", ...
                "No reply from the board to %s after %d attempt(s) of %g s - WiFi dropped, board reset, or the connection went stale? (%s)", ...
                label, attempt, obj.TimeoutS, lastMsg);
        end

        function reply = rawExchange(obj, text, command)
            %RAWEXCHANGE One send and one reply, no retries. text (one or
            %more complete lines) goes out in a single write; the first
            %reply line is returned trimmed (strtrim: the firmware's
            %println() sends CRLF, readline() only strips the LF).
            obj.flushInput();
            write(obj.Conn, uint8(char(text)));
            reply = strtrim(obj.readReply(command));
        end

        function reply = exchange(obj, text, command, mode, attempt)
            %EXCHANGE One attempt at a command. For "verify" commands (RUN,
            %FIRE) a repeat attempt first asks STATUS?, because the first
            %copy may have arrived and only its reply been lost: if a
            %capture is already running the command evidently worked, so
            %"OK" is returned instead of sending it again.
            if attempt > 1 && mode == "verify"
                state = obj.rawExchange("STATUS?" + newline, "STATUS?");
                if startsWith(state, "CAPTURING")
                    reply = "OK";
                    return
                elseif command == "FIRE" && ~startsWith(state, "ARMED")
                    % idle ("DONE") means either it never arrived or it has
                    % already finished: can't tell, so don't guess.
                    error("DaqClient:unverified", ...
                        "No reply to FIRE and the board is idle (%s): can't tell whether it was received. Check the capture before repeating it.", ...
                        state);
                end
            end
            reply = obj.rawExchange(text, command);
        end

        function reply = roundTrip(obj, text, command)
            %ROUNDTRIP Send a command (text = its complete line(s)) and
            %return the board's reply, retrying through WiFi stalls: see
            %retryMode for which commands may be sent again.
            mode = wt.hasta.DaqClient.retryMode(command);
            reply = obj.withRetries(command, mode ~= "none", ...
                @(attempt) obj.exchange(text, command, mode, attempt));
        end

        function data = fetchData(obj)
            %FETCHDATA One attempt at DATA?: header line, then the raw
            %sample bytes. A short payload counts as a stalled link.
            obj.flushInput();
            writeline(obj.Conn, "DATA?");
            header = strtrim(obj.readReply("DATA?"));
            parsed = sscanf(header, "BIN %d %d");
            if numel(parsed) ~= 2
                error("DaqClient:badReply", "Unexpected DATA? header: %s", header);
            end
            n = parsed(1);
            bytesPerSample = parsed(2);

            if n > 0
                raw = read(obj.Conn, n * bytesPerSample, "uint8");
            else
                raw = zeros(0, 1, "uint8");
            end
            if numel(raw) ~= n * bytesPerSample
                error("DaqClient:noReply", "DATA? payload incomplete (%d of %d bytes)", ...
                    numel(raw), n * bytesPerSample);
            end
            raw = reshape(uint8(raw(:)), bytesPerSample, n); % column k = sample k's bytes
            data = wt.hasta.DaqData.FromBytes(raw, bytesPerSample);
        end

        function reply = query(obj, command)
            %QUERY Send one command line, return the trimmed reply line.
            reply = obj.roundTrip(command + newline, command);
        end

        function sendJson(obj, command, body)
            %SENDJSON Two-line JSON command: command line, then the JSON
            %body as a second raw line; expects "OK" back. Both lines go out
            %in ONE write: as two small writes, TCP's Nagle algorithm holds
            %the second until the first is acknowledged, adding latency to
            %every command.
            lines = command + newline + jsonencode(body) + newline;
            reply = obj.roundTrip(lines, command);
            wt.hasta.DaqClient.checkReply(reply, command);
        end

        function cfg = queryJson(obj, command)
            reply = obj.query(command);
            if startsWith(reply, "ERR")
                error("DaqClient:boardError", "%s -> %s", command, reply);
            end
            cfg = jsondecode(reply);
        end
    end

    methods (Static)
        function str = formatHealth(h)
            %FORMATHEALTH One-line summary of a getHealth() result.
            wifi = "up";
            if ~h.wifiConnected
                wifi = "DOWN";
            end
            str = sprintf("uptime %.0f s | last reset: %s | WiFi %s %d dBm | max loop %.1f ms | clients %d in / %d out | WiFi drops %d | heap %.0f kB", ...
                h.uptimeS, h.resetReason, wifi, round(h.rssi), h.maxLoopMs, ...
                h.connects, h.disconnects, h.wifiDrops, h.freeHeap / 1024);
        end
    end

    methods (Static, Access = private)
        function mode = retryMode(command)
            %RETRYMODE How a command may be sent again if it gets no reply:
            %   "repeat" - harmless to send twice: queries ("...?"), the
            %              setters (they set absolute values), ARM and ZERO
            %              (re-doing either changes nothing)
            %   "verify" - RUN and FIRE: the first copy may have arrived,
            %              so STATUS? is checked before sending again
            %   "none"   - anything else: one attempt only
            word = extractBefore(string(command) + " ", " ");
            if endsWith(word, "?") || any(word == ["CHANCONFIG", "EXCITE", "CTRLCONFIG", ...
                    "TRIGCONFIG", "UDPCONFIG", "ARM", "ZERO", "ZEROOFFSET"])
                mode = "repeat";
            elseif any(word == ["RUN", "FIRE"])
                mode = "verify";
            else
                mode = "none";
            end
        end

        function checkReply(reply, command)
            if reply ~= "OK"
                error("DaqClient:boardError", "%s -> %s", command, reply);
            end
        end

        function id = channelId(channel)
            %CHANNELID wt.hasta.HDCh member -> its firmware name;
            %a raw name string or 0-4 index is passed through as-is.
            if isa(channel, "wt.hasta.HDCh")
                id = char(channel.WireName);
            elseif isstring(channel) || ischar(channel)
                id = char(channel);
            elseif isnumeric(channel) && isscalar(channel)
                id = channel;
            else
                error("DaqClient:badChannel", "channel must be an index or a name.");
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
                    error("DaqClient:badGain", "%s must be within [-1, 1].", g);
                end
            end
        end
    end
end
