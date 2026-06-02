{ lib, pkgs, config, ... }:
let
  cfg        = config.op-secrets;
  secretSpec = import ../lib/options.nix  { inherit lib; };
  validate   = import ../lib/validate.nix;
  mkActivation = import ../lib/mk-activation.nix;
in {
  options.op-secrets = {
    enable = lib.mkEnableOption "1Password secrets activation (system-level)";

    account = lib.mkOption {
      type    = lib.types.nullOr lib.types.str;
      default = null;
      description = lib.mdDoc ''
        1Password sign-in address. Overridden by `OP_ACCOUNT` env var at runtime.
      '';
      example = "my.1password.com";
    };

    serviceAccountTokenFile = lib.mkOption {
      type    = lib.types.nullOr lib.types.str;
      default = null;
      description = lib.mdDoc ''
        Path to a file containing a 1Password service account token.
        Mutually exclusive with `connectHost` / `connectTokenFile`.
      '';
    };

    connectHost = lib.mkOption {
      type    = lib.types.nullOr lib.types.str;
      default = null;
      description = lib.mdDoc ''
        URL of a 1Password Connect server (e.g. `https://connect.example.com:8080`).
        Must be set together with `connectTokenFile`. Mutually exclusive with
        `serviceAccountTokenFile`. Sets `OP_CONNECT_HOST` at activation time.
      '';
      example = "https://op-connect.internal:8080";
    };

    connectTokenFile = lib.mkOption {
      type    = lib.types.nullOr lib.types.str;
      default = null;
      description = lib.mdDoc ''
        Path to a file containing the 1Password Connect API token. Must be set
        together with `connectHost`. Mutually exclusive with `serviceAccountTokenFile`.
        Sets `OP_CONNECT_TOKEN` at activation time.
      '';
      example = "/run/secrets/op-connect-token";
    };

    user = lib.mkOption {
      type    = lib.types.str;
      description = lib.mdDoc ''
        The macOS user to run `op` as and to own the written files. nix-darwin system
        activation runs as root — this user is substituted into all `op` calls via
        `sudo -u`.
      '';
      example = "alice";
    };

    group = lib.mkOption {
      type    = lib.types.str;
      default = "staff";
      description = lib.mdDoc "Group owner for written files. Defaults to `staff`.";
    };

    secrets = lib.mkOption {
      type    = lib.types.attrsOf secretSpec;
      default = {};
      description = lib.mdDoc "Named secret declarations.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = validate {
      inherit lib;
      secrets    = cfg.secrets;
      moduleName = "op-secrets (darwin)";
    } ++ [
      {
        assertion = !(cfg.serviceAccountTokenFile != null && (cfg.connectHost != null || cfg.connectTokenFile != null));
        message   = "op-secrets (darwin): 'serviceAccountTokenFile' and connect options ('connectHost'/'connectTokenFile') are mutually exclusive";
      }
      {
        assertion = (cfg.connectHost == null) == (cfg.connectTokenFile == null);
        message   = "op-secrets (darwin): 'connectHost' and 'connectTokenFile' must both be set or both be null";
      }
    ];

    system.activationScripts.op-secrets.text = ''
      echo "op-secrets: fetching secrets for user ${cfg.user}"
      ${mkActivation { inherit pkgs lib cfg; isSystemActivation = true; }}
    '';
  };
}
