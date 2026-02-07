# Example: Home network configuration
# Copy this file and customize for your site
{
  unifi = {
    host = "192.168.1.1";  # Your UDM IP
    site = "default";

    # ==========================================================================
    # Networks (VLANs)
    # ==========================================================================
    networks = {
      # Main trusted network
      Default = {
        subnet = "192.168.1.1/24";
        dhcp = {
          enable = true;
          start = "192.168.1.100";
          end = "192.168.1.254";
          dns = [ "1.1.1.1" "8.8.8.8" ];
        };
      };

      # IoT devices - isolated from main network
      IoT = {
        vlan = 10;
        subnet = "192.168.10.1/24";
        dhcp = {
          enable = true;
          start = "192.168.10.100";
          end = "192.168.10.254";
          dns = [ "1.1.1.1" ];
        };
        isolate = true;  # Block inter-VLAN routing
        mdns = false;
      };

      # Guest network
      Guest = {
        vlan = 30;
        subnet = "192.168.30.1/24";
        purpose = "guest";
        dhcp = {
          enable = true;
          start = "192.168.30.100";
          end = "192.168.30.254";
          dns = [ "1.1.1.1" ];
        };
        isolate = true;
      };
    };

    # ==========================================================================
    # WiFi Networks
    # ==========================================================================
    wifi = {
      # Main WiFi - WPA3 with WPA2 fallback
      main = {
        ssid = "MyNetwork";
        passphrase = { _secret = "wifi/main"; };  # Resolved at deploy time
        network = "Default";
        wpa3 = {
          enable = true;
          transition = true;
        };
      };

      # IoT WiFi - hidden, WPA2 for compatibility
      iot = {
        ssid = "MyNetwork-IoT";
        passphrase = { _secret = "wifi/iot"; };
        network = "IoT";
        hidden = true;
        wpa3.enable = false;
      };

      # Guest WiFi
      guest = {
        ssid = "MyNetwork-Guest";
        passphrase = { _secret = "wifi/guest"; };
        network = "Guest";
        wpa3.enable = true;
        clientIsolation = true;
        guestMode = true;
      };
    };

    # ==========================================================================
    # Firewall Rules
    # ==========================================================================
    firewall.rules = {
      # Block IoT from accessing main network
      block-iot-to-lan = {
        from = "IoT";
        to = "Default";
        action = "drop";
        description = "Isolate IoT devices";
        index = 2001;
      };

      # Block guests from all private networks
      block-guest-to-private = {
        from = "Guest";
        to = [ "Default" "IoT" ];
        action = "drop";
        description = "Isolate guest network";
        index = 2000;
      };
    };
  };
}
