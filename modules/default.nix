# Module option definitions loader
# Imports all submodule definitions for the UniFi module
{
  lib,
  schema,
  secretType,
}:

{
  # Import network options
  networkOpts = import ./networks.nix { inherit lib schema; };

  # Import WiFi options
  wifiOpts = import ./wifi.nix { inherit lib schema secretType; };

  # Import firewall options
  firewallOpts = import ./firewall.nix { inherit lib schema; };

  # Import VPN options
  vpnOpts = import ./vpn.nix { inherit lib secretType; };

  # Import group options (AP, User, DPI)
  groupOpts = import ./groups.nix { inherit lib schema; };

  # Import port forward and DHCP reservation options
  portForwardOpts = import ./port-forwards.nix { inherit lib schema; };

  # Import port profile options
  portProfileOpts = import ./port-profiles.nix { inherit lib schema; };

  # Import RADIUS profile options
  radiusOpts = import ./radius.nix { inherit lib secretType; };

  # Import traffic rule options
  trafficRuleOpts = import ./traffic-rules.nix { inherit lib schema; };

  # Import validation helpers
  validation = import ./validation.nix { inherit lib; };
}
