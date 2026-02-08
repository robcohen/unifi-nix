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
  └── 10.0.162/          # Version-specific schema
      ├── integration.json   # OpenAPI schema (from device)
      ├── enums.json         # Extracted enum values
      ├── mongodb-fields.json    # MongoDB collection fields
      ├── mongodb-examples.json  # Example documents
      └── reference-ids.json     # IDs for default groups/sites

lib/
  └── schema.nix         # Nix schema loader
```

## How It Works

### Schema Extraction

When you first deploy to a device, `extract-device-schema.sh` automatically:

1. Connects to the UDM via SSH
1. Queries MongoDB for collection field names and example documents
1. Extracts enum values from existing data (zones, network purposes, etc.)
1. Downloads the OpenAPI schema from the device
1. Caches everything in `~/.cache/unifi-nix/devices/<host>/`
1. Copies enums to the versioned `schemas/<version>/` directory

### Version Detection

The deploy script:

1. Gets the device version from `/usr/lib/unifi/webapps/ROOT/api-docs/integration.json`
1. Looks for a matching `schemas/<version>/` directory
1. If not found, creates a minimal schema with extracted enums
1. Updates the versioned schema if device enums are newer

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

1. Run `./scripts/extract-device-schema.sh <host>` to cache device schema
1. The deploy script will auto-create `schemas/<version>/enums.json`

### "Invalid enum value"

The value isn't in the schema. Either:

1. Re-extract schema: `./scripts/extract-device-schema.sh <host>`
1. The value may be from a newer/older version - check the device version

### Tests fail with "empty enum list"

The schema loader couldn't find valid enums. Ensure:

1. `schemas/<version>/enums.json` exists and has content
1. The enum field names match what's in `lib/schema.nix`

## CI Integration

For CI pipelines, you can:

1. Commit extracted schemas to the repo
1. Use `SKIP_SCHEMA_CACHE=true` to skip device extraction
1. Use `SKIP_SCHEMA_VALIDATION=true` to deploy without OpenAPI validation

The recommended approach is to extract schemas from a test device and commit them:

```bash
./scripts/extract-device-schema.sh test-udm.local
git add schemas/
git commit -m "chore: update device schema"
```
