# Convert Nix UniFi config to MongoDB document format
{ lib }:

let
  inherit (lib) mapAttrs mapAttrsToList filterAttrs optionalAttrs;

  # Parse subnet string "192.168.10.1/24" into components
  parseSubnet = subnet:
    let
      parts = lib.splitString "/" subnet;
      ip = builtins.elemAt parts 0;
      prefix = builtins.elemAt parts 1;
      ipParts = lib.splitString "." ip;
      baseIp = "${builtins.elemAt ipParts 0}.${builtins.elemAt ipParts 1}.${builtins.elemAt ipParts 2}";
    in {
      inherit ip prefix baseIp;
      gateway = ip;
      ipSubnet = "${ip}/${prefix}";
    };

  # Convert a network config to MongoDB networkconf document
  networkToMongo = name: cfg:
    let
      subnet = parseSubnet cfg.subnet;
    in {
      name = name;
      enabled = cfg.enable;
      purpose = cfg.purpose;
      ip_subnet = subnet.ipSubnet;

      # VLAN settings
      vlan_enabled = cfg.vlan != null;
      vlan = if cfg.vlan != null then cfg.vlan else 0;
      networkgroup = cfg.networkGroup;

      # DHCP settings
      dhcpd_enabled = cfg.dhcp.enable;
      dhcpd_start = if cfg.dhcp.start != null then cfg.dhcp.start
                    else if cfg.dhcp.enable then
                      throw "Network '${name}': dhcp.start is required when dhcp.enable = true"
                    else "";
      dhcpd_stop = if cfg.dhcp.end != null then cfg.dhcp.end
                   else if cfg.dhcp.enable then
                     throw "Network '${name}': dhcp.end is required when dhcp.enable = true"
                   else "";
      dhcpd_leasetime = cfg.dhcp.leasetime;

      # DNS settings
      dhcpd_dns_enabled = cfg.dhcp.dns != [];
      dhcpd_dns_1 = if builtins.length cfg.dhcp.dns >= 1
                    then builtins.elemAt cfg.dhcp.dns 0 else "";
      dhcpd_dns_2 = if builtins.length cfg.dhcp.dns >= 2
                    then builtins.elemAt cfg.dhcp.dns 1 else "";
      dhcpd_dns_3 = if builtins.length cfg.dhcp.dns >= 3
                    then builtins.elemAt cfg.dhcp.dns 2 else "";
      dhcpd_dns_4 = if builtins.length cfg.dhcp.dns >= 4
                    then builtins.elemAt cfg.dhcp.dns 3 else "";

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
  wifiToMongo = name: cfg: networkLookup: {
    name = cfg.ssid;
    enabled = cfg.enable;

    # Security settings
    security = cfg.security;
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
  portForwardToMongo = name: cfg: {
    name = cfg.name;
    enabled = cfg.enable;
    pfwd_interface = "wan";
    src = if cfg.srcIP != null then cfg.srcIP else "any";
    dst_port = toString cfg.srcPort;
    fwd = cfg.dstIP;
    fwd_port = toString (if cfg.dstPort != null then cfg.dstPort else cfg.srcPort);
    proto = cfg.protocol;
    log = cfg.log;
    setting_preference = "manual";
  };

  # Convert a DHCP reservation to MongoDB dhcp_option document
  dhcpReservationToMongo = name: cfg: {
    mac = cfg.mac;
    ip = cfg.ip;
    name = cfg.name;
    _network_name = cfg.network;
    setting_preference = "manual";
  };

  # Convert a firewall rule to MongoDB traffic_rule document
  firewallRuleToMongo = name: cfg: {
    description = if cfg.description != "" then cfg.description else name;
    enabled = cfg.enable;
    action = cfg.action;

    # Source/destination - will be resolved to zone IDs at deploy time
    _source_networks = if builtins.isList cfg.from then cfg.from else [ cfg.from ];
    _dest_networks = if builtins.isList cfg.to then cfg.to else [ cfg.to ];

    matching_target = "INTERNET_AND_LAN";
    target_devices = [];

    # Protocol and ports
    ip_protocol = cfg.protocol;
    dst_port = if cfg.ports != null then
               builtins.concatStringsSep "," (map toString cfg.ports)
               else "";

    # Rule ordering
    index = cfg.index;

    setting_preference = "manual";
  };

  # Validation checks - throw on errors
  validate = config:
    let
      v = config._validation;
      errors = lib.concatLists [
        (lib.optional (v.duplicateVlans != [])
          "Duplicate VLAN IDs: ${toString (lib.unique v.duplicateVlans)}")
        (lib.optional (v.invalidWifiRefs != [])
          "WiFi networks reference undefined networks: ${toString v.invalidWifiRefs}. Valid: ${toString v.networkNames}")
        (lib.optional (v.invalidFirewallRefs != [])
          "Firewall rules reference undefined networks: ${toString (lib.unique v.invalidFirewallRefs)}. Valid: ${toString v.networkNames} (or 'any')")
        (lib.optional (v.overlappingSubnets != [])
          "Overlapping subnets: ${lib.concatMapStringsSep ", " (p: "${p.a.name} overlaps ${p.b.name}") v.overlappingSubnets}")
      ];
    in
      if errors != [] then
        throw "Validation failed:\n  - ${lib.concatStringsSep "\n  - " errors}"
      else
        true;

in config: assert validate config; {
  # Convert all networks
  networks = mapAttrs networkToMongo config.networks;

  # Convert all WiFi configs
  wifi = mapAttrs (name: cfg: wifiToMongo name cfg config.networks) config.wifi;

  # Convert all firewall rules
  firewallRules = mapAttrs firewallRuleToMongo config.firewall.rules;

  # Convert all port forwards
  portForwards = mapAttrs portForwardToMongo config.portForwards;

  # Convert all DHCP reservations
  dhcpReservations = mapAttrs dhcpReservationToMongo config.dhcpReservations;

  # Metadata
  _meta = {
    host = config.host;
    site = config.site;
    generatedAt = "DEPLOY_TIME";
  };
}
