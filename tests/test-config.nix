# Test configuration covering all major features
{
  unifi = {
    host = "192.168.1.1";
    site = "default";

    networks = {
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

      IoT = {
        vlan = 10;
        subnet = "192.168.10.1/24";
        purpose = "corporate";
        networkGroup = "LAN";
        isolate = true;
        dhcp = {
          enable = true;
          start = "192.168.10.100";
          end = "192.168.10.254";
        };
      };

      Guest = {
        vlan = 20;
        subnet = "192.168.20.1/24";
        purpose = "guest";
        networkGroup = "LAN";
        dhcp = {
          enable = true;
          start = "192.168.20.100";
          end = "192.168.20.254";
        };
      };
    };

    wifi = {
      main = {
        ssid = "TestNetwork";
        passphrase = "testpassword123";
        network = "Default";
        security = "wpapsk";
        bands = [
          "2g"
          "5g"
        ];
      };

      guest = {
        ssid = "TestGuest";
        passphrase = "guestpass456";
        network = "Guest";
        security = "wpapsk";
        bands = [
          "2g"
          "5g"
        ];
      };
    };

    firewall = {
      policies = {
        block-iot-to-default = {
          action = "block";
          sourceZone = "internal";
          sourceType = "network";
          sourceNetworks = [ "IoT" ];
          destinationZone = "internal";
          destinationType = "network";
          destinationNetworks = [ "Default" ];
        };

        allow-iot-to-internet = {
          action = "allow";
          sourceZone = "internal";
          sourceType = "network";
          sourceNetworks = [ "IoT" ];
          destinationZone = "external";
        };
      };

      groups = {
        trusted-ips = {
          type = "address-group";
          members = [
            "192.168.1.10"
            "192.168.1.11"
          ];
        };

        web-ports = {
          type = "port-group";
          members = [
            "80"
            "443"
          ];
        };
      };
    };

    portForwards = {
      https = {
        srcPort = 443;
        dstIP = "192.168.1.100";
        protocol = "tcp";
      };

      ssh = {
        srcPort = 2222;
        dstPort = 22;
        dstIP = "192.168.1.100";
        protocol = "tcp";
      };
    };

    dhcpReservations = {
      server = {
        mac = "aa:bb:cc:dd:ee:ff";
        ip = "192.168.1.100";
        network = "Default";
      };
    };
  };
}
