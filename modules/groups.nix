# Group configuration options (AP, User, DPI groups)
{ lib, ... }:

let
  inherit (lib) mkOption types;
in
{
  # AP group options (assign SSIDs to specific access points)
  apGroupOpts =
    { name, ... }:
    {
      options = {
        name = mkOption {
          type = types.str;
          default = name;
          description = "AP group name";
        };

        devices = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "List of AP MAC addresses in this group";
          example = [ "00:11:22:33:44:55" ];
        };
      };
    };

  # User group options (bandwidth limits, rate limiting)
  userGroupOpts =
    { name, ... }:
    {
      options = {
        name = mkOption {
          type = types.str;
          default = name;
          description = "User group name";
        };

        downloadLimit = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = "Download bandwidth limit in kbps (null = unlimited)";
          example = 10000;
        };

        uploadLimit = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = "Upload bandwidth limit in kbps (null = unlimited)";
          example = 5000;
        };
      };
    };

  # DPI group options (for app/category blocking)
  dpiGroupOpts =
    { name, ... }:
    {
      options = {
        name = mkOption {
          type = types.str;
          default = name;
          description = "DPI group name";
        };

        # App IDs can be discovered from the device MongoDB dpiapp collection
        # or from the UniFi DPI documentation
        appIds = mkOption {
          type = types.listOf types.int;
          default = [ ];
          description = "List of DPI application IDs to include in this group";
          example = [
            5
            24
            123
          ];
        };

        # Category-based selection (more user-friendly)
        categories = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "List of DPI categories (resolved to app IDs at deploy time)";
          example = [
            "Social"
            "Streaming"
            "Gaming"
          ];
        };
      };
    };
}
