#!/usr/bin/env bash
# Extract UniFi API schemas from official Docker image
# Usage: extract-schema-docker.sh [version]
#
# NOTE: The self-hosted Network Application generates the OpenAPI spec at runtime.
# This script starts a temporary container, waits for it to initialize, then
# fetches the spec via HTTP.
#
# For static extraction (no runtime required), use extract-schema.sh against
# a UniFi OS device (UDM, UDM Pro, UCG) which has the spec as a static file.
#
set -euo pipefail

VERSION="${1:-latest}"
IMAGE="linuxserver/unifi-network-application:${VERSION}"
CONTAINER_NAME="unifi-schema-extract-$$"
MONGO_CONTAINER_NAME="unifi-mongo-extract-$$"
NETWORK_NAME="unifi-extract-net-$$"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEMA_BASE_DIR="$SCRIPT_DIR/../schemas"

echo "=== UniFi Schema Extraction from Docker ==="
echo "Image: $IMAGE"
echo ""
echo "NOTE: This starts temporary containers to fetch the runtime-generated"
echo "      OpenAPI spec. For faster extraction, use extract-schema.sh"
echo "      against a live UniFi OS device."
echo ""

# Check for required tools
for tool in docker jq curl; do
  if ! command -v "$tool" &>/dev/null; then
    echo "ERROR: $tool is required but not installed"
    exit 1
  fi
done

cleanup() {
  echo ""
  echo "Cleaning up containers..."
  docker rm -f "$CONTAINER_NAME" &>/dev/null || true
  docker rm -f "$MONGO_CONTAINER_NAME" &>/dev/null || true
  docker network rm "$NETWORK_NAME" &>/dev/null || true
}
trap cleanup EXIT

# Create network for containers
echo "Creating Docker network..."
docker network create "$NETWORK_NAME" &>/dev/null || true

# Start MongoDB (required by Network Application)
echo "Starting MongoDB container..."
docker run -d --name "$MONGO_CONTAINER_NAME" \
  --network "$NETWORK_NAME" \
  -e MONGO_INITDB_DATABASE=unifi \
  mongo:7.0 &>/dev/null

# Wait for MongoDB
echo "Waiting for MongoDB to start..."
sleep 5

# Pull and start the UniFi Network Application
echo "Pulling UniFi Network Application image..."
docker pull "$IMAGE" &>/dev/null

echo "Starting UniFi Network Application container..."
docker run -d --name "$CONTAINER_NAME" \
  --network "$NETWORK_NAME" \
  -e PUID=1000 \
  -e PGID=1000 \
  -e MONGO_HOST="$MONGO_CONTAINER_NAME" \
  -e MONGO_PORT=27017 \
  -e MONGO_DBNAME=unifi \
  -p 18443:8443 \
  "$IMAGE" &>/dev/null

# Wait for the application to start
echo "Waiting for UniFi Network Application to initialize..."
echo "(This may take 1-2 minutes)"

MAX_WAIT=120
WAITED=0
while [[ $WAITED -lt $MAX_WAIT ]]; do
  if curl -sk "https://localhost:18443/api-docs/integration.json" 2>/dev/null | jq -e '.info.version' &>/dev/null; then
    echo "Application is ready!"
    break
  fi
  sleep 5
  WAITED=$((WAITED + 5))
  echo "  Waiting... ($WAITED seconds)"
done

if [[ $WAITED -ge $MAX_WAIT ]]; then
  echo "ERROR: Timeout waiting for UniFi Network Application to start"
  echo ""
  echo "Container logs:"
  docker logs "$CONTAINER_NAME" 2>&1 | tail -50
  exit 1
fi

# Fetch the OpenAPI spec
echo ""
echo "=== Fetching OpenAPI spec ==="
TEMP_SPEC=$(mktemp)
curl -sk "https://localhost:18443/api-docs/integration.json" > "$TEMP_SPEC"

# Validate the spec
if ! jq -e '.info.version' "$TEMP_SPEC" &>/dev/null; then
  echo "ERROR: Failed to fetch valid OpenAPI spec"
  echo "Response:"
  head -20 "$TEMP_SPEC"
  exit 1
fi

# Get version from spec
SPEC_VERSION=$(jq -r '.info.version' "$TEMP_SPEC")
echo "Detected version: $SPEC_VERSION"

# Create output directory
SCHEMA_DIR="$SCHEMA_BASE_DIR/$SPEC_VERSION"
mkdir -p "$SCHEMA_DIR"

# Save the spec
cp "$TEMP_SPEC" "$SCHEMA_DIR/integration.json"
echo "Saved: integration.json"

# Extract metadata
echo ""
echo "=== Extracting metadata ==="
jq '{
  version: .info.version,
  title: .info.title,
  description: .info.description,
  paths: (.paths | keys | length),
  schemas: (.components.schemas | keys | length),
  source: "docker",
  image: $image,
  extractedAt: now | strftime("%Y-%m-%dT%H:%M:%SZ")
}' --arg image "$IMAGE" "$TEMP_SPEC" > "$SCHEMA_DIR/metadata.json"
echo "Saved: metadata.json"

# Extract schema names
echo ""
echo "=== Extracting schema definitions ==="
jq '.components.schemas | keys' "$TEMP_SPEC" > "$SCHEMA_DIR/schema-names.json"
SCHEMA_COUNT=$(jq 'length' "$SCHEMA_DIR/schema-names.json")
echo "Found $SCHEMA_COUNT schema definitions"

# Extract API paths
echo ""
echo "=== Extracting API paths ==="
jq '.paths | keys' "$TEMP_SPEC" > "$SCHEMA_DIR/api-paths.json"
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
)' "$TEMP_SPEC" > "$SCHEMA_DIR/required-fields.json"
echo "Saved: required-fields.json"

# Cleanup temp file
rm -f "$TEMP_SPEC"

echo ""
echo "=== Extraction Complete ==="
echo "Schemas extracted to: $SCHEMA_DIR"
echo ""
echo "Files:"
ls -lh "$SCHEMA_DIR"
echo ""
echo "To compare with live extraction:"
echo "  ./scripts/extract-schema.sh <udm-ip>"
