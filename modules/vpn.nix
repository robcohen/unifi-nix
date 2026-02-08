# VPN configuration options (WireGuard and Site-to-Site)
{ lib, secretType }:

let
  inherit (lib) mkOption types;
in
{
  # WireGuard VPN server options
  serverOpts = {
    options = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable WireGuard VPN server";
      };

      port = mkOption {
        type = types.int;
        default = 51820;
        description = "WireGuard server port";
      };

      network = mkOption {
        type = types.str;
        default = "192.168.2.0/24";
        description = "VPN client network CIDR";
        example = "10.8.0.0/24";
      };

      dns = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "DNS servers to push to VPN clients";
        example = [
          "1.1.1.1"
          "8.8.8.8"
        ];
      };

      allowedNetworks = mkOption {
        type = types.listOf types.str;
        default = [ "0.0.0.0/0" ];
        description = "Networks clients can access (split tunnel)";
        example = [
          "192.168.1.0/24"
          "192.168.10.0/24"
        ];
      };
    };
  };

  # WireGuard VPN client/peer options
  peerOpts =
    { name, ... }:
    {
      options = {
        name = mkOption {
          type = types.str;
          default = name;
          description = "Peer name (for identification)";
        };

        publicKey = mkOption {
          type = types.str;
          description = "WireGuard public key of the peer";
        };

        presharedKey = mkOption {
          type = types.nullOr secretType;
          default = null;
          description = "Optional preshared key for additional security";
        };

        allowedIPs = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "IP addresses allowed for this peer";
          example = [ "192.168.2.10/32" ];
        };
      };
    };

  # Site-to-site VPN options
  siteToSiteOpts =
    { name, ... }:
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Whether this VPN tunnel is enabled";
        };

        name = mkOption {
          type = types.str;
          default = name;
          description = "VPN tunnel name";
        };

        type = mkOption {
          type = types.enum [
            "ipsec"
            "openvpn"
            "wireguard"
          ];
          default = "ipsec";
          description = "VPN tunnel type";
        };

        remoteHost = mkOption {
          type = types.str;
          description = "Remote VPN endpoint IP or hostname";
          example = "vpn.example.com";
        };

        remoteNetworks = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Remote networks accessible via this tunnel";
          example = [ "10.0.0.0/24" ];
        };

        localNetworks = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Local networks to expose to remote site";
          example = [ "192.168.1.0/24" ];
        };

        presharedKey = mkOption {
          type = secretType;
          description = "Shared secret for the VPN tunnel";
        };

        # IPsec specific
        ipsec = {
          ikeVersion = mkOption {
            type = types.enum [
              1
              2
            ];
            default = 2;
            description = "IKE version";
          };

          encryption = mkOption {
            type = types.str;
            default = "aes256";
            description = "Encryption algorithm";
          };

          hash = mkOption {
            type = types.str;
            default = "sha256";
            description = "Hash algorithm";
          };

          dhGroup = mkOption {
            type = types.int;
            default = 14;
            description = "Diffie-Hellman group";
          };
        };
      };
    };
}
