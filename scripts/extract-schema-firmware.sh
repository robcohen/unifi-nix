#!/usr/bin/env bash
# Extract UniFi API schemas from firmware .bin files
# Usage: extract-schema-firmware.sh <firmware.bin> [device-type]
#
# Requires: binwalk, unsquashfs (squashfs-tools), jq
#
# Firmware files can be downloaded from:
# - https://ui.com/download/releases/firmware
# - https://community.ui.com/releases
#
set -euo pipefail

FIRMWARE_FILE="${1:?Usage: extract-schema-firmware.sh <firmware.bin> [device-type]}"
DEVICE_TYPE="${2:-unknown}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEMA_BASE_DIR="$SCRIPT_DIR/../schemas"
WORK_DIR=$(mktemp -d)

echo "=== UniFi Schema Extraction from Firmware ==="
echo "Firmware: $FIRMWARE_FILE"
echo "Device type: $DEVICE_TYPE"
echo "Work dir: $WORK_DIR"
echo ""

# Check for required tools
for tool in binwalk unsquashfs jq; do
  if ! command -v "$tool" &>/dev/null; then
    echo "ERROR: $tool is required but not installed"
    echo ""
    echo "Install with:"
    echo "  nix-shell -p binwalk squashfs-tools-ng jq"
    echo "  # or"
    echo "  apt install binwalk squashfs-tools jq"
    exit 1
  fi
done

cleanup() {
  echo "Cleaning up work directory..."
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# Copy firmware to work directory
cp "$FIRMWARE_FILE" "$WORK_DIR/firmware.bin"
cd "$WORK_DIR"

# Extract firmware
echo "=== Extracting firmware with binwalk ==="
binwalk -e firmware.bin

# Find the extracted directory
EXTRACTED_DIR=$(find . -maxdepth 1 -type d -name "_*" | head -1)
if [[ -z "$EXTRACTED_DIR" ]]; then
  echo "ERROR: binwalk did not extract anything"
  echo "Firmware structure:"
  binwalk firmware.bin
  exit 1
fi

echo "Extracted to: $EXTRACTED_DIR"

# Find squashfs-root (may need multiple extraction layers)
echo ""
echo "=== Searching for filesystem ==="
SQUASHFS_ROOT=""

# Try direct squashfs-root
if [[ -d "$EXTRACTED_DIR/squashfs-root" ]]; then
  SQUASHFS_ROOT="$EXTRACTED_DIR/squashfs-root"
fi

# Try nested extraction (some firmware has multiple layers)
if [[ -z "$SQUASHFS_ROOT" ]]; then
  echo "Trying nested extraction..."
  for nested in "$EXTRACTED_DIR"/*; do
    if [[ -f "$nested" ]] && file "$nested" | grep -q "Squashfs"; then
      echo "Found squashfs: $nested"
      unsquashfs -d "$WORK_DIR/squashfs-root" "$nested" 2>/dev/null || true
      if [[ -d "$WORK_DIR/squashfs-root" ]]; then
        SQUASHFS_ROOT="$WORK_DIR/squashfs-root"
        break
      fi
    fi
  done
fi

if [[ -z "$SQUASHFS_ROOT" ]] || [[ ! -d "$SQUASHFS_ROOT" ]]; then
  echo "ERROR: Could not find squashfs filesystem"
  echo "Directory structure:"
  find "$EXTRACTED_DIR" -maxdepth 3 -type d
  exit 1
fi

echo "Found filesystem: $SQUASHFS_ROOT"

# Search for integration.json
echo ""
echo "=== Searching for OpenAPI spec ==="
SPEC_FILE=$(find "$SQUASHFS_ROOT" -name "integration.json" -path "*api-docs*" 2>/dev/null | head -1 || echo "")

if [[ -z "$SPEC_FILE" ]]; then
  # Try alternate locations
  SPEC_FILE=$(find "$SQUASHFS_ROOT" -name "integration.json" 2>/dev/null | head -1 || echo "")
fi

if [[ -z "$SPEC_FILE" ]]; then
  echo "ERROR: Could not find integration.json"
  echo ""
  echo "Searching for any JSON API files..."
  find "$SQUASHFS_ROOT" -name "*.json" -path "*api*" 2>/dev/null | head -20 || true
  echo ""
  echo "Searching for unifi directories..."
  find "$SQUASHFS_ROOT" -type d -name "*unifi*" 2>/dev/null | head -20 || true
  exit 1
fi

echo "Found: $SPEC_FILE"

# Get version from spec
if ! jq -e '.info.version' "$SPEC_FILE" &>/dev/null; then
  echo "ERROR: integration.json is not valid JSON or missing version"
  head -20 "$SPEC_FILE"
  exit 1
fi

SPEC_VERSION=$(jq -r '.info.version' "$SPEC_FILE")
echo "Detected version: $SPEC_VERSION"

# Create output directory with device info
SCHEMA_DIR="$SCHEMA_BASE_DIR/$SPEC_VERSION"
mkdir -p "$SCHEMA_DIR"

# Save the spec
cp "$SPEC_FILE" "$SCHEMA_DIR/integration.json"
echo "Saved: integration.json"

# Extract metadata with firmware source info
echo ""
echo "=== Extracting metadata ==="
FIRMWARE_NAME=$(basename "$FIRMWARE_FILE")
jq '{
  version: .info.version,
  title: .info.title,
  description: .info.description,
  paths: (.paths | keys | length),
  schemas: (.components.schemas | keys | length),
  source: "firmware",
  firmwareFile: $firmware,
  deviceType: $device,
  extractedAt: now | strftime("%Y-%m-%dT%H:%M:%SZ")
}' --arg firmware "$FIRMWARE_NAME" --arg device "$DEVICE_TYPE" "$SPEC_FILE" > "$SCHEMA_DIR/metadata.json"
echo "Saved: metadata.json"

# Extract schema names
echo ""
echo "=== Extracting schema definitions ==="
jq '.components.schemas | keys' "$SPEC_FILE" > "$SCHEMA_DIR/schema-names.json"
SCHEMA_COUNT=$(jq 'length' "$SCHEMA_DIR/schema-names.json")
echo "Found $SCHEMA_COUNT schema definitions"

# Extract API paths
echo ""
echo "=== Extracting API paths ==="
jq '.paths | keys' "$SPEC_FILE" > "$SCHEMA_DIR/api-paths.json"
PATH_COUNT=$(jq 'length' "$SCHEMA_DIR/api-paths.json")
echo "Found $PATH_COUNT API paths"

# Extract required fields for key schemas
echo ""
echo "=== Extracting required fields ==="
jq '
.components.schemas | to_entries | map(
  select(.value.required != null) |
  {
    name: .key,
    required: .value.required,
    properties: (.value.properties | keys)
  }
)' "$SPEC_FILE" > "$SCHEMA_DIR/required-fields.json"
echo "Saved: required-fields.json"

# Look for MongoDB-related files
echo ""
echo "=== Searching for MongoDB schemas ==="
MONGO_FILES=$(find "$SQUASHFS_ROOT" -name "*.bson" -o -name "*mongo*" -o -name "*schema*" 2>/dev/null | head -20 || echo "")
if [[ -n "$MONGO_FILES" ]]; then
  echo "Found potential MongoDB files:"
  echo "$MONGO_FILES"
else
  echo "No MongoDB schema files found in firmware"
  echo "(MongoDB schemas are generated at runtime, use extract-schema.sh on a live device)"
fi

echo ""
echo "=== Extraction Complete ==="
echo "Schemas extracted to: $SCHEMA_DIR"
echo ""
echo "Files:"
ls -lh "$SCHEMA_DIR"
echo ""
echo "Note: For MongoDB schemas, run extract-schema.sh against a live device"
