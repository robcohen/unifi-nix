#!/usr/bin/env bash
# deploy/backup.sh - Backup creation for unifi-nix deploy
# Source this file from deploy.sh

# =============================================================================
# Backup Creation
# =============================================================================

# Create backup of current configuration before deploying
# Args: host, ssh_user, backup_dir, device_version
# Returns: 0 on success (backup created or skipped), 1 on failure
create_pre_deploy_backup() {
  local host="$1"
  local ssh_user="$2"
  local backup_dir="$3"
  local device_version="${4:-unknown}"

  if [[ ${DRY_RUN:-false} == "true" ]]; then
    return 0
  fi

  if [[ ${SKIP_BACKUP:-false} == "true" ]]; then
    return 0
  fi

  echo "=== Creating Backup ==="
  mkdir -p "$backup_dir"

  local backup_file="$backup_dir/$(date +%Y%m%d-%H%M%S)-$host.json"

  echo "  Backing up current configuration..."

  local backup_data
  backup_data=$(ssh "$ssh_user@$host" 'mongo --quiet --port 27117 ace --eval "
    JSON.stringify({
      _backup_meta: {
        timestamp: new Date().toISOString(),
        host: \"'"$host"'\",
        version: \"'"$device_version"'\"
      },
      networkconf: db.networkconf.find({}).toArray(),
      wlanconf: db.wlanconf.find({}).toArray(),
      traffic_rule: db.traffic_rule.find({}).toArray(),
      firewall_policy: db.firewall_policy.find({}).toArray(),
      firewall_zone: db.firewall_zone.find({}).toArray(),
      portforward: db.portforward.find({}).toArray(),
      dhcp_option: db.dhcp_option.find({}).toArray()
    })
  "' 2>/dev/null)

  if [[ -n $backup_data ]] && [[ $backup_data != "null" ]]; then
    echo "$backup_data" | jq '.' >"$backup_file"
    echo "  Backup saved: $backup_file"
    echo ""
    echo "  To restore if something goes wrong:"
    echo "    unifi-restore $backup_file $host"
    echo ""
    export LAST_BACKUP_FILE="$backup_file"
    return 0
  else
    echo "  WARNING: Could not create backup (empty response)"
    echo "  Proceeding anyway..."
    echo ""
    return 0
  fi
}

# =============================================================================
# Confirmation Prompt
# =============================================================================

# Show changes summary and prompt for confirmation
# Args: desired_config
# Returns: 0 if confirmed, 1 if aborted
confirm_deployment() {
  local desired="$1"

  if [[ ${DRY_RUN:-false} == "true" ]]; then
    return 0
  fi

  if [[ ${AUTO_CONFIRM:-false} == "true" ]]; then
    return 0
  fi

  echo "=== Changes to Apply ==="
  show_deploy_summary "$desired"
  echo ""

  if [[ ${ALLOW_DELETES:-false} == "true" ]]; then
    echo "  WARNING: ALLOW_DELETES=true - orphaned resources will be removed!"
    echo ""
  fi

  # Prompt for confirmation
  echo -n "Apply these changes to ${HOST}? [y/N] "
  read -r confirm
  if [[ $confirm != "y" ]] && [[ $confirm != "Y" ]]; then
    echo "Aborted."
    return 1
  fi
  echo ""
  return 0
}
