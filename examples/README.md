# Example Configurations

This directory contains example configurations for common scenarios.

## Examples

| File                                         | Description                               |
| -------------------------------------------- | ----------------------------------------- |
| [home.nix](home.nix)                         | Basic home network setup                  |
| [iot-isolation.nix](iot-isolation.nix)       | IoT network with VLAN isolation           |
| [guest-network.nix](guest-network.nix)       | Guest network with bandwidth limiting     |
| [enterprise-wifi.nix](enterprise-wifi.nix)   | WPA-Enterprise with RADIUS                |
| [vpn-site-to-site.nix](vpn-site-to-site.nix) | WireGuard and IPsec VPNs                  |
| [port-profiles.nix](port-profiles.nix)       | Switch port profiles (VLANs, PoE, trunks) |
| [traffic-rules.nix](traffic-rules.nix)       | QoS, bandwidth limits, app blocking       |

## Usage

1. Copy an example to your sites directory:

   ```bash
   cp examples/iot-isolation.nix sites/mysite.nix
   ```

1. Edit to match your network:

   ```bash
   $EDITOR sites/mysite.nix
   ```

1. Set required secrets:

   ```bash
   export WIFI_MAIN="your-password"
   export WIFI_IOT="iot-password"
   ```

1. Deploy:

   ```bash
   nix run .#diff -- sites/mysite.nix 192.168.1.1
   nix run .#deploy -- sites/mysite.nix 192.168.1.1
   ```

## Secrets

Examples use secret references like `{ _secret = "wifi/main"; }`. Set these via:

1. **Environment variables**: `WIFI_MAIN=password`
1. **Secret files**: `$UNIFI_SECRETS_DIR/wifi/main`

See the main README for sops-nix integration.
