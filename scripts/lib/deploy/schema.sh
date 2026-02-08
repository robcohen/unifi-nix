#!/usr/bin/env bash
# deploy/schema.sh - Schema extraction and default loading for unifi-nix deploy
# Source this file from deploy.sh

# =============================================================================
# Schema Extraction and Caching
# =============================================================================

# Extract and cache device schemas, set up environment variables
# Sets: UNIFI_DEVICE_SCHEMA_DIR, UNIFI_OPENAPI_SCHEMA_DIR, DEVICE_VERSION
# Returns: 0 on success, 1 on failure (with SKIP_SCHEMA_VALIDATION check)
setup_device_schemas() {
  local host="$1"
  local ssh_user="$2"
  local script_dir="$3"

  if [[ ${SKIP_SCHEMA_CACHE:-false} == "true" ]]; then
    return 0
  fi

  if [[ ! -x "$script_dir/extract-device-schema.sh" ]]; then
    return 0
  fi

  local device_schema_dir
  device_schema_dir=$("$script_dir/extract-device-schema.sh" "$host" "$ssh_user" 2>/dev/null | tail -1) || true

  if [[ -z $device_schema_dir ]] || [[ ! -d $device_schema_dir ]]; then
    return 0
  fi

  echo "Device schemas: $device_schema_dir"
  export UNIFI_DEVICE_SCHEMA_DIR="$device_schema_dir"

  # Check if OpenAPI schema exists for this version
  DEVICE_VERSION=$(cat "$device_schema_dir/version" 2>/dev/null || echo "unknown")
  export DEVICE_VERSION

  local openapi_schema_dir="$script_dir/../schemas/$DEVICE_VERSION"

  if [[ ! -f "$openapi_schema_dir/integration.json" ]]; then
    handle_missing_openapi_schema "$device_schema_dir" "$openapi_schema_dir" "$host" || return 1
  else
    echo "OpenAPI schema: $openapi_schema_dir"
    export UNIFI_OPENAPI_SCHEMA_DIR="$openapi_schema_dir"
    sync_device_enums "$device_schema_dir" "$openapi_schema_dir"
  fi

  echo ""
  return 0
}

# Handle case where OpenAPI schema is missing for device version
handle_missing_openapi_schema() {
  local device_schema_dir="$1"
  local openapi_schema_dir="$2"
  local host="$3"

  echo ""
  echo "WARNING: OpenAPI schema not found for version $DEVICE_VERSION"
  echo ""
  echo "Your device is running a version that isn't in the schema repository yet."
  echo "This can happen if:"
  echo "  1. Your device was recently upgraded"
  echo "  2. The CI pipeline hasn't extracted the new schema yet"
  echo ""

  # Create minimal schema directory with device-extracted enums
  if [[ -f "${device_schema_dir}/enums.json" ]]; then
    echo "Creating minimal schema directory for Nix-time validation..."
    mkdir -p "$openapi_schema_dir"
    cp "${device_schema_dir}/enums.json" "${openapi_schema_dir}/enums.json"
    echo "  Created: $openapi_schema_dir/enums.json"
    echo ""
    echo "NOTE: Full OpenAPI schema (integration.json) not available."
    echo "      Nix-time validation will use device-extracted enums."
    echo ""
  fi

  if [[ ${SKIP_SCHEMA_VALIDATION:-false} != "true" ]]; then
    echo "Options:"
    echo "  1. Wait for CI to extract the schema (runs every 6 hours)"
    echo "  2. Extract manually: ./scripts/extract-schema.sh $host"
    echo "  3. Skip validation: SKIP_SCHEMA_VALIDATION=true ./scripts/deploy.sh ..."
    echo ""
    return 1
  else
    echo "WARNING: Proceeding without OpenAPI validation (SKIP_SCHEMA_VALIDATION=true)"
  fi

  return 0
}

# Sync device-extracted enums to versioned schema directory
sync_device_enums() {
  local device_schema_dir="$1"
  local openapi_schema_dir="$2"

  if [[ ! -f "${device_schema_dir}/enums.json" ]]; then
    return 0
  fi

  if [[ ! -f "${openapi_schema_dir}/enums.json" ]]; then
    echo "  Syncing device enums to versioned schema..."
    cp "${device_schema_dir}/enums.json" "${openapi_schema_dir}/enums.json"
    return 0
  fi

  # Check if device enums are newer
  local device_mtime schema_mtime
  device_mtime=$(stat -c %Y "${device_schema_dir}/enums.json" 2>/dev/null || echo 0)
  schema_mtime=$(stat -c %Y "${openapi_schema_dir}/enums.json" 2>/dev/null || echo 0)

  if [[ $device_mtime -gt $schema_mtime ]]; then
    echo "  Checking for schema changes..."
    check_schema_migration "${openapi_schema_dir}/enums.json" "${device_schema_dir}/enums.json"
    echo "  Updating versioned schema with newer device enums..."
    cp "${device_schema_dir}/enums.json" "${openapi_schema_dir}/enums.json"
  fi
}

# Check for schema migration warnings
check_schema_migration() {
  local old_enums="$1"
  local new_enums="$2"
  local changes=0

  for key in zone_keys policy_actions policy_protocols network_purposes wifi_security; do
    local old_vals new_vals
    old_vals=$(jq -r ".${key} // [] | sort | .[]" "$old_enums" 2>/dev/null | tr '\n' ' ')
    new_vals=$(jq -r ".${key} // [] | sort | .[]" "$new_enums" 2>/dev/null | tr '\n' ' ')

    if [[ $old_vals != "$new_vals" ]]; then
      if [[ $changes -eq 0 ]]; then
        echo ""
        echo "  === Schema Migration Warnings ==="
      fi
      ((changes++)) || true

      # Find removed values
      for val in $old_vals; do
        if ! echo " $new_vals " | grep -q " $val "; then
          echo "    REMOVED: $key.$val"
        fi
      done

      # Find added values
      for val in $new_vals; do
        if ! echo " $old_vals " | grep -q " $val "; then
          echo "    ADDED: $key.$val"
        fi
      done
    fi
  done

  if [[ $changes -gt 0 ]]; then
    echo ""
    echo "  The device schema has changed. Your configuration may need updates."
    echo "  Run: nix run .#schema-diff -- <old-version> $DEVICE_VERSION"
    echo ""
  fi
}

# =============================================================================
# Default Loading from Schema
# =============================================================================

# Load defaults from device-extracted MongoDB examples
# Sets: WIFI_DEFAULTS, NETWORK_DEFAULTS, FIREWALL_POLICY_DEFAULTS, PORTFWD_DEFAULTS, DHCP_DEFAULTS
# Returns: 0, sets HAVE_SCHEMA_DEFAULTS
load_schema_defaults() {
  # Initialize defaults
  export WIFI_DEFAULTS='{}'
  export NETWORK_DEFAULTS='{}'
  export FIREWALL_POLICY_DEFAULTS='{}'
  export PORTFWD_DEFAULTS='{}'
  export DHCP_DEFAULTS='{}'
  export HAVE_SCHEMA_DEFAULTS="false"

  if [[ -z ${UNIFI_DEVICE_SCHEMA_DIR:-} ]]; then
    show_missing_defaults_warning
    return 0
  fi

  local schema_file="${UNIFI_DEVICE_SCHEMA_DIR}/mongodb-examples.json"
  if [[ ! -f $schema_file ]]; then
    show_missing_defaults_warning
    return 0
  fi

  echo "Loading defaults from schema..."

  # WiFi defaults (excluding instance-specific fields)
  WIFI_DEFAULTS=$(jq -c '.wlanconf | del(._id, .site_id, .networkconf_id, .usergroup_id, .ap_group_ids, .name, .x_passphrase, .x_iapp_key, .external_id)' "$schema_file" 2>/dev/null || echo '{}')

  # Network defaults
  NETWORK_DEFAULTS=$(jq -c '.networkconf_vlan // .networkconf // {} | del(._id, .site_id, .name, .ip_subnet, .vlan, .dhcpd_start, .dhcpd_stop)' "$schema_file" 2>/dev/null || echo '{}')

  # Firewall policy defaults
  FIREWALL_POLICY_DEFAULTS=$(jq -c '.firewall_policy // {} | del(._id, .site_id, .name, .description, .index, .source, .destination, .enabled)' "$schema_file" 2>/dev/null || echo '{}')

  # Port forward defaults
  PORTFWD_DEFAULTS=$(jq -c '.portforward // {} | del(._id, .site_id, .name, .dst_port, .fwd, .fwd_port)' "$schema_file" 2>/dev/null || echo '{}')

  # DHCP reservation defaults
  DHCP_DEFAULTS=$(jq -c '.dhcp_option // .dhcpd_static // {} | del(._id, .site_id, .mac, .ip, .name, .network_id)' "$schema_file" 2>/dev/null || echo '{}')

  echo "  Loaded defaults for: networks, wifi, firewall, port forwards, dhcp"
  echo ""

  # Track if we have safe defaults
  if [[ $WIFI_DEFAULTS != "{}" ]] && [[ $NETWORK_DEFAULTS != "{}" ]]; then
    HAVE_SCHEMA_DEFAULTS="true"
  fi

  export WIFI_DEFAULTS NETWORK_DEFAULTS FIREWALL_POLICY_DEFAULTS PORTFWD_DEFAULTS DHCP_DEFAULTS HAVE_SCHEMA_DEFAULTS
}

# Show warning when schema defaults are not available
show_missing_defaults_warning() {
  echo ""
  echo "WARNING: No schema defaults available!"
  echo "Creating new resources without schema defaults may result in incomplete MongoDB documents."
  echo "This can cause resources to not function correctly on the UniFi controller."
  echo ""
  echo "To fix: Run the deploy with schema caching enabled (default), or run:"
  echo "  ./scripts/extract-schema.sh ${HOST:-<host>}"
  echo ""
  if [[ ${ALLOW_UNSAFE_CREATE:-false} != "true" ]]; then
    echo "To proceed anyway (NOT RECOMMENDED), set ALLOW_UNSAFE_CREATE=true"
    echo ""
  fi
}

# =============================================================================
# Configuration Validation
# =============================================================================

# Run configuration validation
# Returns: 0 on success, 1 on failure
validate_configuration() {
  local config_json="$1"
  local script_dir="$2"

  if [[ -n ${UNIFI_OPENAPI_SCHEMA_DIR:-} ]] && [[ -n ${UNIFI_DEVICE_SCHEMA_DIR:-} ]]; then
    if [[ -x "$script_dir/validate-config.sh" ]]; then
      echo "=== Validating Configuration ==="
      if ! "$script_dir/validate-config.sh" "$config_json" "$UNIFI_OPENAPI_SCHEMA_DIR" "$UNIFI_DEVICE_SCHEMA_DIR"; then
        echo ""
        echo "Configuration validation failed. Fix the errors above before deploying."
        echo ""
        echo "To skip validation (not recommended):"
        echo "  SKIP_SCHEMA_VALIDATION=true ./scripts/deploy.sh ..."
        return 1
      fi
      echo ""
    fi
  elif [[ ${SKIP_SCHEMA_VALIDATION:-false} != "true" ]]; then
    echo "WARNING: Skipping validation (schemas not available)"
    echo ""
  fi

  return 0
}
