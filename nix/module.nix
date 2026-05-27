{ config, lib, pkgs, ... }:

let
  cfg = config.services.dust;
in
{
  options.services.dust = {
    enable = lib.mkEnableOption "the Dust distributed file system daemon";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.dust or (throw "services.dust.package is not set and pkgs.dust is unavailable. Add the Dust flake's `nixosModules.default` and overlay, or set `services.dust.package` explicitly.");
      description = "The Dust daemon package to run.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "dust";
      description = "User the daemon runs as.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "dust";
      description = "Group the daemon runs as.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/dust";
      description = "Root directory for persistent state (mapped to DUST_DATA_DIR).";
    };

    logDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/log/dust";
      description = "Directory the daemon writes logs into.";
    };

    apiBind = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address the local HTTP API binds to (DUST_API_BIND).";
    };

    apiPort = lib.mkOption {
      type = lib.types.port;
      default = 4884;
      description = "TCP port for the local HTTP API (DUST_API_PORT).";
    };

    nodeName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "dust@name";
      description = ''
        Optional override for the daemon's Erlang RELEASE_NODE. When null
        (the default), the node's name is sourced from
        `''${dataDir}/node_name` — written by `dustctl init` — via the
        release boot script. Set this only to pin the node atom
        statically, e.g. for a stateless deployment that doesn't run
        `dustctl init`.
      '';
    };

    cookieFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a file containing the Erlang distribution cookie. If set,
        its contents are loaded into RELEASE_COOKIE at start. Keep this
        out of the Nix store (e.g. via `sops-nix`) — anything readable by
        the cookie holder can connect to the BEAM node.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Optional environment file (systemd `EnvironmentFile=` format) for
        secrets like TS_AUTHKEY. Loaded before the daemon starts.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the API port in the firewall. Off by default — Dust expects API traffic over loopback or Tailscale only.";
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { TS_TAGS = "tag:dust-node"; };
      description = "Additional environment variables to set on the daemon unit.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.dataDir;
      description = "Dust daemon";
    };

    users.groups.${cfg.group} = { };

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0750 ${cfg.user} ${cfg.group} - -"
      "d '${cfg.dataDir}/tmp' 0750 ${cfg.user} ${cfg.group} - -"
      "d '${cfg.logDir}'  0750 ${cfg.user} ${cfg.group} - -"
    ];

    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts = [ cfg.apiPort ];
    };

    systemd.services.dust = {
      description = "Dust distributed file system daemon";
      documentation = [ "https://github.com/AndrewBoessen/dust" ];
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = {
        HOME = cfg.dataDir;
        DUST_DATA_DIR = cfg.dataDir;
        DUST_API_BIND = cfg.apiBind;
        DUST_API_PORT = toString cfg.apiPort;
        RELEASE_TMP = "${cfg.dataDir}/tmp";
      }
      // lib.optionalAttrs (cfg.nodeName != null) { RELEASE_NODE = cfg.nodeName; }
      // cfg.extraEnvironment;

      serviceConfig = {
        Type = "exec";
        User = cfg.user;
        Group = cfg.group;
        ExecStart = "${cfg.package}/bin/dust start";
        ExecStop = "${cfg.package}/bin/dust stop";
        Restart = "on-failure";
        RestartSec = 5;
        LimitNOFILE = 65536;

        StateDirectory = lib.mkIf (cfg.dataDir == "/var/lib/dust") "dust";
        LogsDirectory = lib.mkIf (cfg.logDir == "/var/log/dust") "dust";

        EnvironmentFile = lib.mkIf (cfg.environmentFile != null) cfg.environmentFile;

        # If a cookie file is configured, load it as a credential and
        # export RELEASE_COOKIE before exec'ing the release script.
        LoadCredential =
          lib.mkIf (cfg.cookieFile != null) [ "cookie:${toString cfg.cookieFile}" ];
        ExecStartPre = lib.mkIf (cfg.cookieFile != null) [
          ''${pkgs.runtimeShell} -c 'export RELEASE_COOKIE="$(cat $CREDENTIALS_DIRECTORY/cookie)"' ''
        ];

        # Hardening. `MemoryDenyWriteExecute` MUST be false — the BEAM JIT
        # and Rust NIFs map W+X pages during code loading.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = false;
        ReadWritePaths = [ cfg.dataDir cfg.logDir ];
      };
    };
  };
}
