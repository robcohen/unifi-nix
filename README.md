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
- **Zone-based firewall** - Full support for UniFi 10.x+ zone-based policies
- **Schema validation** - Automatically validates against device-derived enums
- **Diff before deploy** - Preview all changes before applying
- **Backup & restore** - Automatic backups with schema-validated restore
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

### Firewall Policies (Zone-Based)

For custom firewall rules, use the zone-based firewall (requires UniFi 10.x+):

```nix
firewall.policies = {
  # Block IoT from accessing main network
  block-iot-to-default = {
    action = "block";
    sourceZone = "internal";
    sourceType = "network";
    sourceNetworks = [ "IoT" ];
    destinationZone = "internal";
    destinationType = "network";
    destinationNetworks = [ "Default" ];
    index = 10000;                   # Lower = higher priority
  };

  # Allow IoT to reach DNS on gateway
  allow-iot-dns = {
    action = "allow";
    sourceZone = "internal";
    sourceType = "network";
    sourceNetworks = [ "IoT" ];
    destinationZone = "gateway";
    destinationPort = 53;
    protocol = "tcp_udp";
    index = 9000;                    # Higher priority than block
  };
};
```

**Important:** Zone-based firewall must be enabled on your UDM first:
Settings > Firewall & Security > Upgrade to Zone-Based Firewall

### Network Isolation

For simple inter-VLAN isolation, use the `isolate` option:

```nix
networks = {
  IoT = {
    vlan = 10;
    subnet = "192.168.10.1/24";
    isolate = true;                  # Blocks traffic TO this network
  };

  Guest = {
    vlan = 30;
    subnet = "192.168.30.1/24";
    purpose = "guest";               # Guest networks are auto-isolated
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

## Command Reference

unifi-nix provides a unified CLI with the following commands:

### Configuration Commands

| Command                            | Description                                |
| ---------------------------------- | ------------------------------------------ |
| `unifi eval <config.nix>`          | Evaluate Nix config and output JSON        |
| `unifi validate <config.nix>`      | Validate configuration without deploying   |
| `unifi diff <config.nix> <host>`   | Show differences between config and device |
| `unifi deploy <config.nix> <host>` | Deploy configuration to device             |
| `unifi plan <config.nix> <host>`   | Show full plan including deletions         |

### Migration & Backup Commands

| Command                              | Description                               |
| ------------------------------------ | ----------------------------------------- |
| `unifi import <host> [output.nix]`   | Import existing config from device to Nix |
| `unifi backup <host> [output.json]`  | Create backup of current device config    |
| `unifi restore <backup.json> <host>` | Restore from backup file                  |

### Monitoring Commands

| Command                            | Description                                 |
| ---------------------------------- | ------------------------------------------- |
| `unifi drift <config.json> <host>` | Detect configuration drift                  |
| `unifi status [--json] <host>`     | Show device status and configuration counts |
| `unifi preflight <host>`           | Run pre-flight connectivity checks          |

### Utility Commands

| Command                             | Description                        |
| ----------------------------------- | ---------------------------------- |
| `unifi setup`                       | Interactive setup wizard           |
| `unifi export-schema [output.json]` | Export JSON schema for IDE support |
| `unifi generate-module <schema>`    | Generate Nix module from schema    |

### Schema Commands

| Command                             | Description                        |
| ----------------------------------- | ---------------------------------- |
| `unifi extract-schema <host> <dir>` | Extract MongoDB schema from device |
| `unifi schema-diff <dir1> <dir2>`   | Compare two schema versions        |

### Multi-site

| Command                         | Description                               |
| ------------------------------- | ----------------------------------------- |
| `unifi multi-site <config-dir>` | Deploy to multiple sites from a directory |

### Environment Variables

| Variable                     | Description                          | Default |
| ---------------------------- | ------------------------------------ | ------- |
| `SSH_USER`                   | SSH username                         | `root`  |
| `SSH_TIMEOUT`                | SSH connection timeout (seconds)     | `10`    |
| `UNIFI_SECRETS_DIR`          | Directory containing secret files    | -       |
| `UNIFI_KNOWN_HOSTS`          | SSH known_hosts file for key pinning | -       |
| `DRY_RUN`                    | Preview without changes              | `false` |
| `ALLOW_DELETES`              | Allow resource deletion              | `false` |
| `UNIFI_BACKUP_ENCRYPT`       | Enable GPG encryption for backups    | `false` |
| `UNIFI_BACKUP_GPG_RECIPIENT` | GPG recipient for backup encryption  | -       |

## NixOS Module

unifi-nix can run as a NixOS service for scheduled deployments:

```nix
{
  imports = [ unifi-nix.nixosModules.service ];

  services.unifi-nix = {
    enable = true;

    # Your site configurations
    sites = {
      home = {
        host = "192.168.1.1";
        configFile = ./sites/home.nix;
      };
      office = {
        host = "10.0.0.1";
        configFile = ./sites/office.nix;
      };
    };

    # SSH configuration
    sshUser = "root";
    sshKeyFile = "/run/secrets/udm-ssh-key";

    # Secrets directory (for WiFi passwords, etc.)
    secretsDir = "/run/secrets/unifi";

    # Optional: scheduled drift detection
    driftCheck = {
      enable = true;
      schedule = "daily";  # or cron expression
      alertCommand = "${pkgs.ntfy-sh}/bin/ntfy publish alerts 'UniFi drift detected'";
    };
  };
}
```

The service provides:

- **Scheduled deployments** via systemd timers
- **Drift detection** with configurable alerts
- **Secrets integration** with sops-nix/agenix
- **Logging** to systemd journal

## Advanced Features

### Drift Detection

Monitor for changes made via the UI:

```bash
# Generate current config
unifi eval sites/home.nix > /tmp/desired.json

# Check for drift
unifi drift /tmp/desired.json 192.168.1.1

# Output formats: text (default), json, summary
OUTPUT_FORMAT=json unifi drift /tmp/desired.json 192.168.1.1
```

### Multi-Site Management

Deploy to multiple UDM devices:

```
sites/
├── home.nix      # host = "192.168.1.1"
├── office.nix    # host = "10.0.0.1"
└── cabin.nix     # host = "cabin.vpn.example.com"
```

```bash
# Deploy to all sites
unifi multi-site sites/

# Or use a manifest
cat > sites/manifest.json <<EOF
{
  "sites": [
    {"name": "home", "host": "192.168.1.1", "config": "home.nix"},
    {"name": "office", "host": "10.0.0.1", "config": "office.nix"}
  ]
}
EOF
unifi multi-site sites/
```

### SSH Key Pinning

For enhanced security, pin SSH host keys:

```bash
# Get the host key
ssh-keyscan 192.168.1.1 > ~/.ssh/unifi_known_hosts

# Use pinned keys
export UNIFI_KNOWN_HOSTS=~/.ssh/unifi_known_hosts
unifi deploy sites/home.nix 192.168.1.1
```

### Pre-flight Checks

Validate connectivity before deployment:

```bash
unifi preflight 192.168.1.1

# Output:
# ==> Running pre-flight checks...
#   SSH connectivity... OK
#   MongoDB connectivity... OK
#   Config file... OK
#   Required tools... OK
#
# [OK] All pre-flight checks passed
```

## Firewall Zones

The zone-based firewall uses these predefined zones:

| Zone       | Description                         |
| ---------- | ----------------------------------- |
| `internal` | All internal networks (VLANs)       |
| `external` | WAN/Internet                        |
| `gateway`  | The UDM itself (management)         |
| `vpn`      | VPN clients (WireGuard, L2TP, etc.) |
| `hotspot`  | Hotspot/Guest portal networks       |
| `dmz`      | DMZ networks                        |

## Safety

- **Always run `diff` before `deploy`** to preview changes
- **Use `DRY_RUN=true`** to see commands without executing
- **Use `unifi preflight`** to verify connectivity
- **Validation runs automatically** before any changes are applied
- **Backup your UDM** before major changes: `unifi backup 192.168.1.1`

### Example Workflows

```bash
# Encrypted backup with GPG
UNIFI_BACKUP_ENCRYPT=true UNIFI_BACKUP_GPG_RECIPIENT=me@example.com \
  unifi backup 192.168.1.1 backups/home.json.gpg

# Get device status as JSON for scripting
unifi status --json 192.168.1.1 | jq '.devices.connected'

# Run interactive setup wizard
unifi setup

# Restore from backup with dry-run first
DRY_RUN=true unifi restore backups/home.json 192.168.1.1
unifi restore backups/home.json 192.168.1.1
```

## Documentation

- [API Reference](docs/api-reference.md) - Complete configuration options reference
- [Migration Guide](docs/migration-guide.md) - Migrate from UniFi UI to declarative config
- [Secrets Guide](docs/secrets-guide.md) - Secrets management with sops-nix/agenix
- [Troubleshooting Guide](docs/troubleshooting.md) - Common issues and solutions
- [Schema Documentation](docs/SCHEMA.md) - UniFi schema details
- [Contributing](CONTRIBUTING.md) - Development guidelines

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

MIT - See [LICENSE](LICENSE) for details.
