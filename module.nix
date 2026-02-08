# UniFi declarative configuration module
# Defines options for networks, WiFi, firewall policies, and more
{ lib, config, ... }:

let
  inherit (lib)
    mkOption
    types
    literalExpression
    ;

  # Load schema enums from device schema (Nix-time validation)
  schemaLib = import ./lib/schema.nix { inherit lib; };
  inherit (schemaLib) schema;

  # Schema-based option generator (for adding new collections)
  fromSchema = import ./lib/from-schema.nix { inherit lib; };

  # Secret reference type - can be a plain string or { _secret = "path"; }
  secretType = types.either types.str (
    types.submodule {
      options._secret = mkOption {
        type = types.str;
        description = "Path to secret (resolved at deploy time via sops/agenix)";
      };
    }
  );

  # Load modular option definitions
  modules = import ./modules { inherit lib schema secretType; };

  # Configuration reference
  cfg = config.unifi;

  # Use validation from module
  validationResult = modules.validation.validate cfg;

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

    schemaVersion = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Pin to a specific UniFi schema version.

        By default, the latest available schema is used. Set this to pin
        to a specific version for reproducibility or compatibility.

        Available versions: ${builtins.concatStringsSep ", " fromSchema.availableVersions}
        Current latest: ${fromSchema.latestVersion or "none"}
      '';
      example = "10.0.162";
    };

    networks = mkOption {
      type = types.attrsOf (types.submodule modules.networkOpts);
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
      type = types.attrsOf (types.submodule modules.wifiOpts);
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
      type = types.attrsOf (types.submodule modules.portForwardOpts.portForwardOpts);
      default = { };
      description = "Port forwarding rules (NAT)";
      example = literalExpression ''
        {
          https = {
            srcPort = 443;
            dstIP = "192.168.1.100";
            protocol = "tcp";
          };
        }
      '';
    };

    dhcpReservations = mkOption {
      type = types.attrsOf (types.submodule modules.portForwardOpts.dhcpReservationOpts);
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
      policies = mkOption {
        type = types.attrsOf (types.submodule modules.firewallOpts.policyOpts);
        default = { };
        description = ''
          Zone-based firewall policies (UniFi 10.x+).

          IMPORTANT: The zone-based firewall must be enabled on your UDM first.
          Go to Settings > Firewall & Security > "Upgrade to Zone-Based Firewall".
        '';
        example = literalExpression ''
          {
            block-iot-to-default = {
              action = "block";
              sourceZone = "internal";
              sourceType = "network";
              sourceNetworks = [ "IoT" ];
              destinationZone = "internal";
              destinationType = "network";
              destinationNetworks = [ "Default" ];
            };
          }
        '';
      };

      groups = mkOption {
        type = types.attrsOf (types.submodule modules.firewallOpts.groupOpts);
        default = { };
        description = "Firewall groups for use in policies.";
        example = literalExpression ''
          {
            trusted-servers = {
              type = "address-group";
              members = [ "192.168.1.100" "192.168.1.101" ];
            };
          }
        '';
      };
    };

    apGroups = mkOption {
      type = types.attrsOf (types.submodule modules.groupOpts.apGroupOpts);
      default = { };
      description = "Access Point groups for assigning SSIDs to specific APs.";
      example = literalExpression ''
        {
          office = {
            devices = [ "00:11:22:33:44:55" ];
          };
        }
      '';
    };

    userGroups = mkOption {
      type = types.attrsOf (types.submodule modules.groupOpts.userGroupOpts);
      default = { };
      description = "User groups for bandwidth limiting and rate limiting.";
      example = literalExpression ''
        {
          limited = {
            downloadLimit = 10000;
            uploadLimit = 5000;
          };
        }
      '';
    };

    trafficRules = mkOption {
      type = types.attrsOf (types.submodule modules.trafficRuleOpts.options);
      default = { };
      description = "Traffic rules for QoS, rate limiting, and app blocking.";
      example = literalExpression ''
        {
          block-social-media = {
            action = "BLOCK";
            matchingTarget = "INTERNET";
          };
        }
      '';
    };

    radiusProfiles = mkOption {
      type = types.attrsOf (types.submodule modules.radiusOpts.options);
      default = { };
      description = "RADIUS profiles for WPA-Enterprise authentication.";
      example = literalExpression ''
        {
          corporate = {
            authServers = [
              { ip = "192.168.1.10"; port = 1812; secret = { _secret = "radius/corp"; }; }
            ];
          };
        }
      '';
    };

    portProfiles = mkOption {
      type = types.attrsOf (types.submodule modules.portProfileOpts.options);
      default = { };
      description = "Switch port profiles for VLAN tagging and PoE control.";
      example = literalExpression ''
        {
          trunk = {
            forward = "customize";
            nativeNetwork = "Default";
            taggedNetworks = [ "IoT" "Guest" ];
          };
        }
      '';
    };

    dpiGroups = mkOption {
      type = types.attrsOf (types.submodule modules.groupOpts.dpiGroupOpts);
      default = { };
      description = "DPI groups for application blocking.";
      example = literalExpression ''
        {
          social-media = {
            categories = [ "Social" ];
          };
        }
      '';
    };

    vpn = {
      wireguard = {
        server = mkOption {
          type = types.submodule modules.vpnOpts.serverOpts;
          default = { };
          description = "WireGuard VPN server configuration";
        };

        peers = mkOption {
          type = types.attrsOf (types.submodule modules.vpnOpts.peerOpts);
          default = { };
          description = "WireGuard VPN peers (clients)";
          example = literalExpression ''
            {
              laptop = {
                publicKey = "abc123...";
                allowedIPs = [ "192.168.2.10/32" ];
              };
            }
          '';
        };
      };

      siteToSite = mkOption {
        type = types.attrsOf (types.submodule modules.vpnOpts.siteToSiteOpts);
        default = { };
        description = "Site-to-site VPN tunnels.";
        example = literalExpression ''
          {
            office-to-datacenter = {
              type = "ipsec";
              remoteHost = "vpn.datacenter.example.com";
              remoteNetworks = [ "10.0.0.0/24" ];
              localNetworks = [ "192.168.1.0/24" ];
              presharedKey = { _secret = "vpn/datacenter"; };
            };
          }
        '';
      };
    };

    # =========================================================================
    # Schema-generated options (auto-generated from MongoDB schema)
    # =========================================================================

    scheduledTasks = fromSchema.mkCollectionOption "scheduletask" ''
      Scheduled tasks for automated actions.
    '';

    wlanGroups = fromSchema.mkCollectionOption "wlangroup" ''
      WLAN groups for controlling which APs broadcast which SSIDs.
    '';

    globalSettings = fromSchema.mkCollectionOption "setting" ''
      Global UniFi controller settings.
    '';

    alertSettings = fromSchema.mkCollectionOption "alert_setting" ''
      Alert and notification settings.
    '';

    # Firewall zones for zone-based firewall (UniFi 10.x+)
    firewallZones = fromSchema.mkCollectionOption "firewall_zone" ''
      Firewall zone definitions for zone-based firewall.

      Zones group networks for policy application. Default zones include:
      internal, external, gateway, vpn, hotspot, dmz.
    '';

    # DNS over HTTPS servers
    dohServers = fromSchema.mkCollectionOption "doh_servers" ''
      DNS over HTTPS (DoH) server configurations.

      Configure custom DoH servers for encrypted DNS queries.
    '';

    # SSL inspection profiles
    sslInspectionProfiles = fromSchema.mkCollectionOption "ssl_inspection_profile" ''
      SSL/TLS inspection profiles for HTTPS traffic inspection.

      Configure which traffic to inspect and which to bypass.
    '';

    # Custom dashboards
    dashboards = fromSchema.mkCollectionOption "dashboard" ''
      Custom dashboard configurations.

      Define custom monitoring dashboards for the UniFi controller.
    '';

    # Diagnostics configuration
    diagnosticsConfig = fromSchema.mkCollectionOption "diagnostics_config" ''
      Diagnostics and troubleshooting settings.

      Configure diagnostic data collection and reporting.
    '';
  };

  # Export validation results for use in to-mongo.nix
  config.unifi._validation = validationResult;
}
