#!/usr/bin/env bash
# Extract MongoDB schemas from a user's device on first run
# Usage: extract-device-schema.sh <host> [ssh-user]
#
# This is called automatically by the deploy script on first run.
# Schemas are cached locally to avoid repeated extraction.
#
set -euo pipefail

HOST="${1:?Usage: extract-device-schema.sh <host> [ssh-user]}"
SSH_USER="${2:-root}"

# Cache directory
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/unifi-nix"
DEVICE_CACHE_DIR="$CACHE_DIR/devices/$HOST"

# Check if we have cached schemas for this device
get_device_version() {
  ssh -o ConnectTimeout=10 -o BatchMode=yes "$SSH_USER@$HOST" \
    'cat /usr/lib/unifi/webapps/ROOT/api-docs/integration.json 2>/dev/null' |
    grep -oP '"version"\s*:\s*"\K[^"]+' | head -1 || echo "unknown"
}

echo "Checking device schema cache for $HOST..."

# Get current version from device
DEVICE_VERSION=$(get_device_version)
if [[ $DEVICE_VERSION == "unknown" ]]; then
  echo "ERROR: Could not determine UniFi version on $HOST"
  echo "Make sure SSH access is configured and the device is running UniFi OS"
  exit 1
fi

echo "Device version: $DEVICE_VERSION"

# Check cache
CACHE_VERSION_FILE="$DEVICE_CACHE_DIR/version"
CACHE_VALID=false

if [[ -f $CACHE_VERSION_FILE ]]; then
  CACHED_VERSION=$(cat "$CACHE_VERSION_FILE")
  if [[ $CACHED_VERSION == "$DEVICE_VERSION" ]]; then
    # Check cache age (refresh if older than 24 hours)
    CACHE_AGE=$(($(date +%s) - $(stat -c %Y "$CACHE_VERSION_FILE" 2>/dev/null || echo 0)))
    if [[ $CACHE_AGE -lt 86400 ]]; then
      echo "Using cached schemas (age: ${CACHE_AGE}s)"
      CACHE_VALID=true
    else
      echo "Cache expired, refreshing..."
    fi
  else
    echo "Version changed ($CACHED_VERSION -> $DEVICE_VERSION), refreshing..."
  fi
fi

if [[ $CACHE_VALID == "true" ]]; then
  echo "$DEVICE_CACHE_DIR"
  exit 0
fi

# Extract fresh schemas
echo ""
echo "Extracting MongoDB schemas from $HOST..."
mkdir -p "$DEVICE_CACHE_DIR"

# Extract field names for all collections
echo "  Extracting field schemas..."
ssh "$SSH_USER@$HOST" 'mongo --port 27117 --quiet ace --eval "
var result = {};
db.getCollectionNames().forEach(function(collName) {
  if (collName.startsWith(\"system.\")) return;
  var allFields = {};
  db[collName].find().limit(100).forEach(function(doc) {
    Object.keys(doc).forEach(function(key) {
      allFields[key] = true;
    });
  });
  var fields = Object.keys(allFields).sort();
  if (fields.length > 0) {
    result[collName] = fields;
  }
});
print(JSON.stringify(result, null, 2));
"' >"$DEVICE_CACHE_DIR/mongodb-fields.json"

# Extract example documents
echo "  Extracting example documents..."
ssh "$SSH_USER@$HOST" 'mongo --port 27117 --quiet ace --eval "
var configCollections = [
  \"wlanconf\", \"networkconf\", \"firewallrule\", \"firewallgroup\",
  \"portforward\", \"routing\", \"dhcpd_static\", \"dhcp_option\",
  \"wlangroup\", \"apgroup\", \"usergroup\", \"radiusprofile\",
  \"hotspotconf\", \"portconf\", \"setting\", \"traffic_rule\", \"device\"
];
var result = {};
configCollections.forEach(function(collName) {
  var doc = db[collName].findOne();
  if (doc) result[collName] = doc;
  else result[collName] = null;
});
var vlanNet = db.networkconf.findOne({vlan_enabled: true});
if (vlanNet) result[\"networkconf_vlan\"] = vlanNet;
var defaultLan = db.networkconf.findOne({attr_hidden_id: \"LAN\"});
if (defaultLan) result[\"networkconf_lan\"] = defaultLan;
print(JSON.stringify(result, null, 2));
"' >"$DEVICE_CACHE_DIR/mongodb-examples.json"

# Extract reference IDs
echo "  Extracting reference IDs..."
ssh "$SSH_USER@$HOST" 'mongo --port 27117 --quiet ace --eval "
var refs = {
  site: db.site.findOne({}, {_id: 1, name: 1}),
  usergroup_default: db.usergroup.findOne({name: \"Default\"}, {_id: 1, name: 1}),
  apgroup_default: db.apgroup.findOne({}, {_id: 1, name: 1}),
  wlangroup_default: db.wlangroup.findOne({}, {_id: 1, name: 1}),
  devices: db.device.find({}, {_id: 1, mac: 1, name: 1, model: 1}).toArray()
};
print(JSON.stringify(refs, null, 2));
"' >"$DEVICE_CACHE_DIR/reference-ids.json"

# Save version marker
echo "$DEVICE_VERSION" >"$CACHE_VERSION_FILE"

# Validate extraction
if ! jq empty "$DEVICE_CACHE_DIR/mongodb-fields.json" 2>/dev/null; then
  echo "ERROR: Failed to extract valid MongoDB schemas"
  rm -rf "$DEVICE_CACHE_DIR"
  exit 1
fi

echo ""
echo "Device schemas cached at: $DEVICE_CACHE_DIR"
echo "$DEVICE_CACHE_DIR"
