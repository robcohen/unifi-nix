# Traffic rule options (QoS, rate limiting, app blocking)
{ lib, schema }:

let
  inherit (lib) mkOption types;
in
{
  options =
    { name, ... }:
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Whether this rule is enabled";
        };

        name = mkOption {
          type = types.str;
          default = name;
          description = "Rule name";
        };

        description = mkOption {
          type = types.str;
          default = "";
          description = "Rule description";
        };

        action = mkOption {
          type = types.enum schema.trafficRuleActions;
          default = "BLOCK";
          description = "Action to take (values from device schema)";
        };

        matchingTarget = mkOption {
          type = types.enum schema.trafficRuleTargets;
          default = "INTERNET";
          description = "What to match against (values from device schema)";
        };

        networkId = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Network name to apply this rule to (null = all)";
        };

        bandwidthLimit = {
          download = mkOption {
            type = types.nullOr types.int;
            default = null;
            description = "Download limit in kbps (for QOS_RATE_LIMIT action)";
          };
          upload = mkOption {
            type = types.nullOr types.int;
            default = null;
            description = "Upload limit in kbps (for QOS_RATE_LIMIT action)";
          };
        };

        schedule = {
          mode = mkOption {
            type = types.enum [
              "ALWAYS"
              "CUSTOM"
            ];
            default = "ALWAYS";
            description = "Schedule mode";
          };
        };

        index = mkOption {
          type = types.int;
          default = 4000;
          description = "Rule priority (lower = higher priority)";
        };
      };
    };
}
