# unifi-nix

Declarative UniFi Dream Machine configuration via Nix.

Define your networks, WiFi, and firewall rules in Nix. Preview changes with `diff`. Apply with `deploy`.

## Why?

- **Ubiquiti's official API is read-only** (writes "coming soon")
- **The Terraform provider is broken** and poorly maintained
- **The UI is not declarative** - no GitOps, no version control, no review process

This tool bypasses the API entirely by writing directly to the UDM's MongoDB database via SSH.

## Requirements

- UniFi Dream Machine (UDM, UDM-Pro, UDM-SE, etc.) with SSH access
- Nix with flakes enabled
- SSH key authentication to your UDM (`ssh root@<udm-ip>`)

## Quick Start

```bash
# Clone
git clone https://github.com/yourusername/unifi-nix
cd unifi-nix

# Copy and edit the example config
cp examples/home.nix sites/mysite.nix
$EDITOR sites/mysite.nix

# Evaluate config to JSON
nix run .#eval -- sites/mysite.nix > config.json

# Preview changes
nix run .#diff -- config.json 192.168.1.1

# Apply (with secrets)
export WIFI_MAIN="your-password"
export WIFI_IOT="your-iot-password"
nix run .#deploy -- config.json 192.168.1.1
```

## Usage as a Flake Input

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    unifi-nix.url = "github:yourusername/unifi-nix";
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

    pmf = "optional";                # disabled | optional | required
    clientIsolation = false;
    multicastEnhance = false;
    guestMode = false;

    bands = [ "2g" "5g" ];
    minRate."2g" = 1000;             # kbps
    minRate."5g" = 6000;
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
    description = "Block IoT";
  };
};
```

## Secrets

WiFi passphrases can be specified as secret references:

```nix
passphrase = { _secret = "wifi/main"; };
```

At deploy time, secrets are resolved from:

1. `UNIFI_SECRETS_DIR` environment variable (files at `$UNIFI_SECRETS_DIR/wifi/main`)
2. Environment variables (e.g., `WIFI_MAIN` for `wifi/main`)

### With sops-nix

```nix
# In your deployment script
export UNIFI_SECRETS_DIR=$(sops -d secrets.yaml | yq -r '.unifi')
nix run .#deploy -- config.json 192.168.1.1
```

## How It Works

1. **Nix evaluation** - Your config is evaluated and converted to MongoDB document format
2. **SSH connection** - Connects to UDM as root via SSH
3. **MongoDB queries** - Reads current state from `ace` database on port 27117
4. **Diff calculation** - Compares current vs desired state
5. **MongoDB updates** - Applies changes via `updateOne` / `insertOne`
6. **Controller reload** - UniFi controller watches MongoDB and auto-reloads

## Setting Up SSH Access

```bash
# On your machine, copy your SSH key to the UDM
ssh-copy-id root@192.168.1.1

# Or manually (if ssh-copy-id doesn't work)
cat ~/.ssh/id_ed25519.pub | ssh root@192.168.1.1 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"

# Test
ssh root@192.168.1.1 hostname
```

## Safety

- **Always run `diff` before `deploy`** to preview changes
- **Use `DRY_RUN=true`** to see commands without executing
- **Changes are atomic per-resource** - if deploy fails mid-way, partial changes may be applied
- **Backup your UDM** before major changes

## Limitations

- **Firmware updates may reset SSH access** - You may need to re-enable SSH after updates
- **Some settings not yet supported** - Port profiles, traffic routes, advanced firewall zones
- **Network names are case-sensitive** - Use exact names from UDM UI (e.g., "Default" not "default")

## Contributing

PRs welcome! Areas that need work:

- [ ] More complete firewall zone support
- [ ] Port profile management
- [ ] Static DHCP reservations
- [ ] Site-to-site VPN configuration
- [ ] Better secret management integration

## License

MIT
