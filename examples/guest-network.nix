# Example: Guest Network with Bandwidth Limiting
#
# This example shows how to set up a guest network that:
# - Is completely isolated from internal networks
# - Has bandwidth limits per user
# - Uses a captive portal (optional)
{
  unifi = {
    host = "192.168.1.1";
    site = "default";

    networks = {
      # Main network
      Default = {
        subnet = "192.168.1.1/24";
        purpose = "corporate";
        networkGroup = "LAN";
        dhcp = {
          enable = true;
          start = "192.168.1.100";
          end = "192.168.1.254";
          dns = [
            "1.1.1.1"
            "8.8.8.8"
          ];
        };
      };

      # Guest network on VLAN 30
      Guest = {
        vlan = 30;
        subnet = "192.168.30.1/24";

        # "guest" purpose provides automatic isolation
        purpose = "guest";
        networkGroup = "LAN";

        # Short DHCP lease for guests
        dhcp = {
          enable = true;
          start = "192.168.30.100";
          end = "192.168.30.254";
          dns = [
            "1.1.1.1"
            "8.8.8.8"
          ];
          leasetime = 3600; # 1 hour
        };

        # Disable mDNS to prevent service discovery
        mdns = false;
      };
    };

    wifi = {
      # Main WiFi
      main = {
        ssid = "HomeNetwork";
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

      # Guest WiFi
      guest = {
        ssid = "Guest";
        passphrase = {
          _secret = "wifi/guest";
        };
        network = "Guest";
        security = "wpapsk";

        # Enable guest mode for captive portal support
        guestMode = true;

        # Isolate wireless clients from each other
        clientIsolation = true;

        # WPA2 for compatibility
        wpa3.enable = false;

        bands = [
          "2g"
          "5g"
        ];
      };
    };

    # User groups for bandwidth limiting
    userGroups = {
      # Guest users get limited bandwidth
      guest-limited = {
        downloadLimit = 10000; # 10 Mbps
        uploadLimit = 5000; # 5 Mbps
      };
    };

    # Traffic rules for guest network
    trafficRules = {
      # Rate limit guest network
      limit-guest-bandwidth = {
        action = "QOS_RATE_LIMIT";
        matchingTarget = "INTERNET";
        networkId = "Guest";
        bandwidthLimit = {
          download = 50000; # 50 Mbps total for network
          upload = 20000; # 20 Mbps total for network
        };
      };
    };

    # Firewall policies
    firewall.policies = {
      # Block guests from accessing any internal networks
      block-guest-to-internal = {
        action = "block";
        sourceZone = "internal";
        sourceType = "network";
        sourceNetworks = [ "Guest" ];
        destinationZone = "internal";
        destinationType = "any";
        index = 10000;
      };

      # Block guests from accessing the gateway/management
      block-guest-to-gateway = {
        action = "block";
        sourceZone = "internal";
        sourceType = "network";
        sourceNetworks = [ "Guest" ];
        destinationZone = "gateway";
        destinationType = "any";
        index = 10001;
      };

      # Allow DNS for guests (required for internet)
      allow-guest-dns = {
        action = "allow";
        sourceZone = "internal";
        sourceType = "network";
        sourceNetworks = [ "Guest" ];
        destinationZone = "gateway";
        destinationPort = 53;
        protocol = "tcp_udp";
        index = 9000;
      };

      # Allow DHCP for guests
      allow-guest-dhcp = {
        action = "allow";
        sourceZone = "internal";
        sourceType = "network";
        sourceNetworks = [ "Guest" ];
        destinationZone = "gateway";
        destinationPort = 67;
        protocol = "udp";
        index = 9001;
      };
    };
  };
}
