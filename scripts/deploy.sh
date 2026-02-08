#!/usr/bin/env bash
# unifi-deploy: Apply UniFi configuration to UDM via SSH+MongoDB
# shellcheck disable=SC2029  # Variables are intentionally expanded client-side for SSH
# shellcheck disable=SC2154  # $oid is a MongoDB field name, not a shell variable
set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

CONFIG_JSON="${1:-}"
HOST="${2:-}"
export HOST

export DRY_RUN="${DRY_RUN:-false}"
export SSH_USER="${SSH_USER:-root}"
export ALLOW_DELETES="${ALLOW_DELETES:-false}"
export SKIP_SCHEMA_CACHE="${SKIP_SCHEMA_CACHE:-false}"
export AUTO_CONFIRM="${AUTO_CONFIRM:-false}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="${UNIFI_BACKUP_DIR:-$HOME/.local/share/unifi-nix/backups}"

# =============================================================================
# Source Libraries
# =============================================================================

# shellcheck source=lib/deploy/utils.sh
source "$SCRIPT_DIR/lib/deploy/utils.sh"
# shellcheck source=lib/deploy/schema.sh
source "$SCRIPT_DIR/lib/deploy/schema.sh"
# shellcheck source=lib/deploy/backup.sh
source "$SCRIPT_DIR/lib/deploy/backup.sh"
# shellcheck source=lib/deploy/resources.sh
source "$SCRIPT_DIR/lib/deploy/resources.sh"
# shellcheck source=lib/deploy/cleanup.sh
source "$SCRIPT_DIR/lib/deploy/cleanup.sh"

# =============================================================================
# Usage
# =============================================================================

show_usage() {
  cat <<EOF
Usage: unifi-deploy <config.json> <host>

Arguments:
  config.json  Path to generated config JSON (from unifi-eval)
  host         UDM IP address or hostname

Environment:
  DRY_RUN=true                  Show commands without executing
  SSH_USER=root                 SSH username (default: root)
  ALLOW_DELETES=true            Delete resources not in config
  UNIFI_SECRETS_DIR=path        Directory containing secret files
  SKIP_SCHEMA_CACHE=true        Skip device schema caching
  SKIP_SCHEMA_VALIDATION=true   Deploy even if schema validation unavailable
  ALLOW_UNSAFE_CREATE=true      Create resources without schema defaults (dangerous!)
  SKIP_BACKUP=true              Skip automatic backup before deploy
  AUTO_CONFIRM=true             Skip confirmation prompt (for CI/automation)
  UNIFI_BACKUP_DIR=path         Custom backup directory

Example:
  unifi-eval ./sites/mysite.nix > config.json
  unifi-deploy config.json 192.168.1.1
EOF
}

# =============================================================================
# Pre-flight Checks
# =============================================================================

# Verify zone-based firewall is enabled if policies are defined
check_zone_firewall() {
  local desired="$1"

  local policy_count
  policy_count=$(echo "$desired" | jq '.firewallPolicies | length')

  if [[ $policy_count -eq 0 ]]; then
    return 0
  fi

  echo ""
  echo "=== Pre-flight Check: Zone-Based Firewall ==="
  echo "  Config contains $policy_count firewall policy(ies)"
  echo "  Checking if zone-based firewall is enabled on UDM..."

  local zone_count
  zone_count=$(fetch_mongo 'db.firewall_zone.count()' || echo "0")

  if [[ $zone_count -eq 0 ]]; then
    echo ""
    echo "ERROR: Zone-based firewall is NOT enabled on the UDM!"
    echo ""
    echo "Your configuration defines firewall policies, but the UDM is still using"
    echo "the legacy firewall system. Deploying would fail or cause undefined behavior."
    echo ""
    echo "To enable zone-based firewall:"
    echo "  1. Open UniFi Network UI: https://$HOST"
    echo "  2. Go to: Settings > Firewall & Security"
    echo "  3. Click 'Upgrade to Zone-Based Firewall'"
    echo "  4. Re-run this deploy command"
    echo ""
    echo "Note: This is a one-way upgrade. After enabling, you cannot revert to"
    echo "the legacy firewall system."
    echo ""
    return 1
  fi

  echo "  Zone-based firewall is enabled ($zone_count zones found)"
  return 0
}

# =============================================================================
# Site Info Fetching
# =============================================================================

fetch_site_info() {
  echo "Fetching site info..."

  local site_info
  site_info=$(fetch_mongo 'JSON.stringify(db.site.findOne({name: "default"}))')
  SITE_ID=$(echo "$site_info" | jq -r '._id."$oid"')
  export SITE_ID
  echo "Site ID: $SITE_ID"

  # Get default usergroup_id for WiFi networks
  USERGROUP_ID=$(fetch_mongo "var g = db.usergroup.findOne({site_id: \"$SITE_ID\"}); print(g ? g._id.str : \"\")")
  export USERGROUP_ID
  echo "UserGroup ID: ${USERGROUP_ID:-none}"

  # Build network name -> id mapping
  echo "Building network mappings..."
  NETWORK_MAP=$(fetch_mongo 'JSON.stringify(db.networkconf.find({}, {name: 1}).toArray().reduce(function(m, n) {
    m[n.name] = n._id.str || n._id.toString();
    return m;
  }, {}))')
  export NETWORK_MAP
}

# Refresh network mapping (after creating networks)
refresh_network_map() {
  if [[ $DRY_RUN == "true" ]]; then
    return 0
  fi

  NETWORK_MAP=$(fetch_mongo 'JSON.stringify(db.networkconf.find({}, {name: 1}).toArray().reduce(function(m, n) {
    m[n.name] = n._id.str || n._id.toString();
    return m;
  }, {}))')
  export NETWORK_MAP
}

# =============================================================================
# VPN Deployment (special handling)
# =============================================================================

deploy_vpn() {
  local desired="$1"
  local site_id="$2"

  echo ""
  echo "=== Applying VPN Configuration ==="

  # WireGuard Server
  local wg_enabled
  wg_enabled=$(echo "$desired" | jq -r '.vpn.wireguard.server.wg_enabled // false')

  if [[ $wg_enabled == "true" ]]; then
    echo "Configuring WireGuard server..."
    local wg_config
    wg_config=$(echo "$desired" | jq -c ".vpn.wireguard.server + {site_id: \"$site_id\"} | del(.key)")

    local existing_wg
    existing_wg=$(fetch_mongo 'JSON.stringify(db.setting.findOne({key: "wireguard_server"}, {_id: 1}))' || echo "null")

    if [[ $existing_wg == "null" ]] || [[ -z $existing_wg ]]; then
      echo "  Creating WireGuard server setting"
      run_mongo "db.setting.insertOne({key: \"wireguard_server\", $wg_config})"
    else
      local existing_id
      existing_id=$(echo "$existing_wg" | jq -r '._id."$oid"')
      echo "  Updating WireGuard server (id: ${existing_id:0:8}...)"
      run_mongo "db.setting.updateOne({key: \"wireguard_server\"}, {\$set: $wg_config})"
    fi

    # WireGuard Peers
    local peer_count
    peer_count=$(echo "$desired" | jq '.vpn.wireguard.peers | length')
    if [[ $peer_count -gt 0 ]]; then
      echo "  Configuring $peer_count WireGuard peer(s)..."
      for peer in $(echo "$desired" | jq -r '.vpn.wireguard.peers | keys[]'); do
        local peer_config peer_name
        peer_config=$(echo "$desired" | jq -c ".vpn.wireguard.peers[\"$peer\"]")
        peer_name=$(echo "$peer_config" | jq -r '.name')
        echo "    Processing peer: $peer_name"
      done
    fi
  else
    echo "  WireGuard server not enabled"
  fi

  # Site-to-Site VPN
  local s2s_count
  s2s_count=$(echo "$desired" | jq '.vpn.siteToSite | length')

  if [[ $s2s_count -gt 0 ]]; then
    echo "Configuring $s2s_count site-to-site VPN tunnel(s)..."
    for tunnel in $(echo "$desired" | jq -r '.vpn.siteToSite | keys[]'); do
      local tunnel_config tunnel_name tunnel_type
      tunnel_config=$(echo "$desired" | jq -c ".vpn.siteToSite[\"$tunnel\"]")
      tunnel_name=$(echo "$tunnel_config" | jq -r '.name')
      tunnel_type=$(echo "$tunnel_config" | jq -r '.vpn_type')
      echo "  Processing: $tunnel_name ($tunnel_type)"

      # Resolve PSK secret if needed
      local psk_json
      psk_json=$(echo "$tunnel_config" | jq -c '.x_psk // null')
      if [[ $psk_json != "null" ]]; then
        local psk
        psk=$(resolve_json_secret "$psk_json" "VPN PSK") || {
          echo "    Skipping tunnel due to secret resolution failure"
          continue
        }
        tunnel_config=$(echo "$tunnel_config" | jq -c --arg psk "$psk" '.x_psk = $psk')
      fi

      echo "    Note: Site-to-site VPN requires manual configuration in UniFi UI"
      echo "    Config prepared: $tunnel_name -> $(echo "$tunnel_config" | jq -r '.remote_host')"
    done
  else
    echo "  No site-to-site VPN tunnels defined"
  fi
}

# =============================================================================
# DPI Groups Deployment (special handling)
# =============================================================================

deploy_dpi_groups() {
  local desired="$1"
  local site_id="$2"

  echo ""
  echo "=== Applying DPI Groups ==="

  local count
  count=$(echo "$desired" | jq '.dpiGroups | length')

  if [[ $count -eq 0 ]]; then
    echo "  (none defined)"
    return 0
  fi

  # Build category->app_ids mapping
  echo "Building DPI category mappings..."
  local dpi_category_map
  dpi_category_map=$(fetch_mongo 'var apps = db.dpiapp.find({}, {_id: 1, cat: 1}).toArray();
    var catMap = {};
    apps.forEach(function(a) {
      var cat = a.cat || "Unknown";
      if (!catMap[cat]) catMap[cat] = [];
      catMap[cat].push(a._id.str || a._id.toString());
    });
    print(JSON.stringify(catMap));' || echo "{}")

  for dpi in $(echo "$desired" | jq -r '.dpiGroups | keys[]'); do
    local desired_dpi name
    desired_dpi=$(echo "$desired" | jq -c ".dpiGroups[\"$dpi\"]")
    name=$(echo "$desired_dpi" | jq -r '.name')
    echo "Processing: $name"

    # Get directly specified app IDs
    local app_ids
    app_ids=$(echo "$desired_dpi" | jq -c '.dpiapp_ids // []')

    # Resolve categories to app IDs
    local categories
    categories=$(echo "$desired_dpi" | jq -r '._categories // [] | .[]')
    if [[ -n $categories ]]; then
      for cat in $categories; do
        local cat_app_ids
        cat_app_ids=$(echo "$dpi_category_map" | jq -c ".\"$cat\" // []")
        if [[ $cat_app_ids != "[]" ]]; then
          app_ids=$(echo "[$app_ids, $cat_app_ids]" | jq -c 'flatten | unique')
          echo "  Category '$cat': $(echo "$cat_app_ids" | jq 'length') apps"
        else
          echo "  WARNING: Category '$cat' not found or empty"
        fi
      done
    fi

    local dpi_doc
    dpi_doc=$(echo "$desired_dpi" | jq -c "
      del(._categories) |
      .dpiapp_ids = $app_ids |
      .site_id = \"$site_id\"
    ")

    local existing
    existing=$(fetch_mongo "JSON.stringify(db.dpigroup.findOne({name: \"$name\"}, {_id: 1}))" || echo "null")

    if [[ $existing == "null" ]] || [[ -z $existing ]]; then
      echo "  Creating new DPI group"
      run_mongo "db.dpigroup.insertOne($dpi_doc)"
    else
      local existing_id
      existing_id=$(echo "$existing" | jq -r '._id."$oid"')
      echo "  Updating (id: ${existing_id:0:8}...)"
      local update_doc
      update_doc=$(echo "$dpi_doc" | jq -c 'del(.name, .site_id)')
      run_mongo "db.dpigroup.updateOne({_id: ObjectId(\"$existing_id\")}, {\$set: $update_doc})"
    fi
  done
}

# =============================================================================
# Main
# =============================================================================

main() {
  # Validate arguments
  if [[ -z $CONFIG_JSON ]] || [[ -z $HOST ]]; then
    show_usage
    exit 1
  fi

  if [[ ! -f $CONFIG_JSON ]]; then
    echo "Error: Config file not found: $CONFIG_JSON"
    exit 1
  fi

  echo "=== UniFi Declarative Deploy ==="
  echo "Host: $HOST"
  [[ $DRY_RUN == "true" ]] && echo "Mode: DRY RUN"
  echo ""

  # Setup schemas and load defaults
  setup_device_schemas "$HOST" "$SSH_USER" "$SCRIPT_DIR" || exit 1
  load_schema_defaults

  # Validate configuration
  validate_configuration "$CONFIG_JSON" "$SCRIPT_DIR" || exit 1

  # Load desired config
  local desired
  desired=$(cat "$CONFIG_JSON")

  # Create backup
  create_pre_deploy_backup "$HOST" "$SSH_USER" "$BACKUP_DIR" "${DEVICE_VERSION:-unknown}"

  # Confirm deployment
  confirm_deployment "$desired" || exit 0

  # Fetch site info and mappings
  fetch_site_info

  # Pre-flight: check zone-based firewall
  check_zone_firewall "$desired" || exit 1

  # Deploy resources in order
  deploy_networks "$desired" "$SITE_ID" || exit 1
  refresh_network_map

  deploy_wifi "$desired" "$SITE_ID" "$USERGROUP_ID" || exit 1

  echo ""
  echo "=== Firewall Rules (Legacy) ==="
  echo "  (skipped - use firewall.policies instead)"

  deploy_firewall_policies "$desired" "$SITE_ID" || exit 1

  deploy_simple_resource "firewallGroups" "firewallgroup" "name" "$desired" "$SITE_ID"
  deploy_simple_resource "apGroups" "apgroup" "name" "$desired" "$SITE_ID"
  deploy_simple_resource "userGroups" "usergroup" "name" "$desired" "$SITE_ID"

  deploy_traffic_rules "$desired" "$SITE_ID" || exit 1
  deploy_radius_profiles "$desired" "$SITE_ID" || exit 1
  deploy_port_profiles "$desired" "$SITE_ID" || exit 1
  deploy_vpn "$desired" "$SITE_ID"
  deploy_dpi_groups "$desired" "$SITE_ID"
  deploy_port_forwards "$desired" "$SITE_ID" || exit 1
  deploy_dhcp_reservations "$desired" "$SITE_ID" || exit 1

  # Schema-generated collections
  deploy_simple_resource "scheduledTasks" "scheduletask" "name" "$desired" "$SITE_ID"
  deploy_simple_resource "wlanGroups" "wlangroup" "name" "$desired" "$SITE_ID"
  deploy_simple_resource "alertSettings" "alert_setting" "key" "$desired" "$SITE_ID"
  deploy_simple_resource "firewallZones" "firewall_zone" "name" "$desired" "$SITE_ID"
  deploy_simple_resource "dohServers" "doh_servers" "name" "$desired" "$SITE_ID"
  deploy_simple_resource "sslInspectionProfiles" "ssl_inspection_profile" "name" "$desired" "$SITE_ID"
  deploy_simple_resource "dashboards" "dashboard" "name" "$desired" "$SITE_ID"
  deploy_simple_resource "diagnosticsConfig" "diagnostics_config" "key" "$desired" "$SITE_ID"

  deploy_global_settings "$desired" "$SITE_ID"

  # Cleanup orphaned resources
  cleanup_orphaned_resources "$desired"

  echo ""
  echo "=== Complete ==="
  echo "Changes applied. They should take effect within 30 seconds."
  echo "If not, SSH to UDM and run: unifi-os restart"
}

main "$@"
