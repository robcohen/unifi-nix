# Migration Guide

How to migrate from manual UniFi UI configuration to declarative unifi-nix.

## Table of Contents

- [Overview](#overview)
- [Step 1: Backup Current Config](#step-1-backup-current-config)
- [Step 2: Import Existing Configuration](#step-2-import-existing-configuration)
- [Step 3: Review and Customize](#step-3-review-and-customize)
- [Step 4: Validate](#step-4-validate)
- [Step 5: Deploy](#step-5-deploy)
- [UI to Nix Mapping](#ui-to-nix-mapping)
- [Common Migration Patterns](#common-migration-patterns)
- [Troubleshooting](#troubleshooting)

---

## Overview

Migration from the UniFi UI to unifi-nix involves:

1. **Backup** - Save your current configuration
1. **Import** - Auto-generate Nix config from device
1. **Customize** - Refine the generated configuration
1. **Validate** - Check for errors before deploying
1. **Deploy** - Apply the declarative configuration

After migration, you manage your network via code, with benefits like:

- Version control for network changes
- Reproducible deployments
- Code review for network policies
- Easy multi-site management

---

## Step 1: Backup Current Config

Before any migration, create a backup:

```bash
# Create encrypted backup
unifi backup 192.168.1.1 backups/pre-migration.json

# Or with encryption
UNIFI_BACKUP_ENCRYPT=true unifi backup 192.168.1.1
```

Keep this backup safe - you can restore it if anything goes wrong:

```bash
unifi restore backups/pre-migration.json 192.168.1.1
```

---

## Step 2: Import Existing Configuration

The `import` command reads your current UniFi configuration and generates Nix:

```bash
# Import from device
unifi import 192.168.1.1 sites/home.nix

# Or use the setup wizard for guided import
unifi setup
```

This generates a complete Nix configuration matching your current setup.

### What Gets Imported

| Component         | Imported                        |
| ----------------- | ------------------------------- |
| Networks/VLANs    | Yes                             |
| WiFi SSIDs        | Yes (passwords as placeholders) |
| Firewall policies | Yes                             |
| Firewall groups   | Yes                             |
| Port forwards     | Yes                             |
| DHCP reservations | Yes                             |
| Traffic rules     | Yes                             |
| RADIUS profiles   | Yes (secrets as placeholders)   |
| WireGuard VPN     | Yes (keys as placeholders)      |
| Site-to-site VPN  | Yes (secrets as placeholders)   |

### What's NOT Imported

- Device-specific settings (AP radio config)
- Client device history
- Statistics and logs
- Controller user accounts

---

## Step 3: Review and Customize

After import, review the generated configuration:

```bash
$EDITOR sites/home.nix
```

### Key Customizations

#### 1. Replace Password Placeholders

The importer creates placeholder secrets:

```nix
# Before (generated)
passphrase = "IMPORTED_SECRET_wifi_main";

# After (with secret reference)
passphrase = { _secret = "wifi/main"; };
```

Create the secret file:

```bash
mkdir -p ~/.local/share/unifi-nix/secrets/wifi
echo -n "your-actual-password" > ~/.local/share/unifi-nix/secrets/wifi/main
chmod 600 ~/.local/share/unifi-nix/secrets/wifi/main
```

#### 2. Clean Up Names

Imported names might be verbose:

```nix
# Before
networks."Corporate Network (Main Office)" = { ... };

# After (cleaner)
networks.corporate = { ... };
```

#### 3. Remove Defaults

Imported config includes all defaults - remove unchanged ones:

```nix
# Before (verbose)
networks.Default = {
  enable = true;  # default, remove
  purpose = "corporate";  # default, remove
  networkGroup = "LAN";  # default, remove
  isolate = false;  # default, remove
  internetAccess = true;  # default, remove
  mdns = true;  # default, remove
  igmpSnooping = false;  # default, remove
  subnet = "192.168.1.1/24";
  # ...
};

# After (minimal)
networks.Default = {
  subnet = "192.168.1.1/24";
  dhcp = {
    enable = true;
    start = "192.168.1.100";
    end = "192.168.1.254";
  };
};
```

#### 4. Add Comments

Document your configuration:

```nix
{
  unifi = {
    host = "192.168.1.1";

    networks = {
      # Main network - trusted devices
      Default = {
        subnet = "192.168.1.1/24";
        dhcp.enable = true;
      };

      # IoT devices - isolated from main network
      IoT = {
        vlan = 10;
        subnet = "192.168.10.1/24";
        isolate = true;  # Blocks access to other VLANs
      };
    };
  };
}
```

---

## Step 4: Validate

Check your configuration before deploying:

```bash
# Validate syntax and references
unifi validate sites/home.nix

# Preview changes (diff against device)
unifi diff sites/home.nix 192.168.1.1

# Full deployment plan
unifi plan sites/home.nix 192.168.1.1
```

### Common Validation Errors

| Error                   | Solution                                           |
| ----------------------- | -------------------------------------------------- |
| "Network 'X' not found" | WiFi references undefined network - check spelling |
| "Duplicate VLAN"        | Two networks use same VLAN ID                      |
| "Invalid MAC address"   | Check MAC format: `XX:XX:XX:XX:XX:XX`              |
| "Overlapping subnets"   | Two networks have overlapping IP ranges            |

---

## Step 5: Deploy

When validation passes, deploy:

```bash
# Deploy configuration
unifi deploy sites/home.nix 192.168.1.1

# Dry run first (preview only)
DRY_RUN=true unifi deploy sites/home.nix 192.168.1.1
```

### Post-Deployment Verification

```bash
# Check device status
unifi status 192.168.1.1

# Verify no drift
unifi drift sites/home.nix 192.168.1.1
```

---

## UI to Nix Mapping

### Networks (Settings > Networks)

| UI Field          | Nix Option                       |
| ----------------- | -------------------------------- |
| Name              | `networks.<name>` (key)          |
| VLAN ID           | `networks.<name>.vlan`           |
| Gateway/Subnet    | `networks.<name>.subnet`         |
| DHCP Mode         | `networks.<name>.dhcp.enable`    |
| DHCP Range        | `networks.<name>.dhcp.start/end` |
| DHCP DNS          | `networks.<name>.dhcp.dns`       |
| Network Isolation | `networks.<name>.isolate`        |
| Internet Access   | `networks.<name>.internetAccess` |

### WiFi (Settings > WiFi)

| UI Field            | Nix Option                    |
| ------------------- | ----------------------------- |
| Name (SSID)         | `wifi.<name>.ssid`            |
| Password            | `wifi.<name>.passphrase`      |
| Network             | `wifi.<name>.network`         |
| Security Protocol   | `wifi.<name>.security`        |
| WPA3                | `wifi.<name>.wpa3.enable`     |
| Hide SSID           | `wifi.<name>.hidden`          |
| Bands (2.4/5/6 GHz) | `wifi.<name>.bands`           |
| Client Isolation    | `wifi.<name>.clientIsolation` |
| Fast Roaming        | `wifi.<name>.fastRoaming`     |

### Firewall (Settings > Firewall & Security)

| UI Field             | Nix Option                                     |
| -------------------- | ---------------------------------------------- |
| Rule Name            | `firewall.policies.<name>`                     |
| Action               | `firewall.policies.<name>.action`              |
| Source Zone          | `firewall.policies.<name>.sourceZone`          |
| Source Networks      | `firewall.policies.<name>.sourceNetworks`      |
| Destination Zone     | `firewall.policies.<name>.destinationZone`     |
| Destination Networks | `firewall.policies.<name>.destinationNetworks` |
| Port                 | `firewall.policies.<name>.destinationPort`     |
| Protocol             | `firewall.policies.<name>.protocol`            |
| Enable Logging       | `firewall.policies.<name>.logging`             |

### Port Forwarding (Settings > Firewall & Security > Port Forwarding)

| UI Field     | Nix Option                     |
| ------------ | ------------------------------ |
| Name         | `portForwards.<name>`          |
| From Port    | `portForwards.<name>.srcPort`  |
| Forward IP   | `portForwards.<name>.dstIP`    |
| Forward Port | `portForwards.<name>.dstPort`  |
| Protocol     | `portForwards.<name>.protocol` |

---

## Common Migration Patterns

### Pattern 1: Simple Home Network

**Before (UI):**

- Default network: 192.168.1.0/24
- One WiFi: "HomeNetwork"

**After (Nix):**

```nix
{
  unifi = {
    host = "192.168.1.1";

    networks.Default = {
      subnet = "192.168.1.1/24";
      dhcp = {
        enable = true;
        start = "192.168.1.100";
        end = "192.168.1.254";
        dns = [ "1.1.1.1" ];
      };
    };

    wifi.home = {
      ssid = "HomeNetwork";
      passphrase = { _secret = "wifi/home"; };
      network = "Default";
      wpa3.enable = true;
    };
  };
}
```

### Pattern 2: IoT Isolation

**Before (UI):**

- IoT VLAN with "Block inter-VLAN routing"
- Separate IoT WiFi

**After (Nix):**

```nix
{
  unifi = {
    networks.IoT = {
      vlan = 10;
      subnet = "192.168.10.1/24";
      isolate = true;
      dhcp.enable = true;
    };

    wifi.iot = {
      ssid = "IoT-Devices";
      passphrase = { _secret = "wifi/iot"; };
      network = "IoT";
      bands = [ "2g" ];  # Most IoT is 2.4GHz only
    };

    # Allow IoT to reach the internet but not LAN
    firewall.policies = {
      block-iot-to-lan = {
        action = "block";
        sourceZone = "internal";
        sourceType = "network";
        sourceNetworks = [ "IoT" ];
        destinationZone = "internal";
        destinationType = "network";
        destinationNetworks = [ "Default" ];
      };
    };
  };
}
```

### Pattern 3: Guest Network

**Before (UI):**

- Guest network with client isolation
- Guest portal

**After (Nix):**

```nix
{
  unifi = {
    networks.Guest = {
      vlan = 20;
      subnet = "192.168.20.1/24";
      purpose = "guest";
      isolate = true;
      dhcp.enable = true;
    };

    wifi.guest = {
      ssid = "Guest";
      passphrase = { _secret = "wifi/guest"; };
      network = "Guest";
      guestMode = true;
      clientIsolation = true;
    };
  };
}
```

---

## Troubleshooting

### "Import failed: SSH connection refused"

1. Verify SSH is enabled on UDM (Settings > System > SSH)
1. Check your SSH key is authorized:
   ```bash
   ssh-copy-id root@192.168.1.1
   ```

### "Import failed: MongoDB not responding"

Wait for UDM to fully boot (can take 5+ minutes after restart).

### "Imported config has errors"

The import captures your current state, which may have issues:

- Run `unifi validate` to see specific errors
- Fix issues in the generated Nix file
- Common: duplicate VLANs, orphaned references

### "Passwords aren't working after import"

Imported passwords are placeholders. Replace with actual secrets:

```nix
# Replace this
passphrase = "IMPORTED_SECRET_wifi_main";

# With this
passphrase = { _secret = "wifi/main"; };
```

Then create the secret file with the real password.

### "Some settings are missing after deploy"

unifi-nix manages a subset of UniFi settings. Device-specific settings (AP radio config, switch port assignments) are managed separately.

---

## Next Steps

After successful migration:

1. **Version control** - Commit your config to git
1. **Set up CI** - Add validation to your pipeline
1. **Document** - Add comments explaining your network design
1. **Monitor drift** - Periodically run `unifi drift` to catch manual changes

See also:

- [API Reference](./api-reference.md) - All configuration options
- [Secrets Guide](./secrets-guide.md) - Managing passwords securely
- [Troubleshooting](./troubleshooting.md) - Common issues and solutions
