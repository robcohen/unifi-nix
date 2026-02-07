#!/usr/bin/env bash
# Extract UniFi API schemas from a UDM
# Usage: extract-schema.sh <host> [ssh_user]
#
# Extracts versioned schemas for unifi-nix:
# - OpenAPI spec (Integration API)
# - All MongoDB collections with full schemas
# - Reference IDs (site, usergroup, apgroup, etc.)
#
set -euo pipefail

HOST="${1:?Usage: extract-schema.sh <host> [ssh_user]}"
SSH_USER="${2:-root}"

echo "Extracting schemas from $HOST..."

# Get API version from the OpenAPI spec
VERSION=$(ssh "$SSH_USER@$HOST" 'cat /usr/lib/unifi/webapps/ROOT/api-docs/integration.json 2>/dev/null' | grep -oP '"version"\s*:\s*"\K[^"]+' | head -1 || echo "unknown")

if [[ $VERSION == "unknown" ]]; then
  echo "ERROR: Could not determine API version"
  exit 1
fi

echo "Detected UniFi Network version: $VERSION"

SCHEMA_DIR="$(dirname "$0")/../schemas/$VERSION"
mkdir -p "$SCHEMA_DIR"

# 1. Extract Integration API (OpenAPI 3.1 spec)
echo ""
echo "=== Extracting Integration API schema ==="
ssh "$SSH_USER@$HOST" 'cat /usr/lib/unifi/webapps/ROOT/api-docs/integration.json' >"$SCHEMA_DIR/integration.json"
echo "Saved: integration.json ($(wc -c <"$SCHEMA_DIR/integration.json") bytes)"

# 2. List ALL MongoDB collections (not hardcoded)
echo ""
echo "=== Discovering MongoDB collections ==="
ALL_COLLECTIONS=$(ssh "$SSH_USER@$HOST" 'mongo --port 27117 --quiet ace --eval "
db.getCollectionNames().forEach(function(c) { print(c); })
"')
echo "Found $(echo "$ALL_COLLECTIONS" | wc -l) collections"

# 3. Extract field names for each collection (union of all documents)
echo ""
echo "=== Extracting MongoDB field schemas ==="
ssh "$SSH_USER@$HOST" 'mongo --port 27117 --quiet ace --eval "
var result = {};
db.getCollectionNames().forEach(function(collName) {
  // Skip system collections
  if (collName.startsWith(\"system.\")) return;

  // Collect ALL unique field names from ALL documents
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
"' >"$SCHEMA_DIR/mongodb-fields.json"
echo "Saved: mongodb-fields.json"

# 4. Extract full example documents (for understanding types and defaults)
# Uses JSON.stringify for proper JSON output (converts ObjectId/UUID to strings)
echo ""
echo "=== Extracting MongoDB example documents ==="
ssh "$SSH_USER@$HOST" 'mongo --port 27117 --quiet ace --eval "
// Key collections for unifi-nix configuration
var configCollections = [
  \"wlanconf\",
  \"networkconf\",
  \"firewallrule\",
  \"firewallgroup\",
  \"portforward\",
  \"routing\",
  \"dhcpd_static\",
  \"dhcp_option\",
  \"wlangroup\",
  \"apgroup\",
  \"usergroup\",
  \"radiusprofile\",
  \"hotspotconf\",
  \"portconf\",
  \"setting\",
  \"traffic_rule\",
  \"device\"
];

var result = {};

configCollections.forEach(function(collName) {
  // Get example document
  var doc = db[collName].findOne();
  if (doc) {
    result[collName] = doc;
  } else {
    result[collName] = null;
  }
});

// Also get a VLAN network example (different from default LAN)
var vlanNet = db.networkconf.findOne({vlan_enabled: true});
if (vlanNet) {
  result[\"networkconf_vlan\"] = vlanNet;
}

// Get the default LAN specifically
var defaultLan = db.networkconf.findOne({attr_hidden_id: \"LAN\"});
if (defaultLan) {
  result[\"networkconf_lan\"] = defaultLan;
}

// Use JSON.stringify for proper JSON (converts ObjectId to {$oid:...} format)
print(JSON.stringify(result, null, 2));
"' >"$SCHEMA_DIR/mongodb-examples.json"
echo "Saved: mongodb-examples.json"

# 5. Extract reference IDs needed for creating records
echo ""
echo "=== Extracting reference IDs ==="
ssh "$SSH_USER@$HOST" 'mongo --port 27117 --quiet ace --eval "
var refs = {
  site: db.site.findOne({}, {_id: 1, name: 1}),
  usergroup_default: db.usergroup.findOne({name: \"Default\"}, {_id: 1, name: 1}),
  apgroup_default: db.apgroup.findOne({}, {_id: 1, name: 1}),
  wlangroup_default: db.wlangroup.findOne({}, {_id: 1, name: 1}),
  devices: db.device.find({}, {_id: 1, mac: 1, name: 1, model: 1}).toArray()
};
print(JSON.stringify(refs, null, 2));
"' >"$SCHEMA_DIR/reference-ids.json"
echo "Saved: reference-ids.json"

# 6. Extract collection statistics (doc counts, indexes)
echo ""
echo "=== Extracting collection statistics ==="
ssh "$SSH_USER@$HOST" 'mongo --port 27117 --quiet ace --eval "
var stats = {};
db.getCollectionNames().forEach(function(collName) {
  if (collName.startsWith(\"system.\")) return;
  var s = db[collName].stats();
  stats[collName] = {
    count: s.count,
    size: s.size,
    avgObjSize: s.avgObjSize || 0,
    indexes: Object.keys(db[collName].getIndexes().reduce(function(m, i) { m[i.name] = 1; return m; }, {}))
  };
});
print(JSON.stringify(stats, null, 2));
"' >"$SCHEMA_DIR/mongodb-stats.json"
echo "Saved: mongodb-stats.json"

echo ""
echo "=== Extraction Complete ==="
echo "Schemas extracted to: $SCHEMA_DIR"
echo ""
echo "Files:"
ls -lh "$SCHEMA_DIR"
echo ""
echo "Collection counts:"
jq 'to_entries | .[] | "\(.key): \(.value.count) docs"' "$SCHEMA_DIR/mongodb-stats.json" 2>/dev/null | head -20
