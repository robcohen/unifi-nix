# Network (VLAN) configuration options
{ lib, schema }:

let
  inherit (lib) mkOption mkEnableOption types;
in
{
  options = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Whether this network is enabled";
    };

    vlan = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = "VLAN ID. null for untagged/default network.";
      example = 10;
    };

    subnet = mkOption {
      type = types.str;
      description = "Network subnet in CIDR notation (gateway/prefix)";
      example = "192.168.10.1/24";
    };

    purpose = mkOption {
      type = types.enum schema.networkPurposes;
      default = "corporate";
      description = "Network purpose/type (values from device schema)";
    };

    networkGroup = mkOption {
      type = types.enum schema.networkGroups;
      default = "LAN";
      description = "Network group (values from device schema)";
    };

    dhcp = {
      enable = mkEnableOption "DHCP server for this network";

      start = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "DHCP range start IP";
        example = "192.168.10.6";
      };

      end = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "DHCP range end IP";
        example = "192.168.10.254";
      };

      dns = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "DNS servers to advertise via DHCP";
        example = [
          "76.76.2.44"
          "76.76.10.44"
        ];
      };

      leasetime = mkOption {
        type = types.int;
        default = 86400;
        description = "DHCP lease time in seconds";
      };
    };

    isolate = mkOption {
      type = types.bool;
      default = false;
      description = "Isolate this network from other VLANs (block inter-VLAN routing)";
    };

    internetAccess = mkOption {
      type = types.bool;
      default = true;
      description = "Whether devices on this network can access the internet";
    };

    mdns = mkOption {
      type = types.bool;
      default = true;
      description = "Enable mDNS/Bonjour forwarding";
    };

    igmpSnooping = mkOption {
      type = types.bool;
      default = false;
      description = "Enable IGMP snooping for multicast optimization";
    };
  };
}
