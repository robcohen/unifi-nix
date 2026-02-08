# RADIUS profile options for WPA-Enterprise
{ lib, secretType }:

let
  inherit (lib) mkOption types;
in
{
  options =
    { name, ... }:
    {
      options = {
        name = mkOption {
          type = types.str;
          default = name;
          description = "Radius profile name";
        };

        authServers = mkOption {
          type = types.listOf (
            types.submodule {
              options = {
                ip = mkOption {
                  type = types.str;
                  description = "Radius server IP address";
                };
                port = mkOption {
                  type = types.int;
                  default = 1812;
                  description = "Radius server port";
                };
                secret = mkOption {
                  type = secretType;
                  description = "Shared secret for Radius server";
                };
              };
            }
          );
          default = [ ];
          description = "Authentication servers";
        };

        acctServers = mkOption {
          type = types.listOf (
            types.submodule {
              options = {
                ip = mkOption {
                  type = types.str;
                  description = "Accounting server IP address";
                };
                port = mkOption {
                  type = types.int;
                  default = 1813;
                  description = "Accounting server port";
                };
                secret = mkOption {
                  type = secretType;
                  description = "Shared secret for accounting server";
                };
              };
            }
          );
          default = [ ];
          description = "Accounting servers (optional)";
        };
      };
    };
}
