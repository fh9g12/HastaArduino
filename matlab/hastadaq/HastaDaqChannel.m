classdef HastaDaqChannel
    %HASTADAQCHANNEL The five HastaDAQ control surfaces.
    %   Use these instead of channel-name strings or indices:
    %
    %   hd.setChannel(HastaDaqChannel.ElevL, trimDeg=2)
    %
    %   The declaration order below is the column order of
    %   readData().servoDeg, and WireName must match CHANNEL_DEFS in
    %   HastaDAQ/ChannelMixer.h. If you rename or reorder channels there,
    %   change this file to match:
    %
    %       servoDeg column:  1      2      3      4     5
    %                         Rudder ElevR  ElevL  AilR  AilL

    properties (SetAccess = immutable)
        WireName (1,1) string   % name the firmware's CHANNEL_DEFS uses
    end

    methods
        function obj = HastaDaqChannel(wireName)
            obj.WireName = wireName;
        end

        function c = column(obj)
            %COLUMN Index of this channel in readData().servoDeg.
            c = find(enumeration("HastaDaqChannel") == obj, 1);
        end
    end

    enumeration
        Rudder ("RUDDER")
        ElevR  ("ELEV_R")
        ElevL  ("ELEV_L")
        AilR   ("AIL_R")
        AilL   ("AIL_L")
    end
end
