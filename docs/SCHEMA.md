# Schema System

unifi-nix uses a device-derived schema system to ensure configuration values are valid for your specific UniFi device version.

## Overview

The schema system works at three levels:

1. **Nix-time validation** - When you evaluate your configuration, the Nix module validates enum values against the schema
1. **Deploy-time validation** - The validation script checks your config against MongoDB field schemas
1. **Runtime defaults** - The deploy script applies schema-extracted defaults to new resources

## Directory Structure

```
schemas/
  └── 10.0.162/              # Version-specific schema
      ├── jar-fields/        # Field definitions from core.jar
      │   ├── NetworkConf.json
      │   ├── WlanConf.json
      │   ├── FirewallRule.json
      │   └── ... (34 files)
      ├── generated/
      │   ├── enums.json         # 282 enum types extracted from JAR
      │   ├── validation.json    # 226 validation patterns
      │   ├── defaults.json      # Default values from MongoDB
      │   └── json-schema/       # IDE-compatible JSON schemas
      ├── mongodb-fields.json    # MongoDB collection fields
      ├── mongodb-examples.json  # Example documents
      └── version                # Schema version file

lib/
  └── schema.nix         # Nix schema loader
```

## How It Works

### Schema Extraction

Schemas are automatically extracted via GitHub Actions when new UniFi versions are released:

1. **GitHub Actions workflow** runs weekly (or on-demand)
1. Starts UniFi Network Application in Docker
1. Extracts field definitions from `core.jar` (api/fields/\*.json)
1. Queries MongoDB for collection fields and example documents
1. Generates enums, validation patterns, and JSON schemas
1. Commits updated schemas to the repository

The JAR field definitions are the authoritative source - they contain all 282 enum types and 226 validation patterns directly from UniFi's internal schema.

### Manual Extraction

For local development or testing with specific devices:

```bash
# Run the schema update workflow locally
nix run .#generate-schema
```

### Nix-time Validation

The `lib/schema.nix` loader:

1. Finds the latest schema version in `schemas/`
1. Loads `enums.json` and extracts enum lists
1. Merges device-extracted values with known defaults
1. Exports enum lists for use in `module.nix`

Example in `module.nix`:

```nix
schemaLib = import ./lib/schema.nix { inherit lib; };
inherit (schemaLib) schema;

# Use schema-derived enums
action = mkOption {
  type = types.enum schema.policyActions;  # ["allow" "block" "reject"]
  default = "block";
};
```

## Available Enums

| Schema Field            | Description                                        |
| ----------------------- | -------------------------------------------------- |
| `zoneKeys`              | Firewall zones (internal, external, gateway, etc.) |
| `networkPurposes`       | Network types (corporate, guest, wan, vlan-only)   |
| `networkGroups`         | Network groups (LAN, WAN, WAN2)                    |
| `wifiSecurity`          | WiFi security modes (wpapsk, open, wpaeap, wep)    |
| `wifiWpaModes`          | WPA modes (wpa2, wpa3, auto)                       |
| `wifiPmfModes`          | PMF modes (disabled, optional, required)           |
| `wifiBands`             | WiFi bands (2g, 5g, 6g)                            |
| `wifiMacFilterPolicies` | MAC filter policies (allow, deny)                  |
| `policyActions`         | Firewall actions (allow, block, reject)            |
| `policyProtocols`       | Protocols (all, tcp, udp, tcp_udp, icmp, icmpv6)   |
| `policyIpVersions`      | IP versions (both, ipv4, ipv6)                     |
| `connectionStateTypes`  | Connection states (ALL, ESTABLISHED, etc.)         |
| `matchingTargets`       | Match types (any, network, ip, mac, device)        |
| `portForwardProtocols`  | Port forward protocols (tcp, udp, tcp_udp)         |
| `routingTypes`          | Routing types (static, policy)                     |

## Adding New Enums

1. **Extract from MongoDB** - Add to `scripts/extract-device-schema.sh`:

   ```bash
   new_field: db.collection.distinct("field_name"),
   ```

1. **Add loader to schema.nix** - Add a new field in `loadSchema`:

   ```nix
   newField =
     if hasEnums && enums ? new_field && enums.new_field != [ ] then
       lib.unique (enums.new_field ++ ["default1" "default2"])
     else
       ["default1" "default2"];
   ```

1. **Use in module.nix**:

   ```nix
   myOption = mkOption {
     type = types.enum schema.newField;
   };
   ```

1. **Update schema-diff.sh** - Add the new enum to the comparison list

1. **Add tests** - Update the `schema-loading` check in `flake.nix`

## Comparing Schema Versions

Use the schema diff tool to see changes between versions:

```bash
nix run .#schema-diff

# Compare specific versions
nix run .#schema-diff -- 10.0.159 10.0.162
```

## Troubleshooting

### "Schema not found for version X"

Your device is running a version that hasn't been extracted yet:

1. Trigger the `Update UniFi Schemas` workflow manually
1. Or wait for the weekly automatic update
1. The workflow will extract and commit schemas for the new version

### "Invalid enum value"

The value isn't in the schema. Either:

1. The enum may have been added in a newer UniFi version
1. Check `schemas/<version>/generated/enums.json` for available values
1. Update to a newer schema version if available

### Tests fail with "empty enum list"

The schema loader couldn't find valid enums. Ensure:

1. `schemas/<version>/generated/enums.json` exists and has content
1. The `jar-fields/` directory contains the field definition files
1. Run `nix run .#generate-schema` to regenerate

## CI Integration

Schemas are automatically maintained via GitHub Actions:

- **Weekly schedule**: Checks for new UniFi versions every Sunday
- **Manual trigger**: Run `Update UniFi Schemas` workflow with `force=true`
- **Auto-commit**: New schemas are automatically committed to the repo

All schema files are version-controlled, so your CI just uses what's in the repo.
