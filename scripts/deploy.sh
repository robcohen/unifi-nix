#!/usr/bin/env bash
# unifi-deploy: Apply UniFi configuration to UDM via SSH+MongoDB
set -euo pipefail

CONFIG_JSON="${1:-}"
HOST="${2:-}"
DRY_RUN="${DRY_RUN:-false}"
SSH_USER="${SSH_USER:-root}"
ALLOW_DELETES="${ALLOW_DELETES:-false}"
SKIP_SCHEMA_CACHE="${SKIP_SCHEMA_CACHE:-false}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ -z "$CONFIG_JSON" ]] || [[ -z "$HOST" ]]; then
  echo "Usage: unifi-deploy <config.json> <host>"
  echo ""
  echo "Arguments:"
  echo "  config.json  Path to generated config JSON (from unifi-eval)"
  echo "  host         UDM IP address or hostname"
  echo ""
  echo "Environment:"
  echo "  DRY_RUN=true                  Show commands without executing"
  echo "  SSH_USER=root                 SSH username (default: root)"
  echo "  ALLOW_DELETES=true            Delete resources not in config"
  echo "  UNIFI_SECRETS_DIR=path        Directory containing secret files"
  echo "  SKIP_SCHEMA_CACHE=true        Skip device schema caching"
  echo "  SKIP_SCHEMA_VALIDATION=true   Deploy even if OpenAPI schema missing"
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

# Extract and cache device schemas on first run
if [[ "$SKIP_SCHEMA_CACHE" != "true" ]] && [[ -x "$SCRIPT_DIR/extract-device-schema.sh" ]]; then
  DEVICE_SCHEMA_DIR=$("$SCRIPT_DIR/extract-device-schema.sh" "$HOST" "$SSH_USER" 2>/dev/null | tail -1) || true
  if [[ -n "$DEVICE_SCHEMA_DIR" ]] && [[ -d "$DEVICE_SCHEMA_DIR" ]]; then
    echo "Device schemas: $DEVICE_SCHEMA_DIR"
    export UNIFI_DEVICE_SCHEMA_DIR="$DEVICE_SCHEMA_DIR"

    # Check if OpenAPI schema exists for this version
    DEVICE_VERSION=$(cat "$DEVICE_SCHEMA_DIR/version" 2>/dev/null || echo "unknown")
    OPENAPI_SCHEMA_DIR="$SCRIPT_DIR/../schemas/$DEVICE_VERSION"

    if [[ ! -f "$OPENAPI_SCHEMA_DIR/integration.json" ]]; then
      echo ""
      echo "ERROR: OpenAPI schema not found for version $DEVICE_VERSION"
      echo ""
      echo "Your device is running a version that isn't in the schema repository yet."
      echo "This can happen if:"
      echo "  1. Your device was recently upgraded"
      echo "  2. The CI pipeline hasn't extracted the new schema yet"
      echo ""
      echo "Options:"
      echo "  1. Wait for CI to extract the schema (runs every 6 hours)"
      echo "  2. Extract manually: ./scripts/extract-schema.sh $HOST"
      echo "  3. Skip validation: SKIP_SCHEMA_VALIDATION=true ./scripts/deploy.sh ..."
      echo ""

      if [[ "${SKIP_SCHEMA_VALIDATION:-false}" != "true" ]]; then
        exit 1
      else
        echo "WARNING: Proceeding without OpenAPI validation (SKIP_SCHEMA_VALIDATION=true)"
      fi
    else
      echo "OpenAPI schema: $OPENAPI_SCHEMA_DIR"
      export UNIFI_OPENAPI_SCHEMA_DIR="$OPENAPI_SCHEMA_DIR"
    fi
  fi
  echo ""
fi

# Validate configuration before deploying
if [[ -n "${UNIFI_OPENAPI_SCHEMA_DIR:-}" ]] && [[ -n "${UNIFI_DEVICE_SCHEMA_DIR:-}" ]]; then
  if [[ -x "$SCRIPT_DIR/validate-config.sh" ]]; then
    echo "=== Validating Configuration ==="
    if ! "$SCRIPT_DIR/validate-config.sh" "$CONFIG_JSON" "$UNIFI_OPENAPI_SCHEMA_DIR" "$UNIFI_DEVICE_SCHEMA_DIR"; then
      echo ""
      echo "Configuration validation failed. Fix the errors above before deploying."
      echo ""
      echo "To skip validation (not recommended):"
      echo "  SKIP_SCHEMA_VALIDATION=true ./scripts/deploy.sh ..."
      exit 1
    fi
    echo ""
  fi
elif [[ "${SKIP_SCHEMA_VALIDATION:-false}" != "true" ]]; then
  echo "WARNING: Skipping validation (schemas not available)"
  echo ""
fi

DESIRED=$(cat "$CONFIG_JSON")

run_mongo() {
  local cmd="$1"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN] mongo: ${cmd:0:80}..."
  else
    ssh -o ConnectTimeout=10 "$SSH_USER@$HOST" "mongo --quiet --port 27117 ace --eval '$cmd'"
  fi
}

# Get site_id
echo "Fetching site info..."
SITE_INFO=$(ssh "$SSH_USER@$HOST" "mongo --quiet --port 27117 ace --eval 'JSON.stringify(db.site.findOne())'")
SITE_ID=$(echo "$SITE_INFO" | jq -r '._id."$oid"')
echo "Site ID: $SITE_ID"

# Build network name -> id mapping
echo "Building network mappings..."
NETWORK_MAP=$(ssh "$SSH_USER@$HOST" 'mongo --quiet --port 27117 ace --eval "
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
  NETWORK_MAP=$(ssh "$SSH_USER@$HOST" 'mongo --quiet --port 27117 ace --eval "
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

  existing=$(ssh "$SSH_USER@$HOST" "mongo --quiet --port 27117 ace --eval '
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

    existing=$(ssh "$SSH_USER@$HOST" "mongo --quiet --port 27117 ace --eval '
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
echo "=== Applying Port Forwards ==="

pf_count=$(echo "$DESIRED" | jq '.portForwards | length')
if [[ "$pf_count" -gt 0 ]]; then
  for pf in $(echo "$DESIRED" | jq -r '.portForwards | keys[]'); do
    desired_pf=$(echo "$DESIRED" | jq -c ".portForwards[\"$pf\"]")
    name=$(echo "$desired_pf" | jq -r '.name')
    echo "Processing: $name"

    pf_doc=$(echo "$desired_pf" | jq -c ". + {site_id: \"$SITE_ID\"}")

    existing=$(ssh "$SSH_USER@$HOST" "mongo --quiet --port 27117 ace --eval '
      JSON.stringify(db.portforward.findOne({name: \"$name\"}, {_id: 1}))
    '" 2>/dev/null || echo "null")

    if [[ "$existing" == "null" ]] || [[ -z "$existing" ]]; then
      echo "  Creating new port forward"
      run_mongo "db.portforward.insertOne($pf_doc)"
    else
      existing_id=$(echo "$existing" | jq -r '._id."$oid"')
      echo "  Updating (id: ${existing_id:0:8}...)"
      update_doc=$(echo "$pf_doc" | jq -c 'del(.name, .site_id)')
      run_mongo "db.portforward.updateOne({_id: ObjectId(\"$existing_id\")}, {\$set: $update_doc})"
    fi
  done
else
  echo "  (none defined)"
fi

echo ""
echo "=== Applying DHCP Reservations ==="

dhcp_count=$(echo "$DESIRED" | jq '.dhcpReservations | length')
if [[ "$dhcp_count" -gt 0 ]]; then
  for res in $(echo "$DESIRED" | jq -r '.dhcpReservations | keys[]'); do
    desired_res=$(echo "$DESIRED" | jq -c ".dhcpReservations[\"$res\"]")
    mac=$(echo "$desired_res" | jq -r '.mac')
    name=$(echo "$desired_res" | jq -r '.name')
    echo "Processing: $name ($mac)"

    # Resolve network reference
    net_name=$(echo "$desired_res" | jq -r '._network_name')
    net_id=$(echo "$NETWORK_MAP" | jq -r ".[\"$net_name\"] // empty")

    if [[ -z "$net_id" ]]; then
      echo "  WARNING: Network '$net_name' not found, skipping"
      continue
    fi

    res_doc=$(echo "$desired_res" | jq -c "
      del(._network_name) |
      .network_id = \"$net_id\" |
      .site_id = \"$SITE_ID\"
    ")

    existing=$(ssh "$SSH_USER@$HOST" "mongo --quiet --port 27117 ace --eval '
      JSON.stringify(db.dhcp_option.findOne({mac: \"$mac\"}, {_id: 1}))
    '" 2>/dev/null || echo "null")

    if [[ "$existing" == "null" ]] || [[ -z "$existing" ]]; then
      echo "  Creating new reservation"
      run_mongo "db.dhcp_option.insertOne($res_doc)"
    else
      existing_id=$(echo "$existing" | jq -r '._id."$oid"')
      echo "  Updating"
      run_mongo "db.dhcp_option.updateOne({_id: ObjectId(\"$existing_id\")}, {\$set: $res_doc})"
    fi
  done
else
  echo "  (none defined)"
fi

# Handle deletions if enabled
if [[ "$ALLOW_DELETES" == "true" ]]; then
  echo ""
  echo "=== Cleaning Up Orphaned Resources ==="

  # Get desired resource names
  desired_networks=$(echo "$DESIRED" | jq -r '.networks | keys[]')
  desired_ssids=$(echo "$DESIRED" | jq -r '.wifi[].name')
  desired_rules=$(echo "$DESIRED" | jq -r '.firewallRules[].description')

  # Delete orphaned networks (except Default which is system-managed)
  echo "Checking networks..."
  current_networks=$(ssh "$SSH_USER@$HOST" 'mongo --quiet --port 27117 ace --eval "
    JSON.stringify(db.networkconf.find({}, {name: 1}).toArray())
  "')

  for net in $(echo "$current_networks" | jq -r '.[].name'); do
    [[ "$net" == "Default" ]] && continue
    if ! echo "$desired_networks" | grep -qxF "$net"; then
      net_id=$(echo "$current_networks" | jq -r ".[] | select(.name == \"$net\") | ._id[\"\\$oid\"] // ._id.str")
      echo "  Deleting network: $net"
      run_mongo "db.networkconf.deleteOne({_id: ObjectId(\"$net_id\")})"
    fi
  done

  # Delete orphaned WiFi networks
  echo "Checking WiFi..."
  current_wifi=$(ssh "$SSH_USER@$HOST" 'mongo --quiet --port 27117 ace --eval "
    JSON.stringify(db.wlanconf.find({}, {name: 1}).toArray())
  "')

  for ssid in $(echo "$current_wifi" | jq -r '.[].name'); do
    if ! echo "$desired_ssids" | grep -qxF "$ssid"; then
      wifi_id=$(echo "$current_wifi" | jq -r ".[] | select(.name == \"$ssid\") | ._id[\"\\$oid\"] // ._id.str")
      echo "  Deleting WiFi: $ssid"
      run_mongo "db.wlanconf.deleteOne({_id: ObjectId(\"$wifi_id\")})"
    fi
  done

  # Delete orphaned firewall rules
  echo "Checking firewall rules..."
  current_rules=$(ssh "$SSH_USER@$HOST" 'mongo --quiet --port 27117 ace --eval "
    JSON.stringify(db.traffic_rule.find({}, {description: 1}).toArray())
  "')

  for desc in $(echo "$current_rules" | jq -r '.[].description // empty'); do
    [[ -z "$desc" ]] && continue
    if ! echo "$desired_rules" | grep -qxF "$desc"; then
      rule_id=$(echo "$current_rules" | jq -r ".[] | select(.description == \"$desc\") | ._id[\"\\$oid\"] // ._id.str")
      echo "  Deleting rule: $desc"
      run_mongo "db.traffic_rule.deleteOne({_id: ObjectId(\"$rule_id\")})"
    fi
  done
fi

echo ""
echo "=== Complete ==="
echo "Changes applied. They should take effect within 30 seconds."
echo "If not, SSH to UDM and run: unifi-os restart"
