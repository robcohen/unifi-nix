# WiFi network configuration options
{
  lib,
  schema,
  secretType,
}:

let
  inherit (lib) mkOption types literalExpression;
in
{
  options = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Whether this WiFi network is enabled";
    };

    ssid = mkOption {
      type = types.str;
      description = "WiFi network name (SSID)";
      example = "MyNetwork";
    };

    passphrase = mkOption {
      type = secretType;
      description = "WiFi password (can be secret reference)";
      example = literalExpression ''{ _secret = "wifi/main"; }'';
    };

    network = mkOption {
      type = types.str;
      description = "Name of the network (VLAN) this WiFi should use";
      example = "iot";
    };

    hidden = mkOption {
      type = types.bool;
      default = false;
      description = "Hide SSID from broadcast";
    };

    security = mkOption {
      type = types.enum schema.wifiSecurity;
      default = "wpapsk";
      description = "Security mode (values from device schema)";
    };

    wpa3 = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable WPA3 support";
      };

      transition = mkOption {
        type = types.bool;
        default = true;
        description = "WPA3 transition mode (WPA2+WPA3 for compatibility)";
      };
    };

    pmf = mkOption {
      type = types.enum schema.wifiPmfModes;
      default = "optional";
      description = "Protected Management Frames mode (values from device schema)";
    };

    clientIsolation = mkOption {
      type = types.bool;
      default = false;
      description = "Isolate wireless clients from each other";
    };

    multicastEnhance = mkOption {
      type = types.bool;
      default = false;
      description = "Convert multicast to unicast for streaming";
    };

    bands = mkOption {
      type = types.listOf (types.enum schema.wifiBands);
      default = [
        "2g"
        "5g"
      ];
      description = "WiFi bands to broadcast on (values from device schema)";
    };

    minRate = {
      "2g" = mkOption {
        type = types.int;
        default = 1000;
        description = "Minimum data rate for 2.4GHz in kbps";
      };
      "5g" = mkOption {
        type = types.int;
        default = 6000;
        description = "Minimum data rate for 5GHz in kbps";
      };
    };

    guestMode = mkOption {
      type = types.bool;
      default = false;
      description = "Enable guest mode (captive portal ready)";
    };

    fastRoaming = mkOption {
      type = types.bool;
      default = false;
      description = "Enable 802.11r Fast BSS Transition for faster roaming";
    };

    bssTransition = mkOption {
      type = types.bool;
      default = true;
      description = "Enable 802.11v BSS Transition Management";
    };

    macFilter = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable MAC address filtering";
      };

      policy = mkOption {
        type = types.enum schema.wifiMacFilterPolicies;
        default = "allow";
        description = "MAC filter policy (values from device schema)";
      };

      list = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "List of MAC addresses to filter";
        example = [
          "00:11:22:33:44:55"
          "AA:BB:CC:DD:EE:FF"
        ];
      };
    };

    apGroups = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "AP groups to broadcast this SSID (empty = all)";
    };
  };
}
