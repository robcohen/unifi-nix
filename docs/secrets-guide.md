# Secrets Management Guide

Securely managing passwords, API keys, and other secrets in unifi-nix.

## Table of Contents

- [Overview](#overview)
- [Secret References](#secret-references)
- [File-Based Secrets](#file-based-secrets)
- [Environment Variables](#environment-variables)
- [Sops Integration](#sops-integration)
- [Agenix Integration](#agenix-integration)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)

---

## Overview

unifi-nix handles secrets (WiFi passwords, VPN keys, RADIUS secrets) through a flexible reference system. Secrets are:

1. **Referenced in config** - Not stored in plain text
1. **Resolved at deploy time** - Fetched from secure storage
1. **Never logged** - Excluded from output and diffs

### Secret Types

| Type           | Example        | Options Using Secrets                        |
| -------------- | -------------- | -------------------------------------------- |
| WiFi passwords | WPA passphrase | `wifi.<name>.passphrase`                     |
| VPN keys       | WireGuard PSK  | `vpn.wireguard.peers.<name>.presharedKey`    |
| VPN secrets    | IPsec PSK      | `vpn.siteToSite.<name>.presharedKey`         |
| RADIUS secrets | Shared secret  | `radiusProfiles.<name>.authServers[].secret` |

---

## Secret References

In your Nix configuration, use secret references instead of plain text:

```nix
{
  unifi = {
    wifi.main = {
      ssid = "MyNetwork";

      # Plain text (NOT recommended)
      # passphrase = "my-password-123";

      # Secret reference (recommended)
      passphrase = { _secret = "wifi/main"; };
    };

    vpn.siteToSite.datacenter = {
      remoteHost = "vpn.example.com";
      presharedKey = { _secret = "vpn/datacenter-psk"; };
    };
  };
}
```

The `_secret` path is resolved during deployment from one of:

1. File in `$UNIFI_SECRETS_DIR`
1. Environment variable
1. Sops-encrypted file
1. Agenix-managed secret

---

## File-Based Secrets

The simplest approach for standalone use.

### Setup

```bash
# Create secrets directory
export UNIFI_SECRETS_DIR="$HOME/.local/share/unifi-nix/secrets"
mkdir -p "$UNIFI_SECRETS_DIR"

# Create secret files
mkdir -p "$UNIFI_SECRETS_DIR/wifi"
echo -n "my-wifi-password" > "$UNIFI_SECRETS_DIR/wifi/main"
chmod 600 "$UNIFI_SECRETS_DIR/wifi/main"

mkdir -p "$UNIFI_SECRETS_DIR/vpn"
echo -n "ipsec-preshared-key" > "$UNIFI_SECRETS_DIR/vpn/datacenter-psk"
chmod 600 "$UNIFI_SECRETS_DIR/vpn/datacenter-psk"
```

### Directory Structure

```
$UNIFI_SECRETS_DIR/
├── wifi/
│   ├── main          # WiFi password for main network
│   ├── guest         # WiFi password for guest network
│   └── iot           # WiFi password for IoT network
├── vpn/
│   ├── datacenter-psk
│   └── wireguard-psk
└── radius/
    └── corporate     # RADIUS shared secret
```

### Usage

```bash
# Set environment variable before deploy
export UNIFI_SECRETS_DIR="$HOME/.local/share/unifi-nix/secrets"
unifi deploy sites/home.nix 192.168.1.1
```

Or add to your shell profile:

```bash
# ~/.bashrc or ~/.zshrc
export UNIFI_SECRETS_DIR="$HOME/.local/share/unifi-nix/secrets"
```

---

## Environment Variables

For CI/CD or simpler setups, use environment variables.

### Naming Convention

Secret path `wifi/main` → Environment variable `UNIFI_SECRET_WIFI_MAIN`

```bash
# Set secrets as environment variables
export UNIFI_SECRET_WIFI_MAIN="my-wifi-password"
export UNIFI_SECRET_WIFI_GUEST="guest-password"
export UNIFI_SECRET_VPN_DATACENTER_PSK="vpn-secret"

# Deploy
unifi deploy sites/home.nix 192.168.1.1
```

### CI/CD Example (GitHub Actions)

```yaml
name: Deploy Network Config

on:
  push:
    branches: [main]
    paths: ["sites/**"]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: cachix/install-nix-action@v24

      - name: Deploy
        env:
          UNIFI_SECRET_WIFI_MAIN: ${{ secrets.WIFI_MAIN_PASSWORD }}
          UNIFI_SECRET_WIFI_GUEST: ${{ secrets.WIFI_GUEST_PASSWORD }}
        run: |
          nix run .#deploy -- sites/home.nix ${{ secrets.UDM_HOST }}
```

---

## Sops Integration

[sops-nix](https://github.com/Mic92/sops-nix) provides encrypted secrets in your Nix configuration.

### Setup

1. **Install sops-nix** in your flake:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    sops-nix.url = "github:Mic92/sops-nix";
    unifi-nix.url = "github:robcohen/unifi-nix";
  };
}
```

2. **Create age key**:

```bash
# Generate key
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt

# Note the public key for .sops.yaml
```

3. **Configure sops** (`.sops.yaml`):

```yaml
keys:
  - &admin age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

creation_rules:
  - path_regex: secrets/.*\.yaml$
    key_groups:
      - age:
          - *admin
```

4. **Create encrypted secrets**:

```bash
# Create secrets file
sops secrets/unifi.yaml
```

```yaml
# secrets/unifi.yaml (encrypted at rest)
wifi_main: "my-wifi-password"
wifi_guest: "guest-password"
vpn_datacenter: "ipsec-secret"
```

5. **Use in NixOS configuration**:

```nix
{ config, pkgs, ... }:

{
  imports = [ inputs.sops-nix.nixosModules.sops ];

  sops.defaultSopsFile = ./secrets/unifi.yaml;
  sops.age.keyFile = "/home/admin/.config/sops/age/keys.txt";

  sops.secrets = {
    wifi_main = {};
    wifi_guest = {};
    vpn_datacenter = {};
  };

  # Reference in unifi-nix
  unifi = {
    wifi.main.passphrase = { _secret = config.sops.secrets.wifi_main.path; };
    wifi.guest.passphrase = { _secret = config.sops.secrets.wifi_guest.path; };
  };
}
```

### Deploy with Sops

```bash
# Secrets are decrypted at runtime
unifi deploy sites/home.nix 192.168.1.1
```

---

## Agenix Integration

[agenix](https://github.com/ryantm/agenix) is another popular secrets management solution.

### Setup

1. **Add agenix to flake**:

```nix
{
  inputs = {
    agenix.url = "github:ryantm/agenix";
  };
}
```

2. **Create secrets**:

```bash
# secrets/secrets.nix
let
  admin = "ssh-ed25519 AAAA...";  # Your SSH public key
in {
  "wifi-main.age".publicKeys = [ admin ];
  "wifi-guest.age".publicKeys = [ admin ];
}
```

```bash
# Encrypt secrets
cd secrets
agenix -e wifi-main.age
agenix -e wifi-guest.age
```

3. **Reference in configuration**:

```nix
{ config, ... }:

{
  age.secrets = {
    wifi-main.file = ./secrets/wifi-main.age;
    wifi-guest.file = ./secrets/wifi-guest.age;
  };

  unifi = {
    wifi.main.passphrase = { _secret = config.age.secrets.wifi-main.path; };
    wifi.guest.passphrase = { _secret = config.age.secrets.wifi-guest.path; };
  };
}
```

---

## Best Practices

### DO

- **Use secret references** - Never commit plain text passwords
- **Encrypt at rest** - Use sops/agenix for version-controlled secrets
- **Limit access** - Set file permissions to 600
- **Rotate regularly** - Change WiFi passwords periodically
- **Audit access** - Log who deploys configuration changes
- **Backup secrets** - Store encrypted backups separately

### DON'T

- **Commit plain text secrets** - Even in private repos
- **Log secrets** - unifi-nix masks them, but be careful with wrappers
- **Share secrets files** - Use per-user encryption keys
- **Use weak passwords** - Especially for WiFi and VPN
- **Skip secret rotation** - Especially after personnel changes

### Security Checklist

```markdown
- [ ] All passwords use `{ _secret = "..."; }` references
- [ ] Secret files have 600 permissions
- [ ] Secrets directory is not in git
- [ ] Sops/agenix encryption is configured
- [ ] CI/CD uses GitHub/GitLab secrets
- [ ] Backup encryption keys are stored safely
- [ ] WiFi passwords are at least 12 characters
- [ ] VPN pre-shared keys are random and long
```

---

## Troubleshooting

### "Secret not found: wifi/main"

**Cause:** Secret file doesn't exist or path is wrong.

**Solution:**

```bash
# Check environment variable
echo $UNIFI_SECRETS_DIR

# Verify file exists
ls -la "$UNIFI_SECRETS_DIR/wifi/main"

# Create if missing
mkdir -p "$UNIFI_SECRETS_DIR/wifi"
echo -n "password" > "$UNIFI_SECRETS_DIR/wifi/main"
```

### "Permission denied reading secret"

**Cause:** File permissions too restrictive.

**Solution:**

```bash
# Check current permissions
ls -la "$UNIFI_SECRETS_DIR/wifi/main"

# Fix permissions
chmod 600 "$UNIFI_SECRETS_DIR/wifi/main"
chown $USER "$UNIFI_SECRETS_DIR/wifi/main"
```

### "Secret contains newline"

**Cause:** Extra newline at end of secret file.

**Solution:**

```bash
# Use -n to avoid trailing newline
echo -n "password" > "$UNIFI_SECRETS_DIR/wifi/main"

# Or trim existing file
tr -d '\n' < secret.txt > "$UNIFI_SECRETS_DIR/wifi/main"
```

### "Sops decryption failed"

**Cause:** Wrong key or corrupted file.

**Solution:**

```bash
# Verify key is available
sops --decrypt secrets/unifi.yaml

# Check .sops.yaml configuration
cat .sops.yaml

# Re-encrypt if needed
sops updatekeys secrets/unifi.yaml
```

### "WiFi password not applied"

**Cause:** Secret resolved but value is wrong.

**Solution:**

```bash
# Test secret resolution (shows masked value)
unifi eval sites/home.nix | jq '.wifi'

# Verify the secret file content (carefully!)
cat "$UNIFI_SECRETS_DIR/wifi/main" | wc -c  # Check length
```

---

## Quick Reference

### Secret Path to File/Env Mapping

| Config Reference               | File Path                        | Environment Variable       |
| ------------------------------ | -------------------------------- | -------------------------- |
| `{ _secret = "wifi/main"; }`   | `$UNIFI_SECRETS_DIR/wifi/main`   | `UNIFI_SECRET_WIFI_MAIN`   |
| `{ _secret = "vpn/psk"; }`     | `$UNIFI_SECRETS_DIR/vpn/psk`     | `UNIFI_SECRET_VPN_PSK`     |
| `{ _secret = "radius/corp"; }` | `$UNIFI_SECRETS_DIR/radius/corp` | `UNIFI_SECRET_RADIUS_CORP` |

### Minimum Secret Lengths

| Secret Type   | Minimum  | Recommended |
| ------------- | -------- | ----------- |
| WiFi WPA2/3   | 8 chars  | 16+ chars   |
| VPN PSK       | 16 chars | 32+ chars   |
| RADIUS secret | 8 chars  | 16+ chars   |

---

See also:

- [API Reference](./api-reference.md) - Configuration options
- [Migration Guide](./migration-guide.md) - Moving from UI to declarative
- [sops-nix](https://github.com/Mic92/sops-nix) - Sops integration for NixOS
- [agenix](https://github.com/ryantm/agenix) - Age-based secrets for NixOS
