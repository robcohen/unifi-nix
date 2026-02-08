#!/usr/bin/env bash
# deploy/cleanup.sh - Orphaned resource cleanup for unifi-nix
# Source this file from deploy.sh
# shellcheck disable=SC2154  # $oid is a MongoDB field name, not a shell variable

# =============================================================================
# Orphaned Resource Cleanup
# =============================================================================

# Clean up resources not in desired config (when ALLOW_DELETES=true)
cleanup_orphaned_resources() {
  local desired="$1"

  if [[ ${ALLOW_DELETES:-false} != "true" ]]; then
    return 0
  fi

  echo ""
  echo "=== Cleaning Up Orphaned Resources ==="

  cleanup_orphaned_networks "$desired"
  cleanup_orphaned_wifi "$desired"
  cleanup_orphaned_firewall_policies "$desired"
}

# Clean up orphaned networks
cleanup_orphaned_networks() {
  local desired="$1"

  echo "Checking networks..."
  local desired_networks
  desired_networks=$(echo "$desired" | jq -r '.networks | keys[]')

  local current_networks
  current_networks=$(fetch_mongo 'JSON.stringify(db.networkconf.find({}, {name: 1}).toArray())')

  for net in $(echo "$current_networks" | jq -r '.[].name'); do
    # Skip Default network (system-managed)
    [[ $net == "Default" ]] && continue

    if ! echo "$desired_networks" | grep -qxF "$net"; then
      local net_id
      net_id=$(echo "$current_networks" | jq -r ".[] | select(.name == \"$net\") | ._id[\"\\$oid\"] // ._id.str")
      echo "  Deleting network: $net"
      run_mongo "db.networkconf.deleteOne({_id: ObjectId(\"$net_id\")})"
    fi
  done
}

# Clean up orphaned WiFi networks
cleanup_orphaned_wifi() {
  local desired="$1"

  echo "Checking WiFi..."
  local desired_ssids
  desired_ssids=$(echo "$desired" | jq -r '.wifi[].name')

  local current_wifi
  current_wifi=$(fetch_mongo 'JSON.stringify(db.wlanconf.find({}, {name: 1}).toArray())')

  for ssid in $(echo "$current_wifi" | jq -r '.[].name'); do
    if ! echo "$desired_ssids" | grep -qxF "$ssid"; then
      local wifi_id
      wifi_id=$(echo "$current_wifi" | jq -r ".[] | select(.name == \"$ssid\") | ._id[\"\\$oid\"] // ._id.str")
      echo "  Deleting WiFi: $ssid"
      run_mongo "db.wlanconf.deleteOne({_id: ObjectId(\"$wifi_id\")})"
    fi
  done
}

# Clean up orphaned firewall policies
cleanup_orphaned_firewall_policies() {
  local desired="$1"

  echo "Checking firewall policies..."
  local desired_policies
  desired_policies=$(echo "$desired" | jq -r '.firewallPolicies | keys[]' 2>/dev/null || true)

  if [[ -z $desired_policies ]]; then
    return 0
  fi

  local current_policies
  current_policies=$(fetch_mongo 'JSON.stringify(db.firewall_policy.find({}, {name: 1}).toArray())' || echo "[]")

  for policy_name in $(echo "$current_policies" | jq -r '.[].name'); do
    if ! echo "$desired_policies" | grep -qxF "$policy_name"; then
      # Only delete user-created policies (index < 30000)
      local policy_index
      policy_index=$(fetch_mongo "var p = db.firewall_policy.findOne({name: \"$policy_name\"}); print(p ? p.index : 0);" || echo "0")

      if [[ $policy_index -lt 30000 ]]; then
        local policy_id
        policy_id=$(echo "$current_policies" | jq -r ".[] | select(.name == \"$policy_name\") | ._id[\"\\$oid\"] // ._id.str")
        echo "  Deleting firewall policy: $policy_name"
        run_mongo "db.firewall_policy.deleteOne({_id: ObjectId(\"$policy_id\")})"
      fi
    fi
  done
}
