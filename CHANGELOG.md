# Changelog

All notable changes to unifi-nix will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Unified CLI wrapper (`unifi` command) with all subcommands
- Shared shell library with constants and helper functions
- SSH host key pinning via `UNIFI_KNOWN_HOSTS` environment variable
- Pre-flight connectivity checks (`unifi preflight <host>`)
- Progress indicators for long-running SSH operations
- Comprehensive examples directory:
  - IoT network isolation
  - Guest network with bandwidth limiting
  - Enterprise WiFi with RADIUS
  - Site-to-site VPN with WireGuard
- Edge case validation:
  - VLAN ID range (1-4094)
  - DNS server limit warning (max 4)
  - MAC address format validation
- Backup command (`unifi backup <host>`)
- Status command (`unifi status <host>`)
- JSON schema export for IDE autocompletion
- Setup wizard for first-time configuration
- Backup encryption with GPG

### Changed

- Split `module.nix` into modular components (77% size reduction)
- Enhanced `restore.sh` to support all 21 collection types
- Enhanced `drift-detect.sh` to check 11 collection types
- Improved README with command reference and NixOS module docs

### Fixed

- DNS server limit now properly documented (max 4 servers)

## [1.0.0] - 2024-01-15

### Added

- Initial release
- Declarative network configuration via Nix
- Zone-based firewall policies (UniFi 10.x+)
- Schema validation against device-derived enums
- Multi-version schema support
- Secret management with sops-nix/agenix integration
- Diff before deploy workflow
- Backup and restore functionality
- Drift detection
- Multi-site management
- NixOS module for scheduled deployments

### Supported Features

- Networks (VLANs) with DHCP
- WiFi networks (WPA2, WPA3, WPA-Enterprise)
- Firewall policies and groups
- Port forwards
- DHCP reservations
- AP groups
- User groups with bandwidth limits
- Traffic rules (QoS)
- RADIUS profiles
- Port profiles
- DPI groups
- WireGuard VPN
- Site-to-site VPN (IPsec)
- Scheduled tasks
- Global settings

[1.0.0]: https://github.com/robcohen/unifi-nix/releases/tag/v1.0.0
[unreleased]: https://github.com/robcohen/unifi-nix/compare/v1.0.0...HEAD
