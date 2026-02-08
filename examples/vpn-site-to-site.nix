# Example: Site-to-Site VPN with WireGuard
#
# This example shows how to set up:
# - WireGuard VPN server for remote clients
# - Site-to-site IPsec VPN to another office
# - Split tunneling for efficient routing
{
  unifi = {
    host = "192.168.1.1";
    site = "default";

    networks = {
      # Main office network
      Default = {
        subnet = "192.168.1.1/24";
        purpose = "corporate";
        networkGroup = "LAN";
        dhcp = {
          enable = true;
          start = "192.168.1.100";
          end = "192.168.1.254";
          dns = [ "192.168.1.1" ];
        };
      };

      # Server VLAN
      Servers = {
        vlan = 50;
        subnet = "192.168.50.1/24";
        purpose = "corporate";
        networkGroup = "LAN";
        dhcp = {
          enable = true;
          start = "192.168.50.100";
          end = "192.168.50.254";
          dns = [ "192.168.1.1" ];
        };
      };
    };

    wifi = {
      main = {
        ssid = "OfficeNetwork";
        passphrase = {
          _secret = "wifi/main";
        };
        network = "Default";
        security = "wpapsk";
        wpa3.enable = true;
        bands = [
          "2g"
          "5g"
        ];
      };
    };

    # VPN configuration
    vpn = {
      # WireGuard VPN for remote workers
      wireguard = {
        server = {
          enable = true;
          port = 51820;
          network = "192.168.2.0/24"; # VPN client subnet
          dns = [ "192.168.1.1" ]; # Use office DNS

          # Split tunnel - only route office networks through VPN
          allowedNetworks = [
            "192.168.1.0/24" # Main office
            "192.168.50.0/24" # Servers
            "10.0.0.0/24" # Branch office (via site-to-site)
          ];
        };

        # VPN clients
        peers = {
          ceo-laptop = {
            publicKey = "abc123..."; # Replace with actual key
            allowedIPs = [ "192.168.2.10/32" ];
          };
          cto-laptop = {
            publicKey = "def456...";
            allowedIPs = [ "192.168.2.11/32" ];
          };
          it-admin = {
            publicKey = "ghi789...";
            allowedIPs = [ "192.168.2.20/32" ];
            presharedKey = {
              _secret = "vpn/it-admin-psk";
            };
          };
        };
      };

      # Site-to-site VPN to branch office
      siteToSite = {
        branch-office = {
          enable = true;
          type = "ipsec";
          remoteHost = "branch.example.com";
          remoteNetworks = [ "10.0.0.0/24" ];
          localNetworks = [
            "192.168.1.0/24"
            "192.168.50.0/24"
          ];
          presharedKey = {
            _secret = "vpn/branch-psk";
          };

          ipsec = {
            ikeVersion = 2;
            encryption = "aes256";
            hash = "sha256";
            dhGroup = 14;
          };
        };

        # Backup datacenter connection
        datacenter = {
          enable = true;
          type = "ipsec";
          remoteHost = "dc.example.com";
          remoteNetworks = [ "10.10.0.0/24" ];
          localNetworks = [ "192.168.50.0/24" ]; # Only servers
          presharedKey = {
            _secret = "vpn/dc-psk";
          };

          ipsec = {
            ikeVersion = 2;
            encryption = "aes256gcm16";
            hash = "sha512";
            dhGroup = 21;
          };
        };
      };
    };

    # Port forwards for VPN
    portForwards = {
      wireguard = {
        srcPort = 51820;
        dstIP = "192.168.1.1"; # UDM handles WireGuard
        protocol = "udp";
      };
    };

    # Firewall policies for VPN traffic
    firewall.policies = {
      # Allow VPN clients to access internal networks
      allow-vpn-to-internal = {
        action = "allow";
        sourceZone = "vpn";
        sourceType = "any";
        destinationZone = "internal";
        destinationType = "any";
        index = 5000;
      };

      # Allow VPN clients to access servers
      allow-vpn-to-servers = {
        action = "allow";
        sourceZone = "vpn";
        sourceType = "any";
        destinationZone = "internal";
        destinationType = "network";
        destinationNetworks = [ "Servers" ];
        index = 5001;
      };

      # Block VPN from management network by default
      block-vpn-to-mgmt = {
        action = "block";
        sourceZone = "vpn";
        sourceType = "any";
        destinationZone = "gateway";
        destinationType = "any";
        index = 9000;
      };

      # Allow specific VPN users to manage (IT admin)
      allow-it-vpn-mgmt = {
        action = "allow";
        sourceZone = "vpn";
        sourceType = "ip";
        sourceIPs = [ "192.168.2.20" ]; # IT admin's VPN IP
        destinationZone = "gateway";
        destinationType = "any";
        index = 8000;
      };
    };
  };
}
