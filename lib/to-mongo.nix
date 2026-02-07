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
      networkgroup = "LAN";

      # DHCP settings
      dhcpd_enabled = cfg.dhcp.enable;
      dhcpd_start = if cfg.dhcp.start != null then cfg.dhcp.start
                    else "${subnet.baseIp}.6";
      dhcpd_stop = if cfg.dhcp.end != null then cfg.dhcp.end
                   else "${subnet.baseIp}.254";
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

    # Other defaults
    bss_transition = true;
    fast_roaming_enabled = false;
    mac_filter_enabled = false;
    mac_filter_policy = "allow";
    no2ghz_oui = false;
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

in config: {
  # Convert all networks
  networks = mapAttrs networkToMongo config.networks;

  # Convert all WiFi configs
  wifi = mapAttrs (name: cfg: wifiToMongo name cfg config.networks) config.wifi;

  # Convert all firewall rules
  firewallRules = mapAttrs firewallRuleToMongo config.firewall.rules;

  # Metadata
  _meta = {
    host = config.host;
    site = config.site;
    generatedAt = "DEPLOY_TIME";
  };
}
