classdef ModelConfig
    %MODELCONFIG How the wind-tunnel model was set up for a test.
    %
    %   cfg = wt.hasta.ModelConfig(TankType="Liquid", TankDiameter_mm=40, FuelMass_g=150);
    %
    %   Defaults are deliberately "not set" (NaN) apart from TankType, which
    %   has to be something, so check you've filled all three in.

    properties
        TankType (1,1) string {mustBeMember(TankType, ["Solid", "Liquid"])} = "Solid"  % solid mass or liquid water
        TankDiameter_mm (1,1) double = NaN   % tank diameter, mm
        FuelMass_g (1,1) double = NaN        % mass of the "fuel" (water or solid), g
    end

    methods
        function obj = ModelConfig(varargin)
            %MODELCONFIG Construct, optionally with Name=Value property settings.
            if mod(numel(varargin), 2) ~= 0
                error("ModelConfig:badArgs", "Give Name=Value pairs.");
            end
            for k = 1:2:numel(varargin)
                obj.(varargin{k}) = varargin{k + 1};
            end
        end

        function out = ToStruct(obj)
            out = struct("TankType", obj.TankType, ...
                "TankDiameter_mm", obj.TankDiameter_mm, ...
                "FuelMass_g", obj.FuelMass_g);
        end
    end
end
