# NixOS module for unifi-nix
# Provides systemd service for automated UniFi configuration sync
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.unifi-nix;
  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    types
    ;

  # Import the unifi configuration module
  unifiModule = import ./module.nix;
in
{
  options.services.unifi-nix = {
    enable = mkEnableOption "unifi-nix automatic configuration sync";

    config = mkOption {
      type = types.attrs;
      description = ''
        UniFi configuration (same structure as module.nix).
        See the unifi-nix documentation for available options.
      '';
      example = {
        unifi = {
          host = "192.168.1.1";
          networks = {
            Default = {
              subnet = "192.168.1.1/24";
              dhcp = {
                enable = true;
                start = "192.168.1.100";
                end = "192.168.1.254";
              };
            };
          };
          wifi = { };
        };
      };
    };

    interval = mkOption {
      type = types.str;
      default = "hourly";
      description = ''
        How often to run the drift detection and optional sync.
        Uses systemd calendar format (e.g., "hourly", "daily", "*:0/15" for every 15 min).
      '';
    };

    autoSync = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to automatically apply configuration when drift is detected.
        If false, only drift detection runs and alerts are logged.
      '';
    };

    sshKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to SSH private key for connecting to UDM.
        If null, the default SSH key is used.
      '';
    };

    secretsDirectory = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Directory containing secret files (WiFi passwords, etc.).
        Files should be named by secret path (e.g., wifi/main).
      '';
    };

    alertCommand = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Command to run when drift is detected.
        The drift summary JSON is passed via stdin.
      '';
      example = ''
        ${pkgs.curl}/bin/curl -X POST -d @- https://ntfy.example.com/unifi-drift
      '';
    };
  };

  config = mkIf cfg.enable (
    let
      # Evaluate the UniFi configuration
      evaluated =
        (lib.evalModules {
          modules = [
            unifiModule
            cfg.config
          ];
        }).config;

      toMongo = import ./lib/to-mongo.nix { inherit lib; };
      configJson = pkgs.writeText "unifi-config.json" (builtins.toJSON (toMongo evaluated.unifi));

      # Build the tools
      deploy = pkgs.writeShellApplication {
        name = "unifi-deploy";
        runtimeInputs = with pkgs; [
          jq
          openssh
          coreutils
          diffutils
        ];
        text = builtins.readFile ./scripts/deploy.sh;
        excludeShellChecks = [
          "SC2029"
          "SC2154"
        ];
      };

      driftDetect = pkgs.writeShellApplication {
        name = "unifi-drift-detect";
        runtimeInputs = with pkgs; [
          jq
          openssh
          coreutils
        ];
        text = builtins.readFile ./scripts/drift-detect.sh;
        excludeShellChecks = [ "SC2029" ];
      };

      inherit (evaluated.unifi) host;

      syncScript = pkgs.writeShellScript "unifi-nix-sync" ''
        set -euo pipefail

        export SSH_USER=root
        ${lib.optionalString (cfg.sshKeyFile != null) ''
          export SSH_AUTH_SOCK=""
          export SSH_OPTS="-i ${cfg.sshKeyFile}"
        ''}
        ${lib.optionalString (cfg.secretsDirectory != null) ''
          export UNIFI_SECRETS_DIR="${cfg.secretsDirectory}"
        ''}

        echo "Running unifi-nix drift detection..."

        # Run drift detection
        if OUTPUT_FORMAT=json ${driftDetect}/bin/unifi-drift-detect ${configJson} ${host} > /tmp/drift-result.json 2>&1; then
          echo "No drift detected"
          exit 0
        fi

        echo "Drift detected!"
        cat /tmp/drift-result.json

        ${lib.optionalString (cfg.alertCommand != null) ''
          echo "Sending alert..."
          cat /tmp/drift-result.json | ${cfg.alertCommand}
        ''}

        ${lib.optionalString cfg.autoSync ''
          echo "Auto-sync enabled, applying configuration..."
          AUTO_CONFIRM=true ${deploy}/bin/unifi-deploy ${configJson} ${host}
        ''}
      '';
    in
    {
      systemd.services.unifi-nix = {
        description = "UniFi configuration sync";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];

        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${syncScript}";
          User = "root"; # Needed for SSH key access

          # Hardening
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = "read-only";
          PrivateTmp = true;
        };
      };

      systemd.timers.unifi-nix = {
        description = "UniFi configuration sync timer";
        wantedBy = [ "timers.target" ];

        timerConfig = {
          OnCalendar = cfg.interval;
          Persistent = true;
          RandomizedDelaySec = "5m";
        };
      };
    }
  );
}
