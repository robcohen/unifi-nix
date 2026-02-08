# Example: Enterprise WiFi with RADIUS Authentication
#
# This example shows how to set up WPA-Enterprise (802.1X) WiFi:
# - RADIUS authentication server integration
# - Separate employee and contractor networks
# - Dynamic VLAN assignment based on user group
{
  unifi = {
    host = "192.168.1.1";
    site = "default";

    networks = {
      # Management network
      Management = {
        subnet = "192.168.1.1/24";
        purpose = "corporate";
        networkGroup = "LAN";
        dhcp = {
          enable = true;
          start = "192.168.1.100";
          end = "192.168.1.254";
          dns = [ "192.168.1.10" ]; # Internal DNS
        };
      };

      # Employee network
      Employees = {
        vlan = 100;
        subnet = "192.168.100.1/24";
        purpose = "corporate";
        networkGroup = "LAN";
        dhcp = {
          enable = true;
          start = "192.168.100.100";
          end = "192.168.100.254";
          dns = [ "192.168.1.10" ];
        };
      };

      # Contractor network (more restricted)
      Contractors = {
        vlan = 200;
        subnet = "192.168.200.1/24";
        purpose = "corporate";
        networkGroup = "LAN";
        # Contractors isolated from internal resources
        isolate = true;
        dhcp = {
          enable = true;
          start = "192.168.200.100";
          end = "192.168.200.254";
          dns = [
            "1.1.1.1"
            "8.8.8.8"
          ]; # Public DNS only
        };
      };
    };

    # RADIUS profile for enterprise authentication
    radiusProfiles = {
      # Main RADIUS profile with redundant servers
      corporate-radius = {
        authServers = [
          {
            ip = "192.168.1.10";
            port = 1812;
            secret = {
              _secret = "radius/primary";
            };
          }
          {
            ip = "192.168.1.11";
            port = 1812;
            secret = {
              _secret = "radius/secondary";
            };
          }
        ];
        acctServers = [
          {
            ip = "192.168.1.10";
            port = 1813;
            secret = {
              _secret = "radius/primary";
            };
          }
        ];
      };
    };

    wifi = {
      # Enterprise WiFi with 802.1X
      corporate = {
        ssid = "CorpNetwork";
        network = "Employees"; # Default VLAN, can be overridden by RADIUS

        # WPA-Enterprise (802.1X)
        security = "wpaeap";

        # No PSK needed - RADIUS handles auth
        passphrase = ""; # Not used with wpaeap

        wpa3 = {
          enable = true;
          transition = true;
        };

        # Enable fast roaming for laptops
        fastRoaming = true;
        bssTransition = true;

        bands = [ "5g" ]; # 5GHz only for better performance
      };

      # Guest WiFi for visitors (PSK-based for simplicity)
      guest = {
        ssid = "CorpGuest";
        passphrase = {
          _secret = "wifi/guest";
        };
        network = "Contractors"; # Contractor VLAN
        security = "wpapsk";
        guestMode = true;
        clientIsolation = true;
        bands = [
          "2g"
          "5g"
        ];
      };
    };

    # Firewall policies
    firewall.policies = {
      # Allow employees to access all internal resources
      allow-employees-internal = {
        action = "allow";
        sourceZone = "internal";
        sourceType = "network";
        sourceNetworks = [ "Employees" ];
        destinationZone = "internal";
        destinationType = "any";
        index = 5000;
      };

      # Block contractors from internal resources
      block-contractors-internal = {
        action = "block";
        sourceZone = "internal";
        sourceType = "network";
        sourceNetworks = [ "Contractors" ];
        destinationZone = "internal";
        destinationType = "network";
        destinationNetworks = [
          "Management"
          "Employees"
        ];
        index = 10000;
      };

      # Allow contractors to access internet only
      allow-contractors-internet = {
        action = "allow";
        sourceZone = "internal";
        sourceType = "network";
        sourceNetworks = [ "Contractors" ];
        destinationZone = "external";
        destinationType = "any";
        index = 10001;
      };
    };

    # Firewall groups for IP-based access
    firewall.groups = {
      # Critical servers that need extra protection
      critical-servers = {
        type = "address-group";
        members = [
          "192.168.1.10" # Domain controller
          "192.168.1.11" # Backup DC
          "192.168.1.20" # File server
        ];
      };

      # Allowed management ports
      management-ports = {
        type = "port-group";
        members = [
          "22"
          "3389"
          "5900"
        ];
      };
    };
  };
}
