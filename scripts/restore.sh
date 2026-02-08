#!/usr/bin/env bash
# unifi-restore: Restore UniFi configuration from backup
# Usage: unifi-restore <backup.json> <host>
set -euo pipefail

BACKUP_FILE="${1:-}"
HOST="${2:-}"
SSH_USER="${SSH_USER:-root}"
DRY_RUN="${DRY_RUN:-false}"

if [[ -z $BACKUP_FILE ]] || [[ -z $HOST ]]; then
  echo "Usage: unifi-restore <backup.json> <host>"
  echo ""
  echo "Restores UniFi configuration from a backup created by unifi-deploy."
  echo ""
  echo "Arguments:"
  echo "  backup.json  Path to backup JSON file"
  echo "  host         UDM IP address or hostname"
  echo ""
  echo "Environment:"
  echo "  DRY_RUN=true     Show commands without executing"
  echo "  SSH_USER=root    SSH username (default: root)"
  echo ""
  echo "Example:"
  echo "  unifi-restore ~/.local/share/unifi-nix/backups/20240215-143022-192.168.1.1.json 192.168.1.1"
  exit 1
fi

if [[ ! -f $BACKUP_FILE ]]; then
  echo "Error: Backup file not found: $BACKUP_FILE"
  exit 1
fi

echo "=== UniFi Configuration Restore ==="
echo "Backup: $BACKUP_FILE"
echo "Host:   $HOST"
[[ $DRY_RUN == "true" ]] && echo "Mode:   DRY RUN"
echo ""

# Validate backup file
BACKUP_META=$(jq -r '._backup_meta // empty' "$BACKUP_FILE")
if [[ -z $BACKUP_META ]]; then
  echo "Error: Invalid backup file (missing _backup_meta)"
  exit 1
fi

BACKUP_TIMESTAMP=$(echo "$BACKUP_META" | jq -r '.timestamp')
BACKUP_HOST=$(echo "$BACKUP_META" | jq -r '.host')

BACKUP_VERSION=$(echo "$BACKUP_META" | jq -r '.version // "unknown"')

echo "Backup from: $BACKUP_TIMESTAMP"
echo "Original host: $BACKUP_HOST"
echo "Backup version: $BACKUP_VERSION"
echo ""

# Schema validation
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEMAS_DIR="$SCRIPT_DIR/../schemas"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/unifi-nix"

validate_backup() {
  local warnings=0
  local errors=0

  echo "=== Validating Backup Against Schema ==="

  # Try to find matching schema
  SCHEMA_DIR=""
  if [[ -d "$SCHEMAS_DIR/$BACKUP_VERSION" ]]; then
    SCHEMA_DIR="$SCHEMAS_DIR/$BACKUP_VERSION"
    echo "Using schema: $BACKUP_VERSION"
  else
    # Find latest schema
    LATEST=$(ls -1 "$SCHEMAS_DIR" 2>/dev/null | sort -V | tail -1)
    if [[ -n $LATEST ]]; then
      SCHEMA_DIR="$SCHEMAS_DIR/$LATEST"
      echo "WARNING: No schema for $BACKUP_VERSION, using $LATEST"
      ((warnings++)) || true
    fi
  fi

  if [[ -z $SCHEMA_DIR ]] || [[ ! -f "$SCHEMA_DIR/enums.json" ]]; then
    echo "WARNING: No schema available for validation"
    echo "         Backup may contain invalid values"
    echo ""
    return 0
  fi

  ENUMS="$SCHEMA_DIR/enums.json"

  # Validate network purposes
  local valid_purposes
  valid_purposes=$(jq -r '.network_purposes // [] | .[]' "$ENUMS" 2>/dev/null || true)
  if [[ -n $valid_purposes ]]; then
    # Add known defaults
    valid_purposes="$valid_purposes corporate guest wan vlan-only remote-user-vpn site-vpn"

    while read -r purpose; do
      if [[ -n $purpose ]] && ! echo "$valid_purposes" | grep -qw "$purpose"; then
        echo "  WARNING: Unknown network purpose: $purpose"
        ((warnings++)) || true
      fi
    done < <(jq -r '.networkconf[]?.purpose // empty' "$BACKUP_FILE" 2>/dev/null)
  fi

  # Validate WiFi security
  local valid_security
  valid_security=$(jq -r '.wifi_security // [] | .[]' "$ENUMS" 2>/dev/null || true)
  if [[ -n $valid_security ]]; then
    valid_security="$valid_security open wpapsk wpaeap wep"

    while read -r security; do
      if [[ -n $security ]] && ! echo "$valid_security" | grep -qw "$security"; then
        echo "  WARNING: Unknown WiFi security: $security"
        ((warnings++)) || true
      fi
    done < <(jq -r '.wlanconf[]?.security // empty' "$BACKUP_FILE" 2>/dev/null)
  fi

  # Validate firewall zones (if zone-based)
  local valid_zones
  valid_zones=$(jq -r '.zone_keys // [] | .[]' "$ENUMS" 2>/dev/null || true)
  if [[ -n $valid_zones ]]; then
    valid_zones="$valid_zones internal external gateway vpn hotspot dmz"

    while read -r zone; do
      if [[ -n $zone ]] && ! echo "$valid_zones" | grep -qw "$zone"; then
        echo "  WARNING: Unknown firewall zone: $zone"
        ((warnings++)) || true
      fi
    done < <(jq -r '.firewall_policy[]? | .source._zone_key // empty, .destination._zone_key // empty' "$BACKUP_FILE" 2>/dev/null)
  fi

  echo ""
  if [[ $warnings -gt 0 ]]; then
    echo "Validation: $warnings warning(s)"
    echo "The backup may contain values from a different UniFi version."
    echo -n "Continue with restore? [y/N] "
    read -r confirm
    if [[ $confirm != "y" ]] && [[ $confirm != "Y" ]]; then
      echo "Aborted."
      exit 0
    fi
  else
    echo "Validation: OK"
  fi
  echo ""
}

validate_backup

if [[ $BACKUP_HOST != "$HOST" ]]; then
  echo "WARNING: Backup was created from a different host!"
  echo -n "Continue anyway? [y/N] "
  read -r confirm
  if [[ $confirm != "y" ]] && [[ $confirm != "Y" ]]; then
    echo "Aborted."
    exit 0
  fi
  echo ""
fi

# Show what will be restored
echo "=== Backup Contents ==="
net_count=$(jq '.networkconf | length // 0' "$BACKUP_FILE")
wifi_count=$(jq '.wlanconf | length // 0' "$BACKUP_FILE")
policy_count=$(jq '.firewall_policy | length // 0' "$BACKUP_FILE")
group_count=$(jq '.firewallgroup | length // 0' "$BACKUP_FILE")
pf_count=$(jq '.portforward | length // 0' "$BACKUP_FILE")
dhcp_count=$(jq '.dhcp_option | length // 0' "$BACKUP_FILE")
apgroup_count=$(jq '.apgroup | length // 0' "$BACKUP_FILE")
usergroup_count=$(jq '.usergroup | length // 0' "$BACKUP_FILE")
traffic_count=$(jq '.traffic_rule | length // 0' "$BACKUP_FILE")
radius_count=$(jq '.radiusprofile | length // 0' "$BACKUP_FILE")
portconf_count=$(jq '.portconf | length // 0' "$BACKUP_FILE")
schedule_count=$(jq '.scheduletask | length // 0' "$BACKUP_FILE")
wlangroup_count=$(jq '.wlangroup | length // 0' "$BACKUP_FILE")

echo "  Networks:           $net_count"
echo "  WiFi:               $wifi_count"
echo "  Firewall policies:  $policy_count"
echo "  Firewall groups:    $group_count"
echo "  Port forwards:      $pf_count"
echo "  DHCP reservations:  $dhcp_count"
echo "  AP groups:          $apgroup_count"
echo "  User groups:        $usergroup_count"
echo "  Traffic rules:      $traffic_count"
echo "  RADIUS profiles:    $radius_count"
echo "  Port profiles:      $portconf_count"
echo "  Scheduled tasks:    $schedule_count"
echo "  WLAN groups:        $wlangroup_count"
echo ""

echo "WARNING: This will REPLACE all current configuration with the backup!"
echo -n "Are you sure you want to restore? [y/N] "
read -r confirm
if [[ $confirm != "y" ]] && [[ $confirm != "Y" ]]; then
  echo "Aborted."
  exit 0
fi
echo ""

run_mongo() {
  local cmd="$1"
  if [[ $DRY_RUN == "true" ]]; then
    echo "[DRY RUN] mongo: ${cmd:0:80}..."
  else
    ssh -o ConnectTimeout=10 "$SSH_USER@$HOST" "mongo --quiet --port 27117 ace --eval '$cmd'"
  fi
}

echo "=== Restoring Configuration ==="

# All collections to restore (order matters - networks before wifi, etc.)
COLLECTIONS=(
  "networkconf"
  "wlanconf"
  "firewall_policy"
  "firewallgroup"
  "portforward"
  "dhcp_option"
  "apgroup"
  "usergroup"
  "traffic_rule"
  "radiusprofile"
  "portconf"
  "dpigroup"
  "scheduletask"
  "wlangroup"
  "setting"
  "alert_setting"
  "firewall_zone"
  "doh_servers"
  "ssl_inspection_profile"
  "dashboard"
  "diagnostics_config"
)

# Restore each collection
for collection in "${COLLECTIONS[@]}"; do
  # Get docs from backup (skip if not in backup)
  docs=$(jq -c ".$collection // []" "$BACKUP_FILE")
  doc_count=$(echo "$docs" | jq 'length')

  if [[ $doc_count -eq 0 ]]; then
    continue # Skip empty collections silently
  fi

  echo "Restoring $collection ($doc_count documents)..."

  if [[ $DRY_RUN == "true" ]]; then
    echo "  [DRY RUN] Would restore $doc_count documents"
  else
    # Clear existing and insert from backup
    run_mongo "db.$collection.deleteMany({})"

    # Insert each document
    echo "$docs" | jq -c '.[]' | while read -r doc; do
      # Remove the _id field so MongoDB generates a new one
      clean_doc=$(echo "$doc" | jq -c 'del(._id)')
      run_mongo "db.$collection.insertOne($clean_doc)"
    done

    echo "  Done"
  fi
done

echo ""
echo "=== Restore Complete ==="
echo "Changes should take effect within 30 seconds."
echo "If not, SSH to UDM and run: unifi-os restart"
