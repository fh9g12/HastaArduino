classdef MetaData
    %METADATA Context for one test point: which run/test it was, what the
    %surfaces were doing, how the model was set up, and where it was saved.
    %   Stored alongside the wt.hasta.DaqData and wt.OHBData for the same test
    %   point (one of each per point, in parallel arrays).
    %
    %   meta = wt.hasta.MetaData(RunNumber=3, TestNumber=0, TestType="Steady", ...
    %                   Filename="data/run03.mat", ModelConfig=cfg, ...
    %                   Parameters=struct(AoA_deg=2, ElevatorDeg=3));
    %
    %   RunNumber   from wt.runNum; each recording script takes the next one
    %               when it starts
    %   TestType    what the surfaces were doing: Steady | Sine | Cosine | Chirp
    %               | Step (an elevator step response, scripts.FreePitchStep),
    %               or Zero for a wind-off zeroing run (scripts.ZeroRun)
    %   ZeroRun     file of the most recent zero run when this was taken
    %               (wt.hasta.getLastZeroRun), so the force sensors can be zeroed in
    %               post-processing - nothing is subtracted at acquisition
    %   TestNumber  starts at 0 and increases through a run
    %   Parameters  free-form struct for the test point's setpoints
    %               (AoA, surface angle, excitation frequency, ...)

    properties
        Datetime = NaT                      % creation time unless you set it
        RunNumber (1,1) double = NaN
        TestNumber (1,1) double = NaN
        TestType (1,1) string {mustBeMember(TestType, ["Steady", "Sine", "Cosine", "Chirp", "Step", "Zero"])} = "Steady"
        Filename (1,1) string = ""          % where the data is saved
        ZeroRun (1,1) string = ""           % file of the last zero run (for zeroing the force sensors in post-processing)
        ModelConfig (1,1) wt.hasta.ModelConfig = wt.hasta.ModelConfig()
        Parameters (1,1) struct = struct()
        Notes (1,1) string = ""
    end

    methods
        function obj = MetaData(varargin)
            %METADATA Construct, optionally with Name=Value property settings.
            if mod(numel(varargin), 2) ~= 0
                error("MetaData:badArgs", "Give Name=Value pairs.");
            end
            obj.Datetime = datetime("now");
            for k = 1:2:numel(varargin)
                obj.(varargin{k}) = varargin{k + 1};
            end
        end

        function out = ToStruct(obj)
            %TOSTRUCT All properties as a struct (wt.hasta.ModelConfig as a nested struct).
            names = properties(obj);
            out = struct();
            for k = 1:numel(names)
                out.(names{k}) = obj.(names{k});
            end
            out.ModelConfig = obj.ModelConfig.ToStruct();
        end
    end
end
