# Port forward and DHCP reservation options
{ lib, schema }:

let
  inherit (lib) mkOption types;
in
{
  # Port forward options
  portForwardOpts =
    { name, ... }:
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Whether this port forward is enabled";
        };

        name = mkOption {
          type = types.str;
          default = name;
          description = "Name/description of the port forward";
        };

        protocol = mkOption {
          type = types.enum schema.portForwardProtocols;
          default = "tcp_udp";
          description = "Protocol to forward (values from device schema)";
        };

        srcPort = mkOption {
          type = types.either types.int types.str;
          description = "External port or port range (e.g., 80 or \"8000-8100\")";
          example = 443;
        };

        dstIP = mkOption {
          type = types.str;
          description = "Internal destination IP address";
          example = "192.168.1.100";
        };

        dstPort = mkOption {
          type = types.nullOr (types.either types.int types.str);
          default = null;
          description = "Internal destination port (null = same as srcPort)";
        };

        srcIP = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Limit to source IP/CIDR (null = any)";
          example = "0.0.0.0/0";
        };

        log = mkOption {
          type = types.bool;
          default = false;
          description = "Log forwarded packets";
        };
      };
    };

  # DHCP reservation options
  dhcpReservationOpts =
    { name, ... }:
    {
      options = {
        mac = mkOption {
          type = types.str;
          description = "MAC address of the device";
          example = "00:11:22:33:44:55";
        };

        ip = mkOption {
          type = types.str;
          description = "Fixed IP address to assign";
          example = "192.168.1.100";
        };

        name = mkOption {
          type = types.str;
          default = name;
          description = "Friendly name for the device";
        };

        network = mkOption {
          type = types.str;
          description = "Network this reservation belongs to";
          example = "Default";
        };
      };
    };
}
