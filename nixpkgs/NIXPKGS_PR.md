# Submitting unifi-nix to nixpkgs

This document describes how to submit unifi-nix to the official nixpkgs repository.

## Package Location

The package should be added to nixpkgs using the new `pkgs/by-name` convention:

```
pkgs/by-name/un/unifi-nix/package.nix
```

## Steps to Submit

### 1. Fork nixpkgs

```bash
gh repo fork NixOS/nixpkgs --clone
cd nixpkgs
```

### 2. Create a branch

```bash
git checkout -b unifi-nix
```

### 3. Add the package

```bash
mkdir -p pkgs/by-name/un/unifi-nix
```

Copy `package.nix` from this directory to `pkgs/by-name/un/unifi-nix/package.nix`.

### 4. Update the hash

Build the package to get the correct hash:

```bash
nix-build -A unifi-nix
```

This will fail with the correct hash. Update `package.nix` with the real hash.

### 5. Test the package

```bash
# Build
nix-build -A unifi-nix

# Test it works
./result/bin/unifi-deploy --help

# Run nixpkgs checks
nix-build -A unifi-nix.tests  # if tests exist
```

### 6. Add yourself as maintainer

Edit `maintainers/maintainer-list.nix` to add yourself if not already there.

Then update the `maintainers` list in `package.nix`:

```nix
maintainers = with maintainers; [ your-handle ];
```

### 7. Commit and push

```bash
git add .
git commit -m "unifi-nix: init at 0.1.0"
git push -u origin unifi-nix
```

### 8. Create the PR

```bash
gh pr create --title "unifi-nix: init at 0.1.0" --body "$(cat <<'EOF'
## Description

Add unifi-nix, a declarative UniFi Dream Machine configuration tool.

## Features

- Define networks, WiFi, firewall rules, port forwards, and DHCP reservations in Nix
- Preview changes with diff before deploying
- Validate configuration against UniFi's OpenAPI schema
- Deploy directly to UDM via SSH/MongoDB

## Links

- Homepage: https://github.com/robcohen/unifi-nix
- License: MIT

## Checklist

- [ ] Built on x86_64-linux
- [ ] Built on aarch64-linux (if applicable)
- [ ] Built on x86_64-darwin (if applicable)
- [ ] Tested functionality
- [ ] Added to maintainers list

## Tested on

- [x] x86_64-linux
EOF
)"
```

## Alternative: NixOS Module

If you also want to add a NixOS module for declarative UniFi configuration, it would go in:

```
nixos/modules/services/networking/unifi-nix.nix
```

However, since unifi-nix is more of a configuration management tool (like Terraform) rather than a running service, just the package may be more appropriate.

## Version Tags

Before submitting, ensure you've tagged a release:

```bash
cd /path/to/unifi-nix
git tag v0.1.0
git push origin v0.1.0
```

This is required for `fetchFromGitHub` to work with a version-based rev.
