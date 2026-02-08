#!/usr/bin/env bash
# deploy/resources.sh - Resource deployment functions for unifi-nix
# Source this file from deploy.sh

# =============================================================================
# Generic Resource Deployment
# =============================================================================

# Deploy a simple resource (no special handling needed)
# Args: collection_name, mongo_collection, id_field, desired_json, site_id
deploy_simple_resource() {
  local collection_name="$1"  # e.g., "firewallGroups"
  local mongo_collection="$2" # e.g., "firewallgroup"
  local id_field="${3:-name}" # Field to match on
  local desired="$4"
  local site_id="$5"

  echo ""
  echo "=== Applying ${collection_name} ==="

  local count
  count=$(echo "$desired" | jq ".${collection_name} | length")

  if [[ $count -eq 0 ]]; then
    echo "  (none defined)"
    return 0
  fi

  for item_key in $(echo "$desired" | jq -r ".${collection_name} | keys[]"); do
    local item_doc
    item_doc=$(echo "$desired" | jq -c ".${collection_name}[\"$item_key\"]")

    local id_value
    id_value=$(echo "$item_doc" | jq -r ".${id_field} // \"$item_key\"")
    echo "Processing: $id_value"

    # Add site_id
    item_doc=$(echo "$item_doc" | jq -c ".site_id = \"$site_id\"")

    # Check if exists
    local existing
    existing=$(fetch_mongo "JSON.stringify(db.${mongo_collection}.findOne({${id_field}: \"$id_value\"}, {_id: 1}))" || echo "null")

    if [[ $existing == "null" ]] || [[ -z $existing ]]; then
      echo "  Creating new ${mongo_collection}"
      run_mongo "db.${mongo_collection}.insertOne($item_doc)"
    else
      local existing_id
      existing_id=$(echo "$existing" | jq -r '._id."$oid"')
      echo "  Updating (id: ${existing_id:0:8}...)"
      local update_doc
      update_doc=$(echo "$item_doc" | jq -c "del(.${id_field}, .site_id)")
      run_mongo "db.${mongo_collection}.updateOne({_id: ObjectId(\"$existing_id\")}, {\$set: $update_doc})"
    fi
  done
}

# =============================================================================
# Network Deployment
# =============================================================================

deploy_networks() {
  local desired="$1"
  local site_id="$2"

  echo ""
  echo "=== Applying Networks ==="

  for net in $(echo "$desired" | jq -r '.networks | keys[]'); do
    echo "Processing: $net"
    local desired_net
    desired_net=$(echo "$desired" | jq -c ".networks[\"$net\"]")

    local existing_id
    existing_id=$(echo "$NETWORK_MAP" | jq -r ".[\"$net\"] // empty")

    if [[ -z $existing_id ]]; then
      if [[ ${HAVE_SCHEMA_DEFAULTS:-false} != "true" ]] && [[ ${ALLOW_UNSAFE_CREATE:-false} != "true" ]]; then
        echo "  ERROR: Cannot create new network without schema defaults (safety check)"
        echo "         Set ALLOW_UNSAFE_CREATE=true to override (not recommended)"
        return 1
      fi
      echo "  Creating new network"
      local insert_doc
      insert_doc=$(echo "$NETWORK_DEFAULTS" | jq -c ". * $desired_net + {site_id: \"$site_id\"}")
      run_mongo "db.networkconf.insertOne($insert_doc)"
    else
      echo "  Updating (id: ${existing_id:0:8}...)"
      local update_doc
      update_doc=$(echo "$desired_net" | jq -c 'del(.name)')
      run_mongo "db.networkconf.updateOne({_id: ObjectId(\"$existing_id\")}, {\$set: $update_doc})"
    fi
  done
}

# =============================================================================
# WiFi Deployment
# =============================================================================

deploy_wifi() {
  local desired="$1"
  local site_id="$2"
  local usergroup_id="$3"

  echo ""
  echo "=== Applying WiFi ==="

  for wifi in $(echo "$desired" | jq -r '.wifi | keys[]'); do
    local desired_wifi
    desired_wifi=$(echo "$desired" | jq -c ".wifi[\"$wifi\"]")

    local ssid
    ssid=$(echo "$desired_wifi" | jq -r '.name')
    echo "Processing: $ssid"

    # Resolve network reference
    local net_name net_id
    net_name=$(echo "$desired_wifi" | jq -r '._network_name')
    net_id=$(resolve_network_id "$net_name")

    if [[ -z $net_id ]]; then
      echo "  WARNING: Network '$net_name' not found, skipping"
      continue
    fi

    # Resolve passphrase
    local passphrase_json passphrase
    passphrase_json=$(echo "$desired_wifi" | jq -c '.x_passphrase')
    passphrase=$(resolve_json_secret "$passphrase_json" "WiFi passphrase") || {
      echo "  Skipping WiFi network due to secret resolution failure"
      continue
    }

    local wifi_doc
    wifi_doc=$(echo "$desired_wifi" | jq -c "
      del(._network_name) |
      .networkconf_id = \"$net_id\" |
      .x_passphrase = \"$passphrase\" |
      .site_id = \"$site_id\"
    ")

    local existing
    existing=$(fetch_mongo "JSON.stringify(db.wlanconf.findOne({name: \"$ssid\"}, {_id: 1}))" || echo "null")

    if [[ $existing == "null" ]] || [[ -z $existing ]]; then
      if [[ ${HAVE_SCHEMA_DEFAULTS:-false} != "true" ]] && [[ ${ALLOW_UNSAFE_CREATE:-false} != "true" ]]; then
        echo "  ERROR: Cannot create new WiFi without schema defaults (safety check)"
        return 1
      fi
      echo "  Creating new WiFi"
      wifi_doc=$(echo "$WIFI_DEFAULTS" | jq -c ". * $wifi_doc + {usergroup_id: \"$usergroup_id\"}")
      run_mongo "db.wlanconf.insertOne($wifi_doc)"
    else
      local existing_id
      existing_id=$(echo "$existing" | jq -r '._id."$oid"')
      echo "  Updating (id: ${existing_id:0:8}...)"
      local update_doc
      update_doc=$(echo "$wifi_doc" | jq -c 'del(.name, .site_id)')
      run_mongo "db.wlanconf.updateOne({_id: ObjectId(\"$existing_id\")}, {\$set: $update_doc})"
    fi
  done
}

# =============================================================================
# Firewall Policy Deployment
# =============================================================================

deploy_firewall_policies() {
  local desired="$1"
  local site_id="$2"

  echo ""
  echo "=== Applying Firewall Policies ==="

  local policy_count
  policy_count=$(echo "$desired" | jq '.firewallPolicies | length')

  if [[ $policy_count -eq 0 ]]; then
    echo "  (none defined)"
    return 0
  fi

  # Build zone mapping
  echo "Building zone mappings..."
  ZONE_MAP=$(fetch_mongo 'JSON.stringify(db.firewall_zone.find({}, {zone_key: 1}).toArray().reduce(function(m, z) {
    m[z.zone_key] = z._id.str || z._id.toString();
    return m;
  }, {}))')
  export ZONE_MAP

  echo "  Found zones: $(echo "$ZONE_MAP" | jq -r 'keys | join(", ")')"

  for policy in $(echo "$desired" | jq -r '.firewallPolicies | keys[]'); do
    local desired_policy name
    desired_policy=$(echo "$desired" | jq -c ".firewallPolicies[\"$policy\"]")
    name=$(echo "$desired_policy" | jq -r '.name')
    echo "Processing: $name"

    # Resolve zones
    local src_zone_key src_zone_id dst_zone_key dst_zone_id
    src_zone_key=$(echo "$desired_policy" | jq -r '.source._zone_key')
    src_zone_id=$(resolve_zone_id "$src_zone_key")
    if [[ -z $src_zone_id ]]; then
      echo "  ERROR: Source zone '$src_zone_key' not found"
      return 1
    fi

    dst_zone_key=$(echo "$desired_policy" | jq -r '.destination._zone_key')
    dst_zone_id=$(resolve_zone_id "$dst_zone_key")
    if [[ -z $dst_zone_id ]]; then
      echo "  ERROR: Destination zone '$dst_zone_key' not found"
      return 1
    fi

    # Resolve network IDs
    local src_network_ids dst_network_ids
    src_network_ids=$(resolve_network_ids "$(echo "$desired_policy" | jq -c '.source._network_names // []')") || return 1
    dst_network_ids=$(resolve_network_ids "$(echo "$desired_policy" | jq -c '.destination._network_names // []')") || return 1

    # Build policy document
    local src_ips dst_ips policy_doc
    src_ips=$(echo "$desired_policy" | jq -c '.source._ips // []')
    dst_ips=$(echo "$desired_policy" | jq -c '.destination._ips // []')

    policy_doc=$(echo "$desired_policy" | jq -c "
      .site_id = \"$site_id\" |
      .source.zone_id = \"$src_zone_id\" |
      .source.network_ids = $src_network_ids |
      .source.ips = $src_ips |
      del(.source._zone_key, .source._network_names, .source._ips) |
      .destination.zone_id = \"$dst_zone_id\" |
      .destination.network_ids = $dst_network_ids |
      .destination.ips = $dst_ips |
      del(.destination._zone_key, .destination._network_names, .destination._ips)
    ")

    local existing
    existing=$(fetch_mongo "JSON.stringify(db.firewall_policy.findOne({name: \"$name\"}, {_id: 1}))" || echo "null")

    if [[ $existing == "null" ]] || [[ -z $existing ]]; then
      echo "  Creating new firewall policy"
      if [[ -n ${FIREWALL_POLICY_DEFAULTS:-} ]] && [[ $FIREWALL_POLICY_DEFAULTS != "{}" ]]; then
        policy_doc=$(echo "$FIREWALL_POLICY_DEFAULTS" | jq -c ". * $policy_doc")
      fi
      run_mongo "db.firewall_policy.insertOne($policy_doc)"
    else
      local existing_id
      existing_id=$(echo "$existing" | jq -r '._id."$oid"')
      echo "  Updating (id: ${existing_id:0:8}...)"
      local update_doc
      update_doc=$(echo "$policy_doc" | jq -c 'del(.name, .site_id)')
      run_mongo "db.firewall_policy.updateOne({_id: ObjectId(\"$existing_id\")}, {\$set: $update_doc})"
    fi
  done
}

# =============================================================================
# Traffic Rules Deployment
# =============================================================================

deploy_traffic_rules() {
  local desired="$1"
  local site_id="$2"

  echo ""
  echo "=== Applying Traffic Rules ==="

  local count
  count=$(echo "$desired" | jq '.trafficRules | length')

  if [[ $count -eq 0 ]]; then
    echo "  (none defined)"
    return 0
  fi

  for tr in $(echo "$desired" | jq -r '.trafficRules | keys[]'); do
    local desired_tr name
    desired_tr=$(echo "$desired" | jq -c ".trafficRules[\"$tr\"]")
    name=$(echo "$desired_tr" | jq -r '.name')
    echo "Processing: $name"

    # Resolve network reference if specified
    local net_name net_id
    net_name=$(echo "$desired_tr" | jq -r '._network_name // empty')
    net_id=""
    if [[ -n $net_name ]] && [[ $net_name != "null" ]]; then
      net_id=$(resolve_network_id "$net_name")
      if [[ -z $net_id ]]; then
        echo "  WARNING: Network '$net_name' not found"
      fi
    fi

    local tr_doc
    tr_doc=$(echo "$desired_tr" | jq -c "
      del(._network_name) |
      .network_id = (if \"$net_id\" != \"\" then \"$net_id\" else null end) |
      .site_id = \"$site_id\"
    ")

    local existing
    existing=$(fetch_mongo "JSON.stringify(db.traffic_rule.findOne({name: \"$name\"}, {_id: 1}))" || echo "null")

    if [[ $existing == "null" ]] || [[ -z $existing ]]; then
      echo "  Creating new traffic rule"
      run_mongo "db.traffic_rule.insertOne($tr_doc)"
    else
      local existing_id
      existing_id=$(echo "$existing" | jq -r '._id."$oid"')
      echo "  Updating (id: ${existing_id:0:8}...)"
      local update_doc
      update_doc=$(echo "$tr_doc" | jq -c 'del(.name, .site_id)')
      run_mongo "db.traffic_rule.updateOne({_id: ObjectId(\"$existing_id\")}, {\$set: $update_doc})"
    fi
  done
}

# =============================================================================
# RADIUS Profile Deployment
# =============================================================================

deploy_radius_profiles() {
  local desired="$1"
  local site_id="$2"

  echo ""
  echo "=== Applying RADIUS Profiles ==="

  local count
  count=$(echo "$desired" | jq '.radiusProfiles | length')

  if [[ $count -eq 0 ]]; then
    echo "  (none defined)"
    return 0
  fi

  for rp in $(echo "$desired" | jq -r '.radiusProfiles | keys[]'); do
    local desired_rp name
    desired_rp=$(echo "$desired" | jq -c ".radiusProfiles[\"$rp\"]")
    name=$(echo "$desired_rp" | jq -r '.name')
    echo "Processing: $name"

    # Resolve secrets in servers
    local auth_servers resolved_auth
    auth_servers=$(echo "$desired_rp" | jq -c '.auth_servers // []')
    resolved_auth=$(resolve_server_secrets "$auth_servers" "RADIUS auth") || {
      echo "  Skipping profile due to secret resolution failure"
      continue
    }

    local acct_servers resolved_acct
    acct_servers=$(echo "$desired_rp" | jq -c '.acct_servers // []')
    resolved_acct=$(resolve_server_secrets "$acct_servers" "RADIUS acct") || {
      echo "  Skipping profile due to secret resolution failure"
      continue
    }

    local rp_doc
    rp_doc=$(echo "$desired_rp" | jq -c "
      .auth_servers = $resolved_auth |
      .acct_servers = $resolved_acct |
      .site_id = \"$site_id\"
    ")

    local existing
    existing=$(fetch_mongo "JSON.stringify(db.radiusprofile.findOne({name: \"$name\"}, {_id: 1}))" || echo "null")

    if [[ $existing == "null" ]] || [[ -z $existing ]]; then
      echo "  Creating new RADIUS profile"
      run_mongo "db.radiusprofile.insertOne($rp_doc)"
    else
      local existing_id
      existing_id=$(echo "$existing" | jq -r '._id."$oid"')
      echo "  Updating (id: ${existing_id:0:8}...)"
      local update_doc
      update_doc=$(echo "$rp_doc" | jq -c 'del(.name, .site_id)')
      run_mongo "db.radiusprofile.updateOne({_id: ObjectId(\"$existing_id\")}, {\$set: $update_doc})"
    fi
  done
}

# =============================================================================
# Port Profile Deployment
# =============================================================================

deploy_port_profiles() {
  local desired="$1"
  local site_id="$2"

  echo ""
  echo "=== Applying Port Profiles ==="

  local count
  count=$(echo "$desired" | jq '.portProfiles | length')

  if [[ $count -eq 0 ]]; then
    echo "  (none defined)"
    return 0
  fi

  for pp in $(echo "$desired" | jq -r '.portProfiles | keys[]'); do
    local desired_pp name
    desired_pp=$(echo "$desired" | jq -c ".portProfiles[\"$pp\"]")
    name=$(echo "$desired_pp" | jq -r '.name')
    echo "Processing: $name"

    # Resolve native network
    local native_net_name native_net_id
    native_net_name=$(echo "$desired_pp" | jq -r '._native_network_name // empty')
    native_net_id=""
    if [[ -n $native_net_name ]] && [[ $native_net_name != "null" ]]; then
      native_net_id=$(resolve_network_id "$native_net_name")
      if [[ -z $native_net_id ]]; then
        echo "  WARNING: Native network '$native_net_name' not found"
      fi
    fi

    # Resolve tagged networks
    local tagged_net_ids
    tagged_net_ids=$(resolve_network_ids "$(echo "$desired_pp" | jq -c '._tagged_network_names // []')") || tagged_net_ids="[]"

    local pp_doc
    pp_doc=$(echo "$desired_pp" | jq -c "
      del(._native_network_name, ._tagged_network_names) |
      .native_networkconf_id = (if \"$native_net_id\" != \"\" then \"$native_net_id\" else null end) |
      .tagged_networkconf_ids = $tagged_net_ids |
      .site_id = \"$site_id\"
    ")

    local existing
    existing=$(fetch_mongo "JSON.stringify(db.portconf.findOne({name: \"$name\"}, {_id: 1}))" || echo "null")

    if [[ $existing == "null" ]] || [[ -z $existing ]]; then
      echo "  Creating new port profile"
      run_mongo "db.portconf.insertOne($pp_doc)"
    else
      local existing_id
      existing_id=$(echo "$existing" | jq -r '._id."$oid"')
      echo "  Updating (id: ${existing_id:0:8}...)"
      local update_doc
      update_doc=$(echo "$pp_doc" | jq -c 'del(.name, .site_id)')
      run_mongo "db.portconf.updateOne({_id: ObjectId(\"$existing_id\")}, {\$set: $update_doc})"
    fi
  done
}

# =============================================================================
# Port Forward Deployment
# =============================================================================

deploy_port_forwards() {
  local desired="$1"
  local site_id="$2"

  echo ""
  echo "=== Applying Port Forwards ==="

  local count
  count=$(echo "$desired" | jq '.portForwards | length')

  if [[ $count -eq 0 ]]; then
    echo "  (none defined)"
    return 0
  fi

  for pf in $(echo "$desired" | jq -r '.portForwards | keys[]'); do
    local desired_pf name
    desired_pf=$(echo "$desired" | jq -c ".portForwards[\"$pf\"]")
    name=$(echo "$desired_pf" | jq -r '.name')
    echo "Processing: $name"

    local pf_doc
    pf_doc=$(echo "$desired_pf" | jq -c ". + {site_id: \"$site_id\"}")

    local existing
    existing=$(fetch_mongo "JSON.stringify(db.portforward.findOne({name: \"$name\"}, {_id: 1}))" || echo "null")

    if [[ $existing == "null" ]] || [[ -z $existing ]]; then
      if [[ ${HAVE_SCHEMA_DEFAULTS:-false} != "true" ]] && [[ ${ALLOW_UNSAFE_CREATE:-false} != "true" ]]; then
        echo "  ERROR: Cannot create new port forward without schema defaults (safety check)"
        return 1
      fi
      echo "  Creating new port forward"
      pf_doc=$(echo "$PORTFWD_DEFAULTS" | jq -c ". * $pf_doc")
      run_mongo "db.portforward.insertOne($pf_doc)"
    else
      local existing_id
      existing_id=$(echo "$existing" | jq -r '._id."$oid"')
      echo "  Updating (id: ${existing_id:0:8}...)"
      local update_doc
      update_doc=$(echo "$pf_doc" | jq -c 'del(.name, .site_id)')
      run_mongo "db.portforward.updateOne({_id: ObjectId(\"$existing_id\")}, {\$set: $update_doc})"
    fi
  done
}

# =============================================================================
# DHCP Reservation Deployment
# =============================================================================

deploy_dhcp_reservations() {
  local desired="$1"
  local site_id="$2"

  echo ""
  echo "=== Applying DHCP Reservations ==="

  local count
  count=$(echo "$desired" | jq '.dhcpReservations | length')

  if [[ $count -eq 0 ]]; then
    echo "  (none defined)"
    return 0
  fi

  for res in $(echo "$desired" | jq -r '.dhcpReservations | keys[]'); do
    local desired_res mac name
    desired_res=$(echo "$desired" | jq -c ".dhcpReservations[\"$res\"]")
    mac=$(echo "$desired_res" | jq -r '.mac')
    name=$(echo "$desired_res" | jq -r '.name')
    echo "Processing: $name ($mac)"

    # Resolve network reference
    local net_name net_id
    net_name=$(echo "$desired_res" | jq -r '._network_name')
    net_id=$(resolve_network_id "$net_name")

    if [[ -z $net_id ]]; then
      echo "  WARNING: Network '$net_name' not found, skipping"
      continue
    fi

    local res_doc
    res_doc=$(echo "$desired_res" | jq -c "
      del(._network_name) |
      .network_id = \"$net_id\" |
      .site_id = \"$site_id\"
    ")

    local existing
    existing=$(fetch_mongo "JSON.stringify(db.dhcp_option.findOne({mac: \"$mac\"}, {_id: 1}))" || echo "null")

    if [[ $existing == "null" ]] || [[ -z $existing ]]; then
      if [[ ${HAVE_SCHEMA_DEFAULTS:-false} != "true" ]] && [[ ${ALLOW_UNSAFE_CREATE:-false} != "true" ]]; then
        echo "  ERROR: Cannot create new DHCP reservation without schema defaults (safety check)"
        return 1
      fi
      echo "  Creating new reservation"
      res_doc=$(echo "$DHCP_DEFAULTS" | jq -c ". * $res_doc")
      run_mongo "db.dhcp_option.insertOne($res_doc)"
    else
      local existing_id
      existing_id=$(echo "$existing" | jq -r '._id."$oid"')
      echo "  Updating"
      run_mongo "db.dhcp_option.updateOne({_id: ObjectId(\"$existing_id\")}, {\$set: $res_doc})"
    fi
  done
}

# =============================================================================
# Global Settings Deployment
# =============================================================================

deploy_global_settings() {
  local desired="$1"
  local site_id="$2"

  echo ""
  echo "=== Applying Global Settings ==="

  local count
  count=$(echo "$desired" | jq '.globalSettings | length')

  if [[ $count -eq 0 ]]; then
    echo "  (none defined)"
    return 0
  fi

  for setting_key in $(echo "$desired" | jq -r '.globalSettings | keys[]'); do
    local setting_doc setting_name
    setting_doc=$(echo "$desired" | jq -c ".globalSettings[\"$setting_key\"]")
    setting_name=$(echo "$setting_doc" | jq -r '.key // empty')
    [[ -z $setting_name ]] && setting_name="$setting_key"
    echo "Processing setting: $setting_name"

    setting_doc=$(echo "$setting_doc" | jq -c ".site_id = \"$site_id\" | .key = \"$setting_name\"")

    local existing
    existing=$(fetch_mongo "JSON.stringify(db.setting.findOne({key: \"$setting_name\"}, {_id: 1}))" || echo "null")

    if [[ $existing == "null" ]] || [[ -z $existing ]]; then
      echo "  Creating setting"
      run_mongo "db.setting.insertOne($setting_doc)"
    else
      local existing_id
      existing_id=$(echo "$existing" | jq -r '._id."$oid"')
      echo "  Updating setting"
      local update_doc
      update_doc=$(echo "$setting_doc" | jq -c 'del(.key, .site_id)')
      run_mongo "db.setting.updateOne({_id: ObjectId(\"$existing_id\")}, {\$set: $update_doc})"
    fi
  done
}
