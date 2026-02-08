#!/usr/bin/env bash
# extract-from-docker.sh - Extract UniFi MongoDB schema using Docker
# Usage: ./extract-from-docker.sh [version] [output-dir]
#
# Examples:
#   ./extract-from-docker.sh                    # Latest version, default output
#   ./extract-from-docker.sh 8.6.9              # Specific version
#   ./extract-from-docker.sh latest ../schemas  # Custom output directory
#
# This script:
#   1. Starts UniFi Network Application in Docker
#   2. Waits for initialization
#   3. Extracts MongoDB schema (collections, fields, enums, examples)
#   4. Saves to versioned directory
#   5. Cleans up containers

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UNIFI_VERSION="${1:-latest}"
OUTPUT_BASE="${2:-$SCRIPT_DIR/../../schemas}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

cleanup() {
  log_info "Cleaning up containers..."
  cd "$SCRIPT_DIR"
  docker compose down -v --remove-orphans 2>/dev/null || true
}

trap cleanup EXIT

# Check dependencies
for cmd in docker jq; do
  if ! command -v "$cmd" &>/dev/null; then
    log_error "Required command not found: $cmd"
    exit 1
  fi
done

# Check Docker is running
if ! docker info &>/dev/null; then
  log_error "Docker is not running"
  exit 1
fi

log_info "=== UniFi Docker Schema Extraction ==="
log_info "Version: $UNIFI_VERSION"
log_info "Output: $OUTPUT_BASE"
echo ""

# Start containers
log_info "Starting containers..."
cd "$SCRIPT_DIR"
export UNIFI_VERSION
docker compose up -d

# Wait for MongoDB to be ready
log_info "Waiting for MongoDB..."
for i in {1..30}; do
  if docker exec unifi-mongo mongosh --eval "db.adminCommand('ping')" &>/dev/null; then
    log_success "MongoDB is ready"
    break
  fi
  echo -n "."
  sleep 2
done
echo ""

# Wait for UniFi to initialize (creates collections)
log_info "Waiting for UniFi to initialize (this may take 2-5 minutes)..."
for i in {1..60}; do
  # Check if site collection exists (indicates initialization complete)
  if docker exec unifi-mongo mongosh -u unifi -p unifi --authenticationDatabase admin unifi \
    --eval "db.site.countDocuments()" 2>/dev/null | grep -q "^[0-9]"; then
    log_success "UniFi initialized"
    break
  fi
  echo -n "."
  sleep 5
done
echo ""

# Get actual version from UniFi
log_info "Detecting UniFi version..."
DETECTED_VERSION=$(docker exec unifi-mongo mongosh -u unifi -p unifi --authenticationDatabase admin unifi \
  --quiet --eval "db.version_history.find().sort({_id:-1}).limit(1).toArray()[0]?.version || 'unknown'" 2>/dev/null | tr -d '"' || echo "unknown")

if [[ $DETECTED_VERSION == "unknown" ]]; then
  log_warn "Could not detect version, using: $UNIFI_VERSION"
  DETECTED_VERSION="$UNIFI_VERSION"
fi
log_info "Detected version: $DETECTED_VERSION"

# Create output directory
OUTPUT_DIR="$OUTPUT_BASE/$DETECTED_VERSION"
mkdir -p "$OUTPUT_DIR"
log_info "Output directory: $OUTPUT_DIR"
echo ""

# Extract schema
log_info "=== Extracting Schema ==="

# 1. List all collections
log_info "Extracting collection list..."
docker exec unifi-mongo mongosh -u unifi -p unifi --authenticationDatabase admin unifi \
  --quiet --eval "JSON.stringify(db.getCollectionNames())" >"$OUTPUT_DIR/collections.json"
log_success "Saved: collections.json"

# 2. Extract field names and types for each collection
log_info "Extracting field schemas..."
docker exec unifi-mongo mongosh -u unifi -p unifi --authenticationDatabase admin unifi \
  --quiet --eval '
var collections = db.getCollectionNames();
var schemas = {};

collections.forEach(function(coll) {
  if (coll.startsWith("system.")) return;

  var sample = db[coll].findOne();
  if (sample) {
    var fields = {};
    Object.keys(sample).forEach(function(key) {
      var val = sample[key];
      var type = typeof val;
      if (val === null) type = "null";
      else if (Array.isArray(val)) type = "array";
      else if (val instanceof ObjectId) type = "ObjectId";
      else if (val instanceof Date) type = "Date";
      fields[key] = type;
    });
    schemas[coll] = {
      fieldCount: Object.keys(fields).length,
      fields: fields
    };
  }
});

JSON.stringify(schemas, null, 2);
' >"$OUTPUT_DIR/field-schemas.json"
log_success "Saved: field-schemas.json"

# 3. Extract example documents for key collections
log_info "Extracting example documents..."
docker exec unifi-mongo mongosh -u unifi -p unifi --authenticationDatabase admin unifi \
  --quiet --eval '
var keyCollections = [
  "networkconf", "wlanconf", "portforward", "firewall_policy", "firewall_zone",
  "firewallgroup", "traffic_rule", "radiusprofile", "portconf", "apgroup",
  "usergroup", "dpigroup", "scheduletask", "wlangroup", "dhcp_option",
  "setting", "site", "device"
];

var examples = {};
keyCollections.forEach(function(coll) {
  var doc = db[coll].findOne();
  if (doc) {
    // Remove sensitive fields
    delete doc.x_passphrase;
    delete doc.x_password;
    delete doc.x_psk;
    delete doc.x_secret;
    examples[coll] = doc;
  }
});

JSON.stringify(examples, null, 2);
' >"$OUTPUT_DIR/mongodb-examples.json"
log_success "Saved: mongodb-examples.json"

# 4. Extract enum values from existing data
log_info "Extracting enum values..."
docker exec unifi-mongo mongosh -u unifi -p unifi --authenticationDatabase admin unifi \
  --quiet --eval '
var enums = {
  // From firewall_zone
  zone_keys: db.firewall_zone.distinct("zone_key").filter(x => x),

  // From networkconf
  network_purposes: db.networkconf.distinct("purpose").filter(x => x),
  network_groups: db.networkconf.distinct("networkgroup").filter(x => x),

  // From wlanconf
  wifi_security: db.wlanconf.distinct("security").filter(x => x),
  wpa_modes: db.wlanconf.distinct("wpa_mode").filter(x => x),
  wpa_enc: db.wlanconf.distinct("wpa_enc").filter(x => x),

  // From firewall_policy
  policy_actions: db.firewall_policy.distinct("action").filter(x => x),
  match_types: db.firewall_policy.distinct("source.matching_target").filter(x => x),

  // From portforward
  pf_protocols: db.portforward.distinct("proto").filter(x => x),

  // From traffic_rule
  traffic_actions: db.traffic_rule.distinct("action").filter(x => x),
  traffic_targets: db.traffic_rule.distinct("matching_target").filter(x => x),

  // From setting (for discovering setting keys)
  setting_keys: db.setting.distinct("key").filter(x => x)
};

JSON.stringify(enums, null, 2);
' >"$OUTPUT_DIR/enums.json"
log_success "Saved: enums.json"

# 5. Extract default site configuration
log_info "Extracting site configuration..."
docker exec unifi-mongo mongosh -u unifi -p unifi --authenticationDatabase admin unifi \
  --quiet --eval '
var site = db.site.findOne({name: "default"});
var settings = db.setting.find({site_id: site._id.toString()}).toArray();

JSON.stringify({
  site: site,
  settings: settings.map(function(s) {
    delete s.x_password;
    return s;
  })
}, null, 2);
' >"$OUTPUT_DIR/site-defaults.json"
log_success "Saved: site-defaults.json"

# 6. Save version info
echo "$DETECTED_VERSION" >"$OUTPUT_DIR/version"
log_success "Saved: version"

# Summary
echo ""
log_info "=== Extraction Complete ==="
log_success "Schema saved to: $OUTPUT_DIR"
echo ""
echo "Files created:"
ls -la "$OUTPUT_DIR"
echo ""

# Show collection stats
log_info "Collection statistics:"
docker exec unifi-mongo mongosh -u unifi -p unifi --authenticationDatabase admin unifi \
  --quiet --eval '
var stats = db.getCollectionNames()
  .filter(c => !c.startsWith("system."))
  .map(c => ({ name: c, count: db[c].countDocuments() }))
  .filter(s => s.count > 0)
  .sort((a,b) => b.count - a.count);

stats.forEach(s => print("  " + s.name + ": " + s.count + " documents"));
'

echo ""
log_success "Done! Containers will be cleaned up automatically."
