# UniFi site configuration
# Edit this file to define your networks, WiFi, and firewall rules
{
  unifi = {
    # UDM/UDR IP address or hostname
    host = "192.168.1.1";

    # Site name (usually "default")
    site = "default";

    # Networks (VLANs)
    networks = {
      Default = {
        subnet = "192.168.1.1/24";
        purpose = "corporate";
        dhcp = {
          enable = true;
          start = "192.168.1.100";
          end = "192.168.1.254";
        };
      };

      # Example: IoT network on VLAN 10
      # IoT = {
      #   vlan = 10;
      #   subnet = "192.168.10.1/24";
      #   purpose = "corporate";
      #   isolate = true;  # Block inter-VLAN routing
      #   dhcp = {
      #     enable = true;
      #     start = "192.168.10.100";
      #     end = "192.168.10.254";
      #   };
      # };
    };

    # WiFi networks
    wifi = {
      main = {
        ssid = "MyNetwork";
        passphrase = "changeme"; # Use { _secret = "path/to/secret"; } for sops
        network = "Default";
        security = "wpapsk";
        bands = [
          "2g"
          "5g"
        ];
      };

      # Example: Guest network
      # guest = {
      #   ssid = "Guest";
      #   passphrase = "guestpass";
      #   network = "Guest";
      #   security = "wpapsk";
      # };
    };

    # Zone-based firewall policies (UniFi 10.x+)
    firewall.policies = {
      # Example: Block IoT from accessing main network
      # block-iot-to-default = {
      #   action = "block";
      #   sourceZone = "internal";
      #   sourceType = "network";
      #   sourceNetworks = [ "IoT" ];
      #   destinationZone = "internal";
      #   destinationType = "network";
      #   destinationNetworks = [ "Default" ];
      # };
    };

    # Port forwarding
    portForwards = {
      # Example: Forward port 443 to internal server
      # https = {
      #   srcPort = 443;
      #   dstIP = "192.168.1.100";
      #   protocol = "tcp";
      # };
    };
  };
}
