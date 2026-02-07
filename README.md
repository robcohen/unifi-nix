# unifi-nix

[![CI](https://github.com/robcohen/unifi-nix/actions/workflows/ci.yml/badge.svg)](https://github.com/robcohen/unifi-nix/actions/workflows/ci.yml)
[![FlakeHub](https://img.shields.io/endpoint?url=https://flakehub.com/f/robcohen/unifi-nix/badge)](https://flakehub.com/flake/robcohen/unifi-nix)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Declarative UniFi Dream Machine configuration via Nix.

Define your networks, WiFi, firewall rules, port forwards, and DHCP reservations in Nix. Preview changes with `diff`. Validate before deploy. Apply with `deploy`.

## Why?

- **Ubiquiti's official API is limited** - The Integration API doesn't cover all features
- **The Terraform provider is broken** and poorly maintained
- **The UI is not declarative** - No GitOps, no version control, no review process

This tool provides a fully declarative approach to UniFi configuration with automatic schema validation.

## Features

- **Declarative configuration** - Define your entire network in Nix
- **Schema validation** - Automatically validates against UniFi's OpenAPI schema
- **Diff before deploy** - Preview all changes before applying
- **Secret management** - Integrates with sops-nix/agenix
- **Version tracking** - Schemas are versioned per UniFi Network Application version

## Requirements

- UniFi Dream Machine (UDM, UDM-Pro, UDM-SE, UCG-Ultra, etc.) with SSH access
- Nix with flakes enabled
- SSH key authentication to your UDM (`ssh root@<udm-ip>`)

## Quick Start

```bash
# Add to your flake
nix flake init -t github:robcohen/unifi-nix

# Or clone directly
git clone https://github.com/robcohen/unifi-nix
cd unifi-nix

# Copy and edit the example config
cp examples/home.nix sites/mysite.nix
$EDITOR sites/mysite.nix

# Evaluate config to JSON
nix run .#eval -- sites/mysite.nix > config.json

# Preview changes
nix run .#diff -- config.json 192.168.1.1

# Validate configuration
nix run .#validate -- config.json

# Apply (with secrets)
export WIFI_MAIN="your-password"
nix run .#deploy -- config.json 192.168.1.1
```

## Installation

### As a Flake Input

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    unifi-nix.url = "github:robcohen/unifi-nix";
  };

  outputs = { self, nixpkgs, unifi-nix }: {
    # Your site config
    unifiConfigurations.home = unifi-nix.lib.mkSite {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      config = import ./sites/home.nix;
    };
  };
}
```

### Using the Overlay

```nix
{
  nixpkgs.overlays = [ unifi-nix.overlays.default ];
}
# Then use: pkgs.unifi-nix.deploy, pkgs.unifi-nix.diff, etc.
```

## Configuration Options

### Networks

```nix
networks = {
  Default = {
    subnet = "192.168.1.1/24";      # Gateway IP / prefix
    vlan = null;                     # VLAN ID (null = untagged)
    purpose = "corporate";           # corporate | guest | vlan-only

    dhcp = {
      enable = true;
      start = "192.168.1.100";
      end = "192.168.1.254";
      dns = [ "1.1.1.1" "8.8.8.8" ];
      leasetime = 86400;             # seconds
    };

    isolate = false;                 # Block inter-VLAN routing
    internetAccess = true;
    mdns = true;                     # mDNS/Bonjour forwarding
    igmpSnooping = false;
  };
};
```

### WiFi

```nix
wifi = {
  main = {
    ssid = "MyNetwork";
    passphrase = "secret";           # Or: { _secret = "wifi/main"; }
    network = "Default";             # Network name to bind to

    hidden = false;
    security = "wpapsk";             # wpapsk | wpa2 | wpa3 | open

    wpa3 = {
      enable = true;
      transition = true;             # WPA2+WPA3 compatibility
    };

    bands = [ "2g" "5g" ];           # 2g | 5g | 6g
    clientIsolation = false;
    guestMode = false;
  };
};
```

### Port Forwards

```nix
portForwards = {
  https = {
    srcPort = 443;
    dstIP = "192.168.1.100";
    protocol = "tcp";                # tcp | udp | tcp_udp
  };
  minecraft = {
    srcPort = 25565;
    dstIP = "192.168.1.50";
    dstPort = 25565;                 # Optional, defaults to srcPort
  };
};
```

### DHCP Reservations

```nix
dhcpReservations = {
  server = {
    mac = "00:11:22:33:44:55";
    ip = "192.168.1.100";
    network = "Default";
  };
};
```

### Firewall Rules

```nix
firewall.rules = {
  block-iot-to-lan = {
    from = "IoT";                    # Source network(s)
    to = "Default";                  # Destination network(s)
    action = "drop";                 # accept | drop | reject
    protocol = "all";                # all | tcp | udp | icmp
    ports = null;                    # null = all, or [ 80 443 ]
    index = 2000;                    # Priority (lower = higher)
  };
};
```

## Schema Validation

unifi-nix automatically validates your configuration against UniFi's OpenAPI schema:

- **Required fields** - Ensures all mandatory fields are present
- **Type validation** - Verifies correct types (booleans, integers, strings)
- **Enum validation** - Checks values against allowed options
- **Range validation** - Validates VLAN IDs, ports, etc.
- **Reference validation** - Ensures WiFi networks reference valid VLANs

Schemas are automatically updated via CI when new UniFi versions are released.

## Secrets

WiFi passphrases can be specified as secret references:

```nix
passphrase = { _secret = "wifi/main"; };
```

At deploy time, secrets are resolved from:

1. `UNIFI_SECRETS_DIR` environment variable (files at `$UNIFI_SECRETS_DIR/wifi/main`)
1. Environment variables (e.g., `WIFI_MAIN` for `wifi/main`)

### With sops-nix

```bash
export UNIFI_SECRETS_DIR=$(mktemp -d)
sops -d secrets.yaml | yq -r '.unifi.wifi_main' > "$UNIFI_SECRETS_DIR/wifi/main"
nix run .#deploy -- config.json 192.168.1.1
```

## How It Works

1. **Nix evaluation** - Config is evaluated and converted to MongoDB format
1. **Schema validation** - Configuration is validated against OpenAPI schema
1. **SSH connection** - Connects to UDM as root via SSH
1. **MongoDB queries** - Reads current state from `ace` database (port 27117)
1. **Diff calculation** - Compares current vs desired state
1. **MongoDB updates** - Applies changes via `updateOne` / `insertOne`
1. **Controller reload** - UniFi controller watches MongoDB and auto-reloads

## Development

```bash
# Enter development shell
nix develop

# Run checks
nix flake check

# Format code
nix fmt

# Run linters
nix develop .#ci --command statix check .
nix develop .#ci --command deadnix .
```

## Setting Up SSH Access

```bash
# Copy your SSH key to the UDM
ssh-copy-id root@192.168.1.1

# Test
ssh root@192.168.1.1 hostname
```

## Safety

- **Always run `diff` before `deploy`** to preview changes
- **Use `DRY_RUN=true`** to see commands without executing
- **Validation runs automatically** before any changes are applied
- **Backup your UDM** before major changes

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

MIT - See [LICENSE](LICENSE) for details.
