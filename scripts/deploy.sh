#!/usr/bin/env bash
# unifi-deploy: Apply UniFi configuration to UDM via SSH+MongoDB
set -euo pipefail

CONFIG_JSON="${1:-}"
HOST="${2:-}"
DRY_RUN="${DRY_RUN:-false}"

if [[ -z "$CONFIG_JSON" ]] || [[ -z "$HOST" ]]; then
  echo "Usage: unifi-deploy <config.json> <host>"
  echo ""
  echo "Arguments:"
  echo "  config.json  Path to generated config JSON (from unifi-eval)"
  echo "  host         UDM IP address or hostname"
  echo ""
  echo "Environment:"
  echo "  DRY_RUN=true           Show commands without executing"
  echo "  UNIFI_SECRETS_DIR=path Directory containing secret files"
  echo ""
  echo "Example:"
  echo "  unifi-eval ./sites/mysite.nix > config.json"
  echo "  unifi-deploy config.json 192.168.1.1"
  exit 1
fi

if [[ ! -f "$CONFIG_JSON" ]]; then
  echo "Error: Config file not found: $CONFIG_JSON"
  exit 1
fi

echo "=== UniFi Declarative Deploy ==="
echo "Host: $HOST"
[[ "$DRY_RUN" == "true" ]] && echo "Mode: DRY RUN"
echo ""

DESIRED=$(cat "$CONFIG_JSON")

run_mongo() {
  local cmd="$1"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN] mongo: ${cmd:0:80}..."
  else
    ssh -o ConnectTimeout=10 "root@$HOST" "mongo --quiet --port 27117 ace --eval '$cmd'"
  fi
}

# Get site_id
echo "Fetching site info..."
SITE_INFO=$(ssh "root@$HOST" "mongo --quiet --port 27117 ace --eval 'JSON.stringify(db.site.findOne())'")
SITE_ID=$(echo "$SITE_INFO" | jq -r '._id."$oid"')
echo "Site ID: $SITE_ID"

# Build network name -> id mapping
echo "Building network mappings..."
NETWORK_MAP=$(ssh "root@$HOST" 'mongo --quiet --port 27117 ace --eval "
  JSON.stringify(db.networkconf.find({}, {name: 1}).toArray().reduce(function(m, n) {
    m[n.name] = n._id.str || n._id.toString();
    return m;
  }, {}))
"')

echo ""
echo "=== Applying Networks ==="

for net in $(echo "$DESIRED" | jq -r '.networks | keys[]'); do
  echo "Processing: $net"
  desired_net=$(echo "$DESIRED" | jq -c ".networks[\"$net\"]")
  existing_id=$(echo "$NETWORK_MAP" | jq -r ".[\"$net\"] // empty")

  if [[ -z "$existing_id" ]]; then
    echo "  Creating new network"
    insert_doc=$(echo "$desired_net" | jq -c ". + {site_id: \"$SITE_ID\"}")
    run_mongo "db.networkconf.insertOne($insert_doc)"
  else
    echo "  Updating (id: ${existing_id:0:8}...)"
    update_doc=$(echo "$desired_net" | jq -c 'del(.name)')
    run_mongo "db.networkconf.updateOne({_id: ObjectId(\"$existing_id\")}, {\$set: $update_doc})"
  fi
done

# Refresh network map
if [[ "$DRY_RUN" != "true" ]]; then
  NETWORK_MAP=$(ssh "root@$HOST" 'mongo --quiet --port 27117 ace --eval "
    JSON.stringify(db.networkconf.find({}, {name: 1}).toArray().reduce(function(m, n) {
      m[n.name] = n._id.str || n._id.toString();
      return m;
    }, {}))
  "')
fi

echo ""
echo "=== Applying WiFi ==="

for wifi in $(echo "$DESIRED" | jq -r '.wifi | keys[]'); do
  desired_wifi=$(echo "$DESIRED" | jq -c ".wifi[\"$wifi\"]")
  ssid=$(echo "$desired_wifi" | jq -r '.name')
  echo "Processing: $ssid"

  # Resolve network reference
  net_name=$(echo "$desired_wifi" | jq -r '._network_name')
  net_id=$(echo "$NETWORK_MAP" | jq -r ".[\"$net_name\"] // empty")

  if [[ -z "$net_id" ]]; then
    echo "  WARNING: Network '$net_name' not found, skipping"
    continue
  fi

  # Resolve passphrase
  passphrase=$(echo "$desired_wifi" | jq -r '.x_passphrase')
  if echo "$desired_wifi" | jq -e '.x_passphrase._secret' > /dev/null 2>&1; then
    secret_path=$(echo "$desired_wifi" | jq -r '.x_passphrase._secret')
    echo "  Resolving secret: $secret_path"

    if [[ -n "${UNIFI_SECRETS_DIR:-}" ]] && [[ -f "${UNIFI_SECRETS_DIR}/${secret_path}" ]]; then
      passphrase=$(cat "${UNIFI_SECRETS_DIR}/${secret_path}")
    else
      # Try environment variable
      env_var=$(echo "$secret_path" | tr '/' '_' | tr '[:lower:]' '[:upper:]')
      passphrase="${!env_var:-}"
    fi

    if [[ -z "$passphrase" ]] || [[ "$passphrase" == "null" ]]; then
      echo "  ERROR: Could not resolve secret '$secret_path'"
      exit 1
    fi
  fi

  wifi_doc=$(echo "$desired_wifi" | jq -c "
    del(._network_name) |
    .networkconf_id = \"$net_id\" |
    .x_passphrase = \"$passphrase\" |
    .site_id = \"$SITE_ID\"
  ")

  existing=$(ssh "root@$HOST" "mongo --quiet --port 27117 ace --eval '
    JSON.stringify(db.wlanconf.findOne({name: \"$ssid\"}, {_id: 1}))
  '" 2>/dev/null || echo "null")

  if [[ "$existing" == "null" ]] || [[ -z "$existing" ]]; then
    echo "  Creating new WiFi"
    run_mongo "db.wlanconf.insertOne($wifi_doc)"
  else
    existing_id=$(echo "$existing" | jq -r '._id."$oid"')
    echo "  Updating (id: ${existing_id:0:8}...)"
    update_doc=$(echo "$wifi_doc" | jq -c 'del(.name, .site_id)')
    run_mongo "db.wlanconf.updateOne({_id: ObjectId(\"$existing_id\")}, {\$set: $update_doc})"
  fi
done

echo ""
echo "=== Applying Firewall Rules ==="

rule_count=$(echo "$DESIRED" | jq '.firewallRules | length')
if [[ "$rule_count" -gt 0 ]]; then
  for rule in $(echo "$DESIRED" | jq -r '.firewallRules | keys[]'); do
    desired_rule=$(echo "$DESIRED" | jq -c ".firewallRules[\"$rule\"]")
    desc=$(echo "$desired_rule" | jq -r '.description')
    echo "Processing: $desc"

    rule_doc=$(echo "$desired_rule" | jq -c "
      del(._source_networks, ._dest_networks) |
      .site_id = \"$SITE_ID\"
    ")

    existing=$(ssh "root@$HOST" "mongo --quiet --port 27117 ace --eval '
      JSON.stringify(db.traffic_rule.findOne({description: \"$desc\"}, {_id: 1}))
    '" 2>/dev/null || echo "null")

    if [[ "$existing" == "null" ]] || [[ -z "$existing" ]]; then
      echo "  Creating new rule"
      run_mongo "db.traffic_rule.insertOne($rule_doc)"
    else
      existing_id=$(echo "$existing" | jq -r '._id."$oid"')
      echo "  Updating"
      run_mongo "db.traffic_rule.updateOne({_id: ObjectId(\"$existing_id\")}, {\$set: $rule_doc})"
    fi
  done
else
  echo "  (none defined)"
fi

echo ""
echo "=== Complete ==="
echo "Changes applied. They should take effect within 30 seconds."
echo "If not, SSH to UDM and run: unifi-os restart"
