# Example: Traffic rules configuration
# Traffic rules provide QoS, bandwidth limiting, and application blocking
{
  unifi = {
    host = "192.168.1.1";
    site = "default";

    # ==========================================================================
    # Networks
    # ==========================================================================
    networks = {
      Default = {
        subnet = "192.168.1.1/24";
        dhcp = {
          enable = true;
          start = "192.168.1.100";
          end = "192.168.1.254";
        };
      };

      Kids = {
        vlan = 20;
        subnet = "192.168.20.1/24";
        dhcp = {
          enable = true;
          start = "192.168.20.100";
          end = "192.168.20.254";
        };
      };

      Guest = {
        vlan = 30;
        subnet = "192.168.30.1/24";
        purpose = "guest";
        dhcp = {
          enable = true;
          start = "192.168.30.100";
          end = "192.168.30.254";
        };
      };

      WorkFromHome = {
        vlan = 40;
        subnet = "192.168.40.1/24";
        dhcp = {
          enable = true;
          start = "192.168.40.100";
          end = "192.168.40.254";
        };
      };
    };

    # ==========================================================================
    # Traffic Rules
    # ==========================================================================
    # Traffic rules provide application-level control and QoS.
    # Use these for bandwidth limits, app blocking, and traffic shaping.
    trafficRules = {
      # Block social media on Kids network during school hours
      # (Actual schedule config requires UI - this sets up the rule)
      block-social-kids = {
        name = "Block Social Media - Kids";
        description = "Block social media sites on Kids network";
        enable = true;
        action = "BLOCK";
        matchingTarget = "INTERNET";
        networkId = "Kids";
        index = 1000;
        # Note: App categories are configured in UniFi UI under Traffic Rules
        # This example shows the structure; actual app matching requires UI
      };

      # Rate limit guest network to prevent bandwidth hogging
      guest-rate-limit = {
        name = "Guest Bandwidth Limit";
        description = "Limit guest network to 25 Mbps down / 10 Mbps up";
        enable = true;
        action = "QOS_RATE_LIMIT";
        matchingTarget = "INTERNET";
        networkId = "Guest";
        bandwidthLimit = {
          download = 25000; # 25 Mbps in kbps
          upload = 10000; # 10 Mbps in kbps
        };
        index = 2000;
      };

      # Prioritize video conferencing on Work From Home network
      prioritize-video = {
        name = "Prioritize Video Calls";
        description = "High priority for video conferencing traffic";
        enable = true;
        action = "QOS_PRIORITY_HIGH";
        matchingTarget = "INTERNET";
        networkId = "WorkFromHome";
        index = 500; # Lower index = higher priority
        # Note: Specific app matching (Zoom, Teams, etc.) requires UI config
      };

      # Block P2P/torrents on all networks
      block-p2p = {
        name = "Block P2P";
        description = "Block peer-to-peer file sharing";
        enable = true;
        action = "BLOCK";
        matchingTarget = "INTERNET";
        networkId = null; # null = apply to all networks
        index = 100;
        # App group configuration done in UI
      };

      # Limit IoT devices to low bandwidth
      iot-bandwidth = {
        name = "IoT Bandwidth Limit";
        description = "Limit IoT devices to prevent abuse";
        enable = false; # Disabled by default - enable if needed
        action = "QOS_RATE_LIMIT";
        matchingTarget = "INTERNET";
        networkId = "IoT";
        bandwidthLimit = {
          download = 10000; # 10 Mbps
          upload = 5000; # 5 Mbps
        };
        index = 3000;
      };

      # Block gaming on Kids network (example of another category)
      block-gaming-kids = {
        name = "Block Gaming - Kids";
        description = "Block gaming sites and services on Kids network";
        enable = true;
        action = "BLOCK";
        matchingTarget = "INTERNET";
        networkId = "Kids";
        index = 1100;
      };
    };

    # ==========================================================================
    # WiFi
    # ==========================================================================
    wifi = {
      main = {
        ssid = "MyNetwork";
        passphrase = {
          _secret = "wifi/main";
        };
        network = "Default";
      };

      kids = {
        ssid = "MyNetwork-Kids";
        passphrase = {
          _secret = "wifi/kids";
        };
        network = "Kids";
      };

      guest = {
        ssid = "MyNetwork-Guest";
        passphrase = {
          _secret = "wifi/guest";
        };
        network = "Guest";
        clientIsolation = true;
      };

      wfh = {
        ssid = "MyNetwork-WFH";
        passphrase = {
          _secret = "wifi/wfh";
        };
        network = "WorkFromHome";
      };
    };
  };
}
