# Schema loader - imports generated schema for Nix-time validation
# Uses generated enums.json from the automation framework
{ lib }:

let
  # Helper to get enum values with fallback
  # Handles both old format (list) and new format ({ values, collections })
  getEnum =
    enums: key: fallback:
    let
      raw = enums.${key} or null;
      values =
        if raw == null then
          [ ]
        else if builtins.isList raw then
          raw
        else if builtins.isAttrs raw && raw ? values then
          raw.values
        else
          [ ];
    in
    if values != [ ] then lib.unique (values ++ fallback) else fallback;

  # Load schema from a directory containing enums.json
  loadSchema =
    schemaDir:
    let
      enumsPath = "${schemaDir}/enums.json";
      hasEnums = builtins.pathExists enumsPath;
      enums = if hasEnums then builtins.fromJSON (builtins.readFile enumsPath) else { };

      # Also try to load generated enums (from generate-schema output)
      generatedPath = "${schemaDir}/generated/enums.json";
      hasGenerated = builtins.pathExists generatedPath;
      generated = if hasGenerated then builtins.fromJSON (builtins.readFile generatedPath) else { };

      # Merge generated with base enums (generated takes precedence)
      allEnums = enums // generated;
    in
    {
      inherit hasEnums;

      # Zone-based firewall zones
      zoneKeys = getEnum allEnums "zone_keys" [
        "internal"
        "external"
        "gateway"
        "vpn"
        "hotspot"
        "dmz"
      ];

      # Network configuration
      networkPurposes = getEnum allEnums "network_purposes" [
        "corporate"
        "guest"
        "wan"
        "vlan-only"
        "remote-user-vpn"
        "site-vpn"
      ];

      networkGroups = getEnum allEnums "network_groups" [
        "LAN"
        "WAN"
        "WAN2"
      ];

      # WiFi configuration
      wifiSecurity = getEnum allEnums "wifi_security" [
        "open"
        "wpapsk"
        "wpaeap"
        "wep"
      ];

      wifiWpaModes = getEnum allEnums "wifi_wpa_modes" [
        "wpa2"
        "wpa3"
        "auto"
      ];

      wifiPmfModes = getEnum allEnums "wifi_pmf_modes" [
        "disabled"
        "optional"
        "required"
      ];

      wifiBands = getEnum allEnums "wifi_bands" [
        "2g"
        "5g"
        "6g"
      ];

      wifiMacFilterPolicies = getEnum allEnums "wifi_mac_filter_policies" [
        "allow"
        "deny"
      ];

      # Firewall policy configuration
      policyActions = getEnum allEnums "action" [
        "allow"
        "block"
        "reject"
        "ALLOW"
        "BLOCK"
        "REJECT"
      ];

      policyProtocols = getEnum allEnums "protocols" [
        "all"
        "tcp_udp"
        "tcp"
        "udp"
        "icmp"
        "icmpv6"
      ];

      policyIpVersions = getEnum allEnums "ip_versions" [
        "both"
        "ipv4"
        "ipv6"
        "BOTH"
        "IPV4"
        "IPV6"
      ];

      connectionStateTypes = getEnum allEnums "state" [
        "ALL"
        "ESTABLISHED"
        "INVALID"
        "NEW"
        "RELATED"
        "RETURN_TRAFFIC"
      ];

      matchingTargets = getEnum allEnums "matching_targets" [
        "any"
        "network"
        "ip"
        "mac"
        "device"
        "NETWORK"
        "IP"
        "ANY"
      ];

      # Port forwarding
      portForwardProtocols = getEnum allEnums "protocols" [
        "tcp"
        "udp"
        "tcp_udp"
      ];

      # Traffic rules (QoS)
      trafficRuleActions = getEnum allEnums "traffic_actions" [
        "BLOCK"
        "ALLOW"
        "QOS_RATE_LIMIT"
      ];

      trafficRuleTargets = getEnum allEnums "matching_targets" [
        "INTERNET"
        "LOCAL_NETWORK"
        "IP"
        "NETWORK"
        "DOMAIN"
        "REGION"
      ];

      # Routing
      routingTypes = [
        "static"
        "policy"
      ];

      # Firewall groups
      firewallGroupTypes = [
        "address-group"
        "port-group"
        "ipv6-address-group"
      ];

      # Port profiles (switch)
      portProfileForwards = [
        "all"
        "native"
        "disabled"
        "customize"
      ];

      poeModes = [
        "auto"
        "off"
        "pasv24"
        "passthrough"
      ];

      portSpeeds = [
        "autoneg"
        "10"
        "100"
        "1000"
        "2500"
        "10000"
      ];
    };

  # Default schema (no device-specific data)
  defaultSchema = loadSchema "/nonexistent";

  # Load schema for a specific version
  loadVersionedSchema =
    version:
    let
      schemaDir = ../schemas/${version};
    in
    if builtins.pathExists schemaDir then loadSchema (toString schemaDir) else defaultSchema;

  # Find the latest schema version
  findLatestSchema =
    let
      schemasDir = ../schemas;
      hasSchemasDir = builtins.pathExists schemasDir;
      versions =
        if hasSchemasDir then
          builtins.filter (
            name:
            let
              path = schemasDir + "/${name}";
            in
            builtins.pathExists path
            && (
              builtins.pathExists (path + "/enums.json") || builtins.pathExists (path + "/generated/enums.json")
            )
          ) (builtins.attrNames (builtins.readDir schemasDir))
        else
          [ ];
      sortedVersions = builtins.sort (a: b: a > b) versions;
      latestVersion = if sortedVersions != [ ] then builtins.head sortedVersions else null;
    in
    if latestVersion != null then loadVersionedSchema latestVersion else defaultSchema;

in
{
  inherit
    loadSchema
    loadVersionedSchema
    defaultSchema
    findLatestSchema
    ;

  # Convenience: get the best available schema
  schema = findLatestSchema;
}
