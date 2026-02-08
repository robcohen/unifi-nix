# Switch port profile options
{ lib, schema }:

let
  inherit (lib) mkOption types;
in
{
  options =
    { name, ... }:
    {
      options = {
        name = mkOption {
          type = types.str;
          default = name;
          description = "Port profile name";
        };

        forward = mkOption {
          type = types.enum schema.portProfileForwards;
          default = "all";
          description = "VLAN forwarding mode (values from device schema)";
        };

        nativeNetwork = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Native (untagged) network name";
        };

        taggedNetworks = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Tagged network names (when forward = customize)";
          example = [
            "Management"
            "IoT"
          ];
        };

        poeMode = mkOption {
          type = types.enum schema.poeModes;
          default = "auto";
          description = "PoE power mode";
        };

        speed = mkOption {
          type = types.enum schema.portSpeeds;
          default = "autoneg";
          description = "Port speed setting";
        };

        stormControl = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = "Enable storm control";
          };
          rate = mkOption {
            type = types.int;
            default = 100;
            description = "Storm control rate percentage (1-100)";
          };
        };

        isolation = mkOption {
          type = types.bool;
          default = false;
          description = "Enable port isolation";
        };
      };
    };
}
