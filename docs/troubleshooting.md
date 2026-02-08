# Troubleshooting Guide

Common issues and solutions when using unifi-nix.

## Connection Issues

### SSH Connection Refused

**Symptom**: `ssh: connect to host X.X.X.X port 22: Connection refused`

**Solutions**:

1. Enable SSH on the UDM: Settings > System > SSH
1. Verify the host IP in your configuration
1. Check if a firewall is blocking port 22

### SSH Authentication Failed

**Symptom**: `Permission denied (publickey,password)`

**Solutions**:

1. Use the correct username (usually `root` for UDM/UDMP)
1. Ensure your SSH key is added to the UDM
1. Try with explicit key: `UNIFI_SSH_USER=root nix run .#deploy -- /path/to/config.nix`

### MongoDB Connection Error

**Symptom**: `couldn't connect to server 127.0.0.1:27117`

**Solutions**:

1. MongoDB runs on port 27117, not the default 27017
1. Wait for the UDM to fully boot (MongoDB starts after network services)
1. SSH into UDM and verify: `mongo --port 27117 ace --eval "db.stats()"`

## Configuration Issues

### VLAN Already Exists

**Symptom**: `Duplicate VLAN IDs: [10]`

**Cause**: Two networks configured with the same VLAN ID

**Solution**: Each VLAN ID must be unique. Review your network configurations.

### Invalid Network Reference

**Symptom**: `WiFi networks reference undefined networks: [IoT]`

**Cause**: A WiFi config references a network that doesn't exist

**Solution**: Ensure the network name in `wifi.*.network` matches a defined network name exactly (case-sensitive).

### Overlapping Subnets

**Symptom**: `Overlapping subnets: Default overlaps IoT`

**Cause**: Two networks have IP ranges that overlap

**Solution**: Use non-overlapping CIDR ranges. Example:

- Default: `192.168.1.1/24` (192.168.1.0-255)
- IoT: `192.168.10.1/24` (192.168.10.0-255)

### DHCP Range Required

**Symptom**: `Network 'IoT': dhcp.start is required when dhcp.enable = true`

**Solution**: When enabling DHCP, you must specify both `start` and `end`:

```nix
networks.IoT = {
  subnet = "192.168.10.1/24";
  dhcp = {
    enable = true;
    start = "192.168.10.100";
    end = "192.168.10.254";
  };
};
```

## Firewall Issues

### Zone-Based Firewall Not Enabled

**Symptom**: `ERROR: Zone-based firewall is NOT enabled on the UDM`

**Cause**: You have firewall policies defined but haven't upgraded to zone-based firewall

**Solution**:

1. Go to UniFi Network settings
1. Navigate to Firewall & Security
1. Click "Upgrade to Zone-Based Firewall"
1. Re-run the deploy

### Firewall Policy Not Working

**Symptom**: Traffic still flows despite block policy

**Solutions**:

1. Check policy `index` - lower numbers = higher priority
1. Verify source/destination zones are correct
1. Check if another policy with lower index is allowing traffic
1. Use `logging = true` to debug which policy matches

### Zone Reference Error

**Symptom**: `error: value 'myzone' is not valid for option`

**Cause**: Invalid zone name used

**Valid zones**: `internal`, `external`, `gateway`, `vpn`, `hotspot`, `dmz`

## Secret Resolution Issues

### Secret Not Found

**Symptom**: `ERROR: Could not resolve secret 'wifi/main'`

**Solutions**:

1. Set `UNIFI_SECRETS_DIR` to a directory containing secret files
1. Or set environment variable: `WIFI_MAIN=yourpassword`
1. File path: `$UNIFI_SECRETS_DIR/wifi/main` should contain the password

### RADIUS/VPN Secret Error

**Symptom**: `ERROR: Could not resolve radiusprofile corporate x_secret secret`

**Solution**: For RADIUS and VPN secrets, use the secret reference format:

```nix
radiusProfiles.corporate = {
  authServers = [{
    ip = "192.168.1.10";
    port = 1812;
    secret = { _secret = "radius/corp"; };  # File or env var
  }];
};
```

Then either:

- Create file: `$UNIFI_SECRETS_DIR/radius/corp`
- Or set: `export RADIUS_CORP=yoursecret`

## Deployment Issues

### Changes Not Applied

**Symptom**: Deploy completes but settings don't appear

**Solutions**:

1. Force provision devices: Settings > Devices > select device > Force Provision
1. Wait for the UniFi controller to sync (can take 1-2 minutes)
1. Check MongoDB directly: `ssh root@udm 'mongo --port 27117 ace --eval "db.networkconf.find().pretty()"'`

### WiFi Network Not Broadcasting

**Symptom**: WiFi network created but not visible

**Solutions**:

1. Verify the network binding: `wifi.*.network` must match a network name
1. Check AP groups if specified
1. Verify the bands configuration includes the AP's supported bands
1. Force provision APs after network changes

### Port Forward Not Working

**Symptom**: External connections not reaching internal host

**Solutions**:

1. Verify `dstIP` is correct and device is on
1. Check firewall isn't blocking the traffic
1. Verify `protocol` matches (tcp, udp, or tcp_udp)
1. Test from outside the network (NAT loopback may not work)

## Validation and Debugging

### View Generated Configuration

Before deploying, inspect what will be sent:

```bash
nix run .#eval -- sites/home.nix | jq .
```

### Diff Against Current State

See what will change before deploying:

```bash
nix run .#diff -- sites/home.nix
```

### Validate Without Deploying

Check for errors without making changes:

```bash
nix run .#validate -- sites/home.nix
```

### Check Schema Version

Ensure your schema matches the UDM version:

```bash
# Extract current UDM schema
nix run .#extract-schema -- root@192.168.1.1 ./schemas/current

# Compare with stored schema
nix run .#schema-diff -- ./schemas/10.0.162 ./schemas/current
```

## Recovery

### Rollback to Previous State

If a deploy breaks something:

```bash
# Restore from backup (if taken before deploy)
nix run .#restore -- root@192.168.1.1 ./backups/2024-01-15-pre-deploy.json
```

### Factory Reset Network

As a last resort, reset network settings via the UniFi app or controller UI.

### Manual MongoDB Fix

For emergency fixes, SSH to the UDM:

```bash
ssh root@udm
mongo --port 27117 ace

# Example: Delete a broken network
db.networkconf.deleteOne({name: "BrokenNetwork"})

# Example: Disable a firewall rule
db.firewallrule.updateOne({name: "BadRule"}, {$set: {enabled: false}})
```

## Getting Help

1. Check the [README](../README.md) for examples
1. Review the [schema documentation](./SCHEMA.md)
1. Open an issue on GitHub with:
   - Your configuration (sanitized)
   - Error message
   - UDM model and firmware version
   - `nix flake show` output
