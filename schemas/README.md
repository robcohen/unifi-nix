# UniFi API Schemas

This directory contains extracted API schemas from UniFi Network Application versions.
Each subdirectory is named after the UniFi Network version (e.g., `10.0.162`).

## Extraction Methods

There are three ways to extract schemas, depending on your needs:

### 1. From Live Device (Recommended)

Extract complete schemas including MongoDB runtime data from a running UDM/UCG:

```bash
./scripts/extract-schema.sh <udm-ip> [ssh-user]
```

**Produces:** OpenAPI spec + MongoDB fields + Example documents + Reference IDs

### 2. From Docker Image

Extract the OpenAPI spec from the official Network Application Docker image:

```bash
./scripts/extract-schema-docker.sh [version]
# Examples:
./scripts/extract-schema-docker.sh latest
./scripts/extract-schema-docker.sh 8.6.9
```

**Produces:** OpenAPI spec + Schema definitions + Required fields

### 3. From Firmware File

Extract from raw firmware `.bin` files (requires binwalk):

```bash
./scripts/extract-schema-firmware.sh <firmware.bin> [device-type]
# Example:
./scripts/extract-schema-firmware.sh UDM-Pro-4.0.6.bin udm-pro
```

**Produces:** OpenAPI spec (MongoDB schemas are runtime-generated)

Download firmware from:

- https://ui.com/download/releases/firmware
- https://community.ui.com/releases

## Schema Versioning

**The schema is determined by the Network Application version, not the device type.**

All UniFi OS devices (UDM, UDM Pro, UCG Ultra, etc.) run the same Network Application.
Different devices have different hardware capabilities, but the API schema is consistent.

## Schema Files

Each version directory may contain:

| File | Description |
|------|-------------|
| `integration.json` | Official OpenAPI 3.1 spec (validation rules, required fields) |
| `mongodb-fields.json` | Union of ALL field names from ALL documents per collection |
| `mongodb-examples.json` | Full example documents showing types and defaults |
| `mongodb-stats.json` | Collection statistics (document counts, indexes) |
| `reference-ids.json` | Default reference IDs (site, usergroup, apgroup, etc.) |
| `metadata.json` | Extraction metadata (source, date, counts) |
| `schema-names.json` | List of OpenAPI schema definitions |
| `api-paths.json` | List of API endpoints |
| `required-fields.json` | Required fields per schema |

### Field Extraction

`mongodb-fields.json` captures the **union** of all field names across up to 100 documents
per collection. This ensures we capture fields that only appear in certain document types
(e.g., LAN vs WAN network configs have different fields).

## Integration API vs MongoDB

The Integration API (`/proxy/network/integration/v1/...`) uses different field names than MongoDB:

| Integration API | MongoDB | Notes |
|-----------------|---------|-------|
| `broadcastingFrequenciesGHz` | `wlan_bands` | `["2.4", "5"]` vs `["2g", "5g"]` |
| `clientIsolationEnabled` | `l2_isolation` | |
| `hideName` | `hide_ssid` | |
| `bssTransitionEnabled` | `bss_transition` | |
| `arpProxyEnabled` | `proxy_arp` | |

## Required Fields

### WiFi Broadcast (Integration API)

- `name`
- `type` (STANDARD or IOT_OPTIMIZED)
- `enabled`
- `securityConfiguration`
- `broadcastingFrequenciesGHz`
- `clientIsolationEnabled`
- `hideName`
- `multicastToUnicastConversionEnabled`
- `uapsdEnabled`
- `arpProxyEnabled`
- `bssTransitionEnabled`

### WiFi (MongoDB - auto-populated by controller)

- `site_id`
- `usergroup_id`
- `ap_group_ids`
- `networkconf_id`
- `external_id`
- `x_iapp_key`
- Many boolean flags with defaults

### Network (Integration API)

- `name`
- `enabled`
- `management` (GATEWAY, SWITCH, UNMANAGED)
- `vlanId`

## Automatic Schema Updates

### CI Pipeline (OpenAPI Schemas)

The repository includes a GitHub Actions workflow (`.github/workflows/update-schemas.yml`) that:

- Runs every 6 hours
- Checks Docker Hub for new Network Application versions
- Extracts OpenAPI schemas and commits them to the repo

This ensures users always have up-to-date validation rules without manual intervention.

### First-Run Extraction (MongoDB Schemas)

When you run `deploy.sh` for the first time against a device, it automatically:

1. Extracts MongoDB schemas from your device
1. Caches them in `~/.cache/unifi-nix/devices/<host>/`
1. Refreshes the cache when version changes or after 24 hours

This captures device-specific runtime data like:

- Reference IDs (site, usergroup, apgroup)
- Default field values
- Current configuration examples

### Manual Extraction

You can manually extract schemas at any time:

```bash
# Full extraction from live device
./scripts/extract-schema.sh 192.168.1.1

# Device schema cache only
./scripts/extract-device-schema.sh 192.168.1.1
```

## Version Compatibility

Different UniFi versions may have different schemas. The CI pipeline automatically
tracks new versions. For devices running older versions, schemas are extracted
on first deploy.
