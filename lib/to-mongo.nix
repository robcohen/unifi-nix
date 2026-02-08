# Convert Nix UniFi config to MongoDB document format
{ lib }:

let
  inherit (lib) mapAttrs;

  # Schema-based conversion generator for new collections
  # Usage: fromSchema.convertCollection "collection_name" config.myCollection
  fromSchema = import ./from-schema.nix { inherit lib; };

  # Parse subnet string "192.168.10.1/24" into components
  parseSubnet =
    subnet:
    let
      parts = lib.splitString "/" subnet;
      ip = builtins.elemAt parts 0;
      prefix = builtins.elemAt parts 1;
      ipParts = lib.splitString "." ip;
      baseIp = "${builtins.elemAt ipParts 0}.${builtins.elemAt ipParts 1}.${builtins.elemAt ipParts 2}";
    in
    {
      inherit ip prefix baseIp;
      gateway = ip;
      ipSubnet = "${ip}/${prefix}";
    };

  # Convert a network config to MongoDB networkconf document
  networkToMongo =
    name: cfg:
    let
      subnet = parseSubnet cfg.subnet;
    in
    {
      inherit name;
      enabled = cfg.enable;
      inherit (cfg) purpose;
      ip_subnet = subnet.ipSubnet;

      # VLAN settings
      vlan_enabled = cfg.vlan != null;
      vlan = if cfg.vlan != null then cfg.vlan else 0;
      networkgroup = cfg.networkGroup;

      # DHCP settings
      dhcpd_enabled = cfg.dhcp.enable;
      dhcpd_start =
        if cfg.dhcp.start != null then
          cfg.dhcp.start
        else if cfg.dhcp.enable then
          throw "Network '${name}': dhcp.start is required when dhcp.enable = true"
        else
          "";
      dhcpd_stop =
        if cfg.dhcp.end != null then
          cfg.dhcp.end
        else if cfg.dhcp.enable then
          throw "Network '${name}': dhcp.end is required when dhcp.enable = true"
        else
          "";
      dhcpd_leasetime = cfg.dhcp.leasetime;

      # DNS settings (UniFi supports up to 4 DNS servers)
      dhcpd_dns_enabled = cfg.dhcp.dns != [ ];
      dhcpd_dns_1 = if builtins.length cfg.dhcp.dns >= 1 then builtins.elemAt cfg.dhcp.dns 0 else "";
      dhcpd_dns_2 = if builtins.length cfg.dhcp.dns >= 2 then builtins.elemAt cfg.dhcp.dns 1 else "";
      dhcpd_dns_3 = if builtins.length cfg.dhcp.dns >= 3 then builtins.elemAt cfg.dhcp.dns 2 else "";
      dhcpd_dns_4 = if builtins.length cfg.dhcp.dns >= 4 then builtins.elemAt cfg.dhcp.dns 3 else "";

      # Network features
      internet_access_enabled = cfg.internetAccess;
      network_isolation_enabled = cfg.isolate;
      mdns_enabled = cfg.mdns;
      igmp_snooping = cfg.igmpSnooping;

      # Defaults for required fields
      dhcp_relay_enabled = false;
      dhcpd_boot_enabled = false;
      dhcpd_gateway_enabled = false;
      dhcpd_ntp_enabled = false;
      dhcpd_wins_enabled = false;
      setting_preference = "manual";
    };

  # Convert a WiFi config to MongoDB wlanconf document
  wifiToMongo = _name: cfg: _networkLookup: {
    name = cfg.ssid;
    enabled = cfg.enable;

    # Security settings
    inherit (cfg) security;
    wpa_mode = if cfg.wpa3.enable then "wpa3" else "wpa2";
    wpa3_support = cfg.wpa3.enable;
    wpa3_transition = cfg.wpa3.enable && cfg.wpa3.transition;
    pmf_mode = cfg.pmf;
    wpa_enc = "ccmp";

    # Network binding - will be resolved to networkconf_id at deploy time
    _network_name = cfg.network;

    # Passphrase - will be resolved at deploy time if it's a secret reference
    x_passphrase = cfg.passphrase;

    # Visibility and isolation
    hide_ssid = cfg.hidden;
    l2_isolation = cfg.clientIsolation;
    is_guest = cfg.guestMode;

    # Multicast
    mcastenhance_enabled = cfg.multicastEnhance;

    # Band settings
    wlan_bands = cfg.bands;
    minrate_ng_enabled = true;
    minrate_ng_data_rate_kbps = cfg.minRate."2g";
    minrate_na_enabled = true;
    minrate_na_data_rate_kbps = cfg.minRate."5g";

    # Roaming and transition features
    bss_transition = cfg.bssTransition;
    fast_roaming_enabled = cfg.fastRoaming;

    # MAC filtering
    mac_filter_enabled = cfg.macFilter.enable;
    mac_filter_policy = cfg.macFilter.policy;
    mac_filter_list = cfg.macFilter.list;

    # Other settings
    no2ghz_oui = false;
    setting_preference = "manual";
  };

  # Convert a port forward to MongoDB portforward document
  portForwardToMongo = _name: cfg: {
    inherit (cfg) name log;
    enabled = cfg.enable;
    pfwd_interface = "wan";
    src = if cfg.srcIP != null then cfg.srcIP else "any";
    dst_port = toString cfg.srcPort;
    fwd = cfg.dstIP;
    fwd_port = toString (if cfg.dstPort != null then cfg.dstPort else cfg.srcPort);
    proto = cfg.protocol;
    setting_preference = "manual";
  };

  # Convert a DHCP reservation to MongoDB dhcp_option document
  dhcpReservationToMongo = _name: cfg: {
    inherit (cfg) mac ip name;
    _network_name = cfg.network;
    setting_preference = "manual";
  };

  # Map action names to MongoDB values (lowercase -> uppercase)
  actionMap = {
    allow = "ALLOW";
    block = "BLOCK";
    reject = "REJECT";
  };

  # Map IP version to MongoDB values
  ipVersionMap = {
    both = "BOTH";
    ipv4 = "IPV4";
    ipv6 = "IPV6";
  };

  # Map connection state to MongoDB values
  connectionStateMap = {
    all = "ALL";
    return = "RETURN_TRAFFIC";
  };

  # Convert a firewall group to MongoDB firewallgroup document
  firewallGroupToMongo = _name: cfg: {
    inherit (cfg) name;
    group_type = cfg.type;
    group_members = cfg.members;
    site_id = "_SITE_ID_"; # Resolved at deploy time
  };

  # Convert an AP group to MongoDB apgroup document
  apGroupToMongo = _name: cfg: {
    inherit (cfg) name;
    device_macs = cfg.devices;
    attr_hidden_id = "";
    attr_no_delete = false;
    site_id = "_SITE_ID_";
  };

  # Convert a user group to MongoDB usergroup document
  userGroupToMongo = _name: cfg: {
    inherit (cfg) name;
    qos_rate_max_down = if cfg.downloadLimit != null then cfg.downloadLimit else -1;
    qos_rate_max_up = if cfg.uploadLimit != null then cfg.uploadLimit else -1;
    attr_hidden_id = "";
    attr_no_delete = false;
    site_id = "_SITE_ID_";
  };

  # Convert a traffic rule to MongoDB traffic_rule document
  trafficRuleToMongo = _name: cfg: {
    inherit (cfg) name description;
    enabled = cfg.enable;
    inherit (cfg) action;
    matching_target = cfg.matchingTarget;
    _network_name = cfg.networkId;
    target_devices = [ ];

    # Bandwidth limits (for QOS_RATE_LIMIT action)
    bandwidth_limit = {
      enabled = cfg.action == "QOS_RATE_LIMIT";
      download_limit_kbps =
        if cfg.bandwidthLimit.download != null then cfg.bandwidthLimit.download else 0;
      upload_limit_kbps = if cfg.bandwidthLimit.upload != null then cfg.bandwidthLimit.upload else 0;
    };

    # Schedule
    schedule = {
      inherit (cfg.schedule) mode;
    };

    inherit (cfg) index;
    site_id = "_SITE_ID_";
  };

  # Convert a RADIUS profile to MongoDB radiusprofile document
  radiusProfileToMongo = _name: cfg: {
    inherit (cfg) name;
    use_usg_auth_server = false;

    # Auth servers
    auth_servers = map (s: {
      inherit (s) ip port;
      x_secret = s.secret;
    }) cfg.authServers;

    # Accounting servers
    acct_servers = map (s: {
      inherit (s) ip port;
      x_secret = s.secret;
    }) cfg.acctServers;

    site_id = "_SITE_ID_";
  };

  # Convert a DPI group to MongoDB dpigroup document
  dpiGroupToMongo = _name: cfg: {
    inherit (cfg) name;

    # App IDs (directly specified or resolved from categories at deploy time)
    dpiapp_ids = cfg.appIds;

    # Categories to resolve at deploy time
    _categories = cfg.categories;

    site_id = "_SITE_ID_";
  };

  # Convert WireGuard server config to MongoDB setting document
  wireguardServerToMongo = cfg: {
    key = "wireguard_server";
    wg_enabled = cfg.enable;
    wg_port = cfg.port;
    wg_cidr = cfg.network;
    wg_dns = cfg.dns;
    wg_allowed_networks = cfg.allowedNetworks;
    site_id = "_SITE_ID_";
  };

  # Convert WireGuard peer to MongoDB format
  wireguardPeerToMongo = _name: cfg: {
    inherit (cfg) name;
    public_key = cfg.publicKey;
    preshared_key = cfg.presharedKey;
    allowed_ips = cfg.allowedIPs;
  };

  # Convert site-to-site VPN to MongoDB setting document
  siteToSiteVpnToMongo = _name: cfg: {
    inherit (cfg) name;
    enabled = cfg.enable;
    vpn_type = cfg.type;
    remote_host = cfg.remoteHost;
    remote_networks = cfg.remoteNetworks;
    local_networks = cfg.localNetworks;
    x_psk = cfg.presharedKey;

    # IPsec specific settings
    ike_version = cfg.ipsec.ikeVersion;
    inherit (cfg.ipsec) encryption hash;
    dh_group = cfg.ipsec.dhGroup;

    site_id = "_SITE_ID_";
  };

  # Convert a port profile to MongoDB portconf document
  portProfileToMongo = _name: cfg: {
    inherit (cfg) name forward;

    # Native VLAN reference (resolved at deploy time)
    _native_network_name = cfg.nativeNetwork;

    # Tagged VLANs (resolved at deploy time)
    _tagged_network_names = cfg.taggedNetworks;

    # PoE settings
    poe_mode = cfg.poeMode;

    # Speed/duplex
    inherit (cfg) speed;
    full_duplex = true;

    # Storm control
    stormctrl_enabled = cfg.stormControl.enable;
    stormctrl_rate = cfg.stormControl.rate;

    # Port isolation
    port_security_enabled = cfg.isolation;

    site_id = "_SITE_ID_";
  };

  # Convert a firewall policy to MongoDB firewall_policy document (UniFi 10.x+)
  firewallPolicyToMongo = name: cfg: {
    inherit (cfg) name description;
    enabled = cfg.enable;
    action = actionMap.${cfg.action};
    inherit (cfg) index;

    # Source configuration
    source = {
      # Zone key for runtime lookup (zone names match MongoDB values directly)
      _zone_key = cfg.sourceZone;
      matching_target = lib.toUpper cfg.sourceType;
      _network_names = cfg.sourceNetworks;
      _ips = cfg.sourceIPs;
      port_matching_type = if cfg.sourcePort != null then "SPECIFIC" else "ANY";
      ports = if cfg.sourcePort != null then [ (toString cfg.sourcePort) ] else [ ];
      match_opposite_networks = false;
      match_opposite_ports = false;
      match_mac = false;
    };

    # Destination configuration
    destination = {
      _zone_key = cfg.destinationZone;
      matching_target = lib.toUpper cfg.destinationType;
      _network_names = cfg.destinationNetworks;
      _ips = cfg.destinationIPs;
      port_matching_type = if cfg.destinationPort != null then "SPECIFIC" else "ANY";
      ports = if cfg.destinationPort != null then [ (toString cfg.destinationPort) ] else [ ];
      match_opposite_networks = false;
      match_opposite_ports = false;
    };

    # Protocol and IP version
    inherit (cfg) protocol;
    ip_version = ipVersionMap.${cfg.ipVersion};

    # Connection state
    connection_state_type = connectionStateMap.${cfg.connectionState};
    connection_states = [ ];

    # Other options
    match_ip_sec = false;
    inherit (cfg) logging;
    create_allow_respond = false;
    match_opposite_protocol = false;
    icmp_typename = "ANY";
    icmp_v6_typename = "ANY";

    # Schedule (always on for now)
    schedule = {
      mode = "ALWAYS";
    };
  };

  # Validation checks - throw on errors
  validate =
    config:
    let
      v = config._validation;
      errors = lib.concatLists [
        (lib.optional (
          v.duplicateVlans != [ ]
        ) "Duplicate VLAN IDs: ${toString (lib.unique v.duplicateVlans)}")
        (lib.optional (v.invalidWifiRefs != [ ])
          "WiFi networks reference undefined networks: ${toString v.invalidWifiRefs}. Valid: ${toString v.networkNames}"
        )
        (lib.optional (v.invalidPolicyNetRefs != [ ])
          "Firewall policies reference undefined networks: ${toString (lib.unique v.invalidPolicyNetRefs)}. Valid: ${toString v.networkNames}"
        )
        (lib.optional (v.overlappingSubnets != [ ])
          "Overlapping subnets: ${
            lib.concatMapStringsSep ", " (p: "${p.a.name} overlaps ${p.b.name}") v.overlappingSubnets
          }"
        )
      ];
    in
    if errors != [ ] then
      throw "Validation failed:\n  - ${lib.concatStringsSep "\n  - " errors}"
    else
      true;

in
config:
assert validate config;
{
  # Convert all networks
  networks = mapAttrs networkToMongo config.networks;

  # Convert all WiFi configs
  wifi = mapAttrs (name: cfg: wifiToMongo name cfg config.networks) config.wifi;

  # Convert all firewall policies (zone-based, UniFi 10.x+)
  firewallPolicies = mapAttrs firewallPolicyToMongo config.firewall.policies;

  # Convert all firewall groups
  firewallGroups = mapAttrs firewallGroupToMongo config.firewall.groups;

  # Convert all port forwards
  portForwards = mapAttrs portForwardToMongo config.portForwards;

  # Convert all DHCP reservations
  dhcpReservations = mapAttrs dhcpReservationToMongo config.dhcpReservations;

  # Convert all AP groups
  apGroups = mapAttrs apGroupToMongo config.apGroups;

  # Convert all user groups
  userGroups = mapAttrs userGroupToMongo config.userGroups;

  # Convert all traffic rules
  trafficRules = mapAttrs trafficRuleToMongo config.trafficRules;

  # Convert all RADIUS profiles
  radiusProfiles = mapAttrs radiusProfileToMongo config.radiusProfiles;

  # Convert all port profiles
  portProfiles = mapAttrs portProfileToMongo config.portProfiles;

  # Convert all DPI groups
  dpiGroups = mapAttrs dpiGroupToMongo config.dpiGroups;

  # Convert VPN configuration
  vpn = {
    wireguard = {
      server = wireguardServerToMongo config.vpn.wireguard.server;
      peers = mapAttrs wireguardPeerToMongo config.vpn.wireguard.peers;
    };
    siteToSite = mapAttrs siteToSiteVpnToMongo config.vpn.siteToSite;
  };

  # Schema-generated conversions (auto-generated from MongoDB schema)
  scheduledTasks = fromSchema.convertCollection "scheduletask" config.scheduledTasks;
  wlanGroups = fromSchema.convertCollection "wlangroup" config.wlanGroups;
  globalSettings = fromSchema.convertCollection "setting" config.globalSettings;
  alertSettings = fromSchema.convertCollection "alert_setting" config.alertSettings;
  firewallZones = fromSchema.convertCollection "firewall_zone" config.firewallZones;
  dohServers = fromSchema.convertCollection "doh_servers" config.dohServers;
  sslInspectionProfiles = fromSchema.convertCollection "ssl_inspection_profile" config.sslInspectionProfiles;
  dashboards = fromSchema.convertCollection "dashboard" config.dashboards;
  diagnosticsConfig = fromSchema.convertCollection "diagnostics_config" config.diagnosticsConfig;

  # Metadata
  _meta = {
    inherit (config) host site;
    generatedAt = "DEPLOY_TIME";
  };
}
