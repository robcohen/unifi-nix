# Firewall policy and group options
{ lib, schema }:

let
  inherit (lib) mkOption types;
in
{
  # Firewall group options (IP/port groups for use in policies)
  groupOpts =
    { name, ... }:
    {
      options = {
        name = mkOption {
          type = types.str;
          default = name;
          description = "Group name";
        };

        type = mkOption {
          type = types.enum schema.firewallGroupTypes;
          default = "address-group";
          description = "Group type (values from device schema)";
        };

        members = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Group members (IPs, CIDRs, or ports depending on type)";
          example = [
            "192.168.1.100"
            "10.0.0.0/8"
          ];
        };
      };
    };

  # Zone-based firewall policy options (UniFi 10.x+)
  policyOpts =
    { name, ... }:
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Whether this policy is enabled";
        };

        name = mkOption {
          type = types.str;
          default = name;
          description = "Policy name";
        };

        description = mkOption {
          type = types.str;
          default = "";
          description = "Policy description";
        };

        action = mkOption {
          type = types.enum schema.policyActions;
          default = "block";
          description = "Action to take (values from device schema)";
        };

        sourceZone = mkOption {
          type = types.enum schema.zoneKeys;
          default = "internal";
          description = "Source zone (values from device schema)";
        };

        sourceType = mkOption {
          type = types.enum schema.matchingTargets;
          default = "any";
          description = "Source matching type (values from device schema)";
        };

        sourceNetworks = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Source network names (when sourceType = network)";
          example = [
            "IoT"
            "Media"
          ];
        };

        sourceIPs = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Source IP addresses/CIDRs (when sourceType = ip)";
          example = [
            "192.168.10.100"
            "192.168.20.0/24"
          ];
        };

        sourcePort = mkOption {
          type = types.nullOr (types.either types.int types.str);
          default = null;
          description = "Source port or port range (null = any)";
          example = "1024-65535";
        };

        destinationZone = mkOption {
          type = types.enum schema.zoneKeys;
          default = "internal";
          description = "Destination zone (values from device schema)";
        };

        destinationType = mkOption {
          type = types.enum schema.matchingTargets;
          default = "any";
          description = "Destination matching type (values from device schema)";
        };

        destinationNetworks = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Destination network names (when destinationType = network)";
          example = [ "Default" ];
        };

        destinationIPs = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Destination IP addresses/CIDRs (when destinationType = ip)";
          example = [ "192.168.1.100" ];
        };

        destinationPort = mkOption {
          type = types.nullOr (types.either types.int types.str);
          default = null;
          description = "Destination port or port range (null = any)";
          example = 443;
        };

        protocol = mkOption {
          type = types.enum schema.policyProtocols;
          default = "all";
          description = "Protocol to match (values from device schema)";
        };

        ipVersion = mkOption {
          type = types.enum schema.policyIpVersions;
          default = "both";
          description = "IP version to match (values from device schema)";
        };

        connectionState = mkOption {
          type = types.enum schema.connectionStateTypes;
          default = "ALL";
          description = "Connection state matching (values from device schema)";
        };

        logging = mkOption {
          type = types.bool;
          default = false;
          description = "Enable syslog logging for matched packets";
        };

        index = mkOption {
          type = types.int;
          default = 10000;
          description = "Rule priority (lower = higher priority, user rules typically 10000+)";
        };
      };
    };
}
