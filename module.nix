# UniFi declarative configuration module
# Defines options for networks, WiFi, and firewall rules
{ lib, config, ... }:

let
  inherit (lib)
    mkOption
    mkEnableOption
    types
    literalExpression
    ;

  # Secret reference type - can be a plain string or { _secret = "path"; }
  secretType = types.either types.str (
    types.submodule {
      options._secret = mkOption {
        type = types.str;
        description = "Path to secret (resolved at deploy time via sops/agenix)";
      };
    }
  );

  # Network configuration options
  networkOpts = _: {
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
        type = types.enum [
          "corporate"
          "guest"
          "wan"
          "vlan-only"
          "remote-user-vpn"
          "site-vpn"
        ];
        default = "corporate";
        description = "Network purpose/type";
      };

      networkGroup = mkOption {
        type = types.enum [
          "LAN"
          "WAN"
          "WAN2"
        ];
        default = "LAN";
        description = "Network group (LAN for internal networks, WAN/WAN2 for uplinks)";
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
  };

  # WiFi network configuration options
  wifiOpts = _: {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether this WiFi network is enabled";
      };

      ssid = mkOption {
        type = types.str;
        description = "WiFi network name (SSID)";
        example = "MyNetwork";
      };

      passphrase = mkOption {
        type = secretType;
        description = "WiFi password (can be secret reference)";
        example = literalExpression ''{ _secret = "wifi/main"; }'';
      };

      network = mkOption {
        type = types.str;
        description = "Name of the network (VLAN) this WiFi should use";
        example = "iot";
      };

      hidden = mkOption {
        type = types.bool;
        default = false;
        description = "Hide SSID from broadcast";
      };

      security = mkOption {
        type = types.enum [
          "wpapsk"
          "wpa2"
          "wpa3"
          "open"
        ];
        default = "wpapsk";
        description = "Security mode";
      };

      wpa3 = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Enable WPA3 support";
        };

        transition = mkOption {
          type = types.bool;
          default = true;
          description = "WPA3 transition mode (WPA2+WPA3 for compatibility)";
        };
      };

      pmf = mkOption {
        type = types.enum [
          "disabled"
          "optional"
          "required"
        ];
        default = "optional";
        description = "Protected Management Frames mode";
      };

      clientIsolation = mkOption {
        type = types.bool;
        default = false;
        description = "Isolate wireless clients from each other";
      };

      multicastEnhance = mkOption {
        type = types.bool;
        default = false;
        description = "Convert multicast to unicast for streaming";
      };

      bands = mkOption {
        type = types.listOf (
          types.enum [
            "2g"
            "5g"
            "6g"
          ]
        );
        default = [
          "2g"
          "5g"
        ];
        description = "WiFi bands to broadcast on";
      };

      minRate = {
        "2g" = mkOption {
          type = types.int;
          default = 1000;
          description = "Minimum data rate for 2.4GHz in kbps";
        };
        "5g" = mkOption {
          type = types.int;
          default = 6000;
          description = "Minimum data rate for 5GHz in kbps";
        };
      };

      guestMode = mkOption {
        type = types.bool;
        default = false;
        description = "Enable guest mode (captive portal ready)";
      };

      fastRoaming = mkOption {
        type = types.bool;
        default = false;
        description = "Enable 802.11r Fast BSS Transition for faster roaming";
      };

      bssTransition = mkOption {
        type = types.bool;
        default = true;
        description = "Enable 802.11v BSS Transition Management";
      };

      macFilter = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Enable MAC address filtering";
        };

        policy = mkOption {
          type = types.enum [
            "allow"
            "deny"
          ];
          default = "allow";
          description = "MAC filter policy (allow = whitelist, deny = blacklist)";
        };

        list = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "List of MAC addresses to filter";
          example = [
            "00:11:22:33:44:55"
            "AA:BB:CC:DD:EE:FF"
          ];
        };
      };

      apGroups = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "AP groups to broadcast this SSID (empty = all)";
      };
    };
  };

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
          type = types.enum [
            "tcp"
            "udp"
            "tcp_udp"
          ];
          default = "tcp_udp";
          description = "Protocol to forward";
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

  # Firewall rule options
  firewallRuleOpts = _: {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
      };

      description = mkOption {
        type = types.str;
        default = "";
      };

      action = mkOption {
        type = types.enum [
          "accept"
          "drop"
          "reject"
        ];
        default = "drop";
      };

      from = mkOption {
        type = types.either types.str (types.listOf types.str);
        description = "Source network(s) or 'any'";
        example = "iot";
      };

      to = mkOption {
        type = types.either types.str (types.listOf types.str);
        description = "Destination network(s) or 'any'";
        example = "default";
      };

      protocol = mkOption {
        type = types.enum [
          "all"
          "tcp"
          "udp"
          "icmp"
          "tcp_udp"
        ];
        default = "all";
      };

      ports = mkOption {
        type = types.nullOr (types.listOf types.int);
        default = null;
        description = "Destination ports (null = all)";
        example = [
          80
          443
        ];
      };

      index = mkOption {
        type = types.int;
        default = 2000;
        description = "Rule priority (lower = higher priority)";
      };
    };
  };

  # Validation helpers
  cfg = config.unifi;

  # Get all VLAN IDs that are set
  vlanIds = lib.filter (v: v != null) (lib.mapAttrsToList (_: n: n.vlan) cfg.networks);

  # Check for duplicate VLANs
  duplicateVlans = lib.filter (v: lib.count (x: x == v) vlanIds > 1) vlanIds;

  # Get all network names
  networkNames = lib.attrNames cfg.networks;

  # Check WiFi network references
  wifiNetworkRefs = lib.mapAttrsToList (_: w: w.network) cfg.wifi;
  invalidWifiRefs = lib.filter (n: !(lib.elem n networkNames)) wifiNetworkRefs;

  # Check firewall rule network references
  flattenNetworks = nets: if builtins.isList nets then nets else [ nets ];
  firewallFromRefs = lib.flatten (
    lib.mapAttrsToList (_: r: flattenNetworks r.from) cfg.firewall.rules
  );
  firewallToRefs = lib.flatten (lib.mapAttrsToList (_: r: flattenNetworks r.to) cfg.firewall.rules);
  allFirewallRefs = firewallFromRefs ++ firewallToRefs;
  invalidFirewallRefs = lib.filter (n: n != "any" && !(lib.elem n networkNames)) allFirewallRefs;

  # Power of 2 helper
  pow2 = n: if n == 0 then 1 else 2 * pow2 (n - 1);

  # Parse subnet to get network address for overlap detection
  parseSubnetForOverlap =
    subnet:
    let
      parts = lib.splitString "/" subnet;
      ip = builtins.elemAt parts 0;
      prefix = lib.toInt (builtins.elemAt parts 1);
      ipParts = map lib.toInt (lib.splitString "." ip);
      # Convert IP to integer for comparison
      ipInt =
        (builtins.elemAt ipParts 0) * 16777216
        + (builtins.elemAt ipParts 1) * 65536
        + (builtins.elemAt ipParts 2) * 256
        + (builtins.elemAt ipParts 3);
      # Calculate network size
      hostBits = 32 - prefix;
      networkSize = if hostBits >= 32 then 4294967296 else pow2 hostBits;
    in
    {
      inherit ipInt networkSize prefix;
    };

  # Get all subnets with their parsed info
  subnetInfos = lib.mapAttrsToList (name: n: {
    inherit name;
    info = parseSubnetForOverlap n.subnet;
    inherit (n) subnet;
  }) cfg.networks;

  # Check if two subnets overlap
  subnetsOverlap =
    a: b:
    let
      aStart = a.info.ipInt;
      aEnd = a.info.ipInt + a.info.networkSize - 1;
      bStart = b.info.ipInt;
      bEnd = b.info.ipInt + b.info.networkSize - 1;
    in
    aStart <= bEnd && bStart <= aEnd;

  # Find overlapping subnet pairs
  findOverlaps =
    subnets:
    let
      pairs = lib.filter (p: p.a.name < p.b.name) (
        lib.concatMap (a: map (b: { inherit a b; }) subnets) subnets
      );
    in
    lib.filter (p: subnetsOverlap p.a p.b) pairs;

  overlappingSubnets = findOverlaps subnetInfos;

in
{
  options.unifi = {
    host = mkOption {
      type = types.str;
      description = "UDM IP address or hostname";
      example = "192.168.1.1";
    };

    site = mkOption {
      type = types.str;
      default = "default";
      description = "UniFi site name";
    };

    networks = mkOption {
      type = types.attrsOf (types.submodule networkOpts);
      default = { };
      description = "Network (VLAN) configurations";
      example = literalExpression ''
        {
          iot = {
            vlan = 10;
            subnet = "192.168.10.1/24";
            dhcp.enable = true;
            isolate = true;
          };
        }
      '';
    };

    wifi = mkOption {
      type = types.attrsOf (types.submodule wifiOpts);
      default = { };
      description = "WiFi network configurations";
      example = literalExpression ''
        {
          main = {
            ssid = "MyNetwork";
            passphrase = { _secret = "wifi/main"; };
            network = "default";
            wpa3.enable = true;
          };
        }
      '';
    };

    # Internal validation results (not user-facing)
    _validation = mkOption {
      type = types.attrsOf types.unspecified;
      internal = true;
      default = { };
    };

    portForwards = mkOption {
      type = types.attrsOf (types.submodule portForwardOpts);
      default = { };
      description = "Port forwarding rules (NAT)";
      example = literalExpression ''
        {
          https = {
            srcPort = 443;
            dstIP = "192.168.1.100";
            protocol = "tcp";
          };
          minecraft = {
            srcPort = 25565;
            dstIP = "192.168.1.50";
          };
        }
      '';
    };

    dhcpReservations = mkOption {
      type = types.attrsOf (types.submodule dhcpReservationOpts);
      default = { };
      description = "Static DHCP reservations (fixed IPs)";
      example = literalExpression ''
        {
          server = {
            mac = "00:11:22:33:44:55";
            ip = "192.168.1.100";
            network = "Default";
          };
        }
      '';
    };

    firewall = {
      rules = mkOption {
        type = types.attrsOf (types.submodule firewallRuleOpts);
        default = { };
        description = "Firewall/traffic rules";
        example = literalExpression ''
          {
            block-iot-to-lan = {
              from = "iot";
              to = "default";
              action = "drop";
            };
          }
        '';
      };
    };
  };

  # Export validation results for use in to-mongo.nix
  config.unifi._validation = {
    inherit
      duplicateVlans
      invalidWifiRefs
      invalidFirewallRefs
      overlappingSubnets
      networkNames
      ;
  };
}
