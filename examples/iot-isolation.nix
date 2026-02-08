# Example: IoT Network Isolation
#
# This example shows how to set up a separate IoT VLAN that:
# - Has its own WiFi network
# - Cannot access the main network
# - Can still access the internet
# - Can be reached from the main network (for management)
{
  unifi = {
    host = "192.168.1.1";
    site = "default";

    networks = {
      # Main network (default VLAN)
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

      # IoT network on VLAN 10
      IoT = {
        vlan = 10;
        subnet = "192.168.10.1/24";
        purpose = "corporate";
        networkGroup = "LAN";

        # Network isolation blocks traffic TO this network
        # IoT devices can still reach the internet
        isolate = true;

        # Disable mDNS to prevent discovery from main network
        mdns = false;

        dhcp = {
          enable = true;
          start = "192.168.10.100";
          end = "192.168.10.254";
          # Use UDM as DNS to block unwanted domains
          dns = [ "192.168.10.1" ];
        };
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
        wpa3 = {
          enable = true;
          transition = true;
        };
        bands = [
          "2g"
          "5g"
        ];
      };

      # IoT WiFi - separate SSID for IoT devices
      iot = {
        ssid = "HomeNetwork-IoT";
        passphrase = {
          _secret = "wifi/iot";
        };
        network = "IoT";
        security = "wpapsk";

        # Many IoT devices don't support WPA3
        wpa3.enable = false;

        # Only 2.4GHz for better compatibility
        bands = [ "2g" ];

        # Hide from casual discovery
        hidden = false;
      };
    };

    # Firewall policies for fine-grained control
    firewall.policies = {
      # Block IoT from accessing main network
      block-iot-to-main = {
        action = "block";
        sourceZone = "internal";
        sourceType = "network";
        sourceNetworks = [ "IoT" ];
        destinationZone = "internal";
        destinationType = "network";
        destinationNetworks = [ "Default" ];
        index = 10000;
      };

      # Allow IoT to access DNS on gateway
      allow-iot-dns = {
        action = "allow";
        sourceZone = "internal";
        sourceType = "network";
        sourceNetworks = [ "IoT" ];
        destinationZone = "gateway";
        destinationType = "any";
        destinationPort = 53;
        protocol = "tcp_udp";
        index = 9000;
      };

      # Allow main network to manage IoT devices
      allow-main-to-iot = {
        action = "allow";
        sourceZone = "internal";
        sourceType = "network";
        sourceNetworks = [ "Default" ];
        destinationZone = "internal";
        destinationType = "network";
        destinationNetworks = [ "IoT" ];
        index = 9500;
      };
    };

    # Static IPs for important IoT devices
    dhcpReservations = {
      smart-hub = {
        mac = "aa:bb:cc:dd:ee:01";
        ip = "192.168.10.10";
        network = "IoT";
      };
      thermostat = {
        mac = "aa:bb:cc:dd:ee:02";
        ip = "192.168.10.11";
        network = "IoT";
      };
    };
  };
}
