# Example: Switch port profiles configuration
# Use port profiles to configure VLANs, PoE, and port settings for switches
{
  unifi = {
    host = "192.168.1.1";
    site = "default";

    # ==========================================================================
    # Networks - Define VLANs first
    # ==========================================================================
    networks = {
      Default = {
        subnet = "192.168.1.1/24";
        dhcp = {
          enable = true;
          start = "192.168.1.100";
          end = "192.168.1.254";
          dns = [ "1.1.1.1" ];
        };
      };

      Management = {
        vlan = 5;
        subnet = "192.168.5.1/24";
        dhcp.enable = false;
      };

      Servers = {
        vlan = 10;
        subnet = "192.168.10.1/24";
        dhcp = {
          enable = true;
          start = "192.168.10.100";
          end = "192.168.10.254";
        };
      };

      IoT = {
        vlan = 20;
        subnet = "192.168.20.1/24";
        isolate = true;
        dhcp = {
          enable = true;
          start = "192.168.20.100";
          end = "192.168.20.254";
        };
      };

      Cameras = {
        vlan = 30;
        subnet = "192.168.30.1/24";
        isolate = true;
        dhcp = {
          enable = true;
          start = "192.168.30.100";
          end = "192.168.30.254";
        };
      };
    };

    # ==========================================================================
    # Port Profiles
    # ==========================================================================
    # Port profiles are templates that can be applied to switch ports.
    # Define profiles here, then apply them in UniFi UI: Devices > Switch > Ports
    portProfiles = {
      # Standard desktop/laptop port - untagged on Default
      workstation = {
        name = "Workstation";
        forward = "native";
        nativeNetwork = "Default";
        poeMode = "auto";
        speed = "autoneg";
      };

      # Server port - untagged on Servers VLAN
      server = {
        name = "Server";
        forward = "native";
        nativeNetwork = "Servers";
        poeMode = "off"; # Servers usually have their own power
        speed = "autoneg";
      };

      # Trunk port for access points - carries multiple VLANs
      ap-trunk = {
        name = "AP Trunk";
        forward = "customize";
        nativeNetwork = "Default";
        taggedNetworks = [
          "IoT"
          "Cameras"
        ]; # APs serve these VLANs too
        poeMode = "auto"; # PoE for the AP
        speed = "autoneg";
      };

      # Trunk for hypervisors/VMware - needs multiple VLANs
      hypervisor = {
        name = "Hypervisor";
        forward = "customize";
        nativeNetwork = "Management";
        taggedNetworks = [
          "Default"
          "Servers"
          "IoT"
          "Cameras"
        ];
        poeMode = "off";
        speed = "autoneg";
      };

      # PoE cameras - isolated VLAN, PoE enabled
      camera = {
        name = "Camera";
        forward = "native";
        nativeNetwork = "Cameras";
        poeMode = "auto";
        speed = "autoneg";
        isolation = true; # Port isolation for extra security
      };

      # IoT devices - isolated, storm control enabled
      iot = {
        name = "IoT Device";
        forward = "native";
        nativeNetwork = "IoT";
        poeMode = "auto";
        speed = "autoneg";
        stormControl = {
          enable = true;
          rate = 80; # 80% rate limit on broadcasts
        };
      };

      # Disabled port - for unused ports
      disabled = {
        name = "Disabled";
        forward = "disabled";
        poeMode = "off";
        speed = "disabled";
      };

      # 10G uplink between switches
      uplink-10g = {
        name = "10G Uplink";
        forward = "all";
        poeMode = "off";
        speed = "10000"; # Force 10 Gbps
      };
    };

    # ==========================================================================
    # WiFi (optional - for reference)
    # ==========================================================================
    wifi = {
      main = {
        ssid = "MyNetwork";
        passphrase = {
          _secret = "wifi/main";
        };
        network = "Default";
      };
    };
  };
}
