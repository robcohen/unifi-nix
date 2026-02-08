#!/usr/bin/env bash
# deploy/utils.sh - Utility functions for unifi-nix deploy
# Source this file from deploy.sh
# shellcheck disable=SC2029  # Variables are intentionally expanded client-side for SSH

# =============================================================================
# MongoDB Helpers
# =============================================================================

# Run MongoDB command on UniFi device
# Usage: run_mongo "db.collection.find({})"
run_mongo() {
  local cmd="$1"
  if [[ ${DRY_RUN:-false} == "true" ]]; then
    echo "[DRY RUN] mongo: ${cmd:0:80}..."
  else
    ssh -o ConnectTimeout=10 "${SSH_USER:-root}@${HOST}" "mongo --quiet --port 27117 ace --eval '$cmd'"
  fi
}

# Fetch JSON from MongoDB
# Usage: fetch_mongo "db.collection.find({})"
fetch_mongo() {
  local cmd="$1"
  ssh "${SSH_USER:-root}@${HOST}" "mongo --quiet --port 27117 ace --eval '$cmd'" 2>/dev/null
}

# =============================================================================
# Secret Resolution
# =============================================================================

# Resolve a secret from file or environment variable
# Usage: resolve_secret "path/to/secret" -> prints resolved value or empty
resolve_secret() {
  local secret_path="$1"
  local resolved=""

  # Try file first
  if [[ -n ${UNIFI_SECRETS_DIR:-} ]] && [[ -f "${UNIFI_SECRETS_DIR}/${secret_path}" ]]; then
    resolved=$(cat "${UNIFI_SECRETS_DIR}/${secret_path}")
  else
    # Fall back to environment variable (path/to/secret -> PATH_TO_SECRET)
    local env_var
    env_var=$(echo "$secret_path" | tr '/' '_' | tr '[:lower:]' '[:upper:]')
    resolved="${!env_var:-}"
  fi

  echo "$resolved"
}

# Resolve secrets in a JSON value (handles both string and {_secret: path} format)
# Usage: resolve_json_secret '{"_secret": "path"}' OR resolve_json_secret '"plaintext"'
resolve_json_secret() {
  local json_value="$1"
  local field_name="${2:-secret}"

  # Check if it's a secret reference object
  if echo "$json_value" | jq -e '._secret' >/dev/null 2>&1; then
    local secret_path
    secret_path=$(echo "$json_value" | jq -r '._secret')
    local resolved
    resolved=$(resolve_secret "$secret_path")

    if [[ -z $resolved ]]; then
      echo "  ERROR: Could not resolve $field_name secret '$secret_path'" >&2
      echo "  Set UNIFI_SECRETS_DIR or environment variable: $(echo "$secret_path" | tr '/' '_' | tr '[:lower:]' '[:upper:]')" >&2
      return 1
    fi

    echo "$resolved"
  else
    # Plain string value
    echo "$json_value" | jq -r '.'
  fi
}

# Resolve x_secret fields in an array of server objects (for RADIUS auth/acct servers)
# Usage: resolve_server_secrets '[{ip, port, x_secret}, ...]' -> resolved array
resolve_server_secrets() {
  local servers_json="$1"
  local server_type="${2:-server}"

  if [[ $(echo "$servers_json" | jq 'length') -eq 0 ]]; then
    echo "[]"
    return
  fi

  local resolved_servers="[]"
  local i=0
  local count
  count=$(echo "$servers_json" | jq 'length')

  while [[ $i -lt $count ]]; do
    local server
    server=$(echo "$servers_json" | jq -c ".[$i]")
    local ip port x_secret_json resolved_secret

    ip=$(echo "$server" | jq -r '.ip')
    port=$(echo "$server" | jq -r '.port')
    x_secret_json=$(echo "$server" | jq -c '.x_secret')

    # Resolve the secret
    if echo "$x_secret_json" | jq -e '._secret' >/dev/null 2>&1; then
      resolved_secret=$(resolve_json_secret "$x_secret_json" "$server_type $ip x_secret") || return 1
    else
      resolved_secret=$(echo "$x_secret_json" | jq -r '.')
    fi

    # Build resolved server object
    local resolved_server
    resolved_server=$(jq -nc --arg ip "$ip" --argjson port "$port" --arg secret "$resolved_secret" \
      '{ip: $ip, port: $port, x_secret: $secret}')

    resolved_servers=$(echo "$resolved_servers" | jq -c ". + [$resolved_server]")
    ((i++))
  done

  echo "$resolved_servers"
}

# =============================================================================
# Network ID Resolution
# =============================================================================

# Resolve network name to ID
# Usage: resolve_network_id "NetworkName"
resolve_network_id() {
  local net_name="$1"
  echo "$NETWORK_MAP" | jq -r ".[\"$net_name\"] // empty"
}

# Resolve array of network names to IDs
# Usage: resolve_network_ids '["Net1", "Net2"]' -> '["id1", "id2"]'
resolve_network_ids() {
  local net_names_json="$1"
  local net_names
  net_names=$(echo "$net_names_json" | jq -r '.[]' 2>/dev/null || true)

  if [[ -z $net_names ]]; then
    echo "[]"
    return
  fi

  local ids=()
  for net_name in $net_names; do
    local net_id
    net_id=$(resolve_network_id "$net_name")
    if [[ -z $net_id ]]; then
      echo "  ERROR: Network '$net_name' not found" >&2
      return 1
    fi
    ids+=("\"$net_id\"")
  done

  if [[ ${#ids[@]} -gt 0 ]]; then
    echo "[$(
      IFS=,
      echo "${ids[*]}"
    )]"
  else
    echo "[]"
  fi
}

# =============================================================================
# Zone Resolution
# =============================================================================

# Resolve zone key to ID
# Usage: resolve_zone_id "internal"
resolve_zone_id() {
  local zone_key="$1"
  echo "$ZONE_MAP" | jq -r ".[\"$zone_key\"] // empty"
}

# =============================================================================
# Display Helpers
# =============================================================================

# Show deploy summary counts
show_deploy_summary() {
  local desired="$1"

  local net_count wifi_count policy_count fwgroup_count apgroup_count
  local usergroup_count traffic_count radius_count portprofile_count
  local dpi_count pf_count dhcp_count sched_count wlangroup_count
  local settings_count alert_count

  net_count=$(echo "$desired" | jq '.networks | length')
  wifi_count=$(echo "$desired" | jq '.wifi | length')
  policy_count=$(echo "$desired" | jq '.firewallPolicies | length')
  fwgroup_count=$(echo "$desired" | jq '.firewallGroups | length')
  apgroup_count=$(echo "$desired" | jq '.apGroups | length')
  usergroup_count=$(echo "$desired" | jq '.userGroups | length')
  traffic_count=$(echo "$desired" | jq '.trafficRules | length')
  radius_count=$(echo "$desired" | jq '.radiusProfiles | length')
  portprofile_count=$(echo "$desired" | jq '.portProfiles | length')
  dpi_count=$(echo "$desired" | jq '.dpiGroups | length')
  pf_count=$(echo "$desired" | jq '.portForwards | length')
  dhcp_count=$(echo "$desired" | jq '.dhcpReservations | length')
  sched_count=$(echo "$desired" | jq '.scheduledTasks | length')
  wlangroup_count=$(echo "$desired" | jq '.wlanGroups | length')
  settings_count=$(echo "$desired" | jq '.globalSettings | length')
  alert_count=$(echo "$desired" | jq '.alertSettings | length')

  echo "  Networks:           $net_count"
  echo "  WiFi:               $wifi_count"
  echo "  Firewall policies:  $policy_count"
  echo "  Firewall groups:    $fwgroup_count"
  echo "  AP groups:          $apgroup_count"
  echo "  User groups:        $usergroup_count"
  echo "  Traffic rules:      $traffic_count"
  echo "  RADIUS profiles:    $radius_count"
  echo "  Port profiles:      $portprofile_count"
  echo "  DPI groups:         $dpi_count"
  echo "  Port forwards:      $pf_count"
  echo "  DHCP reservations:  $dhcp_count"
  echo "  Scheduled tasks:    $sched_count"
  echo "  WLAN groups:        $wlangroup_count"
  echo "  Global settings:    $settings_count"
  echo "  Alert settings:     $alert_count"
}
