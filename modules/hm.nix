{ lib, pkgs, config, ... }:
let
  cfg        = config.op-secrets;
  secretSpec = import ../lib/options.nix  { inherit lib; };
  validate   = import ../lib/validate.nix;
  mkActivation = import ../lib/mk-activation.nix;
in {
  options.op-secrets = {
    enable = lib.mkEnableOption "1Password secrets activation";

    account = lib.mkOption {
      type    = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        1Password sign-in address (e.g. `my.1password.com`). `null` uses the most
        recently used account. Overridden at runtime by the `OP_ACCOUNT` env var.
      '';
      example = "my.1password.com";
    };

    serviceAccountTokenFile = lib.mkOption {
      type    = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Path to a file containing a 1Password service account token. For headless
        hosts without a desktop app. Overridden by `OP_SERVICE_ACCOUNT_TOKEN` env var.
        Mutually exclusive with `connectHost` / `connectTokenFile`.
      '';
      example = "/run/secrets/op-token";
    };

    connectHost = lib.mkOption {
      type    = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        URL of a 1Password Connect server (e.g. `https://connect.example.com:8080`).
        Must be set together with `connectTokenFile`. Mutually exclusive with
        `serviceAccountTokenFile`. Sets `OP_CONNECT_HOST` at activation time.
        Overridden by the `OP_CONNECT_HOST` env var.
      '';
      example = "https://op-connect.internal:8080";
    };

    connectTokenFile = lib.mkOption {
      type    = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Path to a file containing the 1Password Connect API token. Must be set
        together with `connectHost`. Mutually exclusive with `serviceAccountTokenFile`.
        Sets `OP_CONNECT_TOKEN` at activation time. Overridden by `OP_CONNECT_TOKEN`
        env var.
      '';
      example = "/run/secrets/op-connect-token";
    };

    secrets = lib.mkOption {
      type    = lib.types.attrsOf secretSpec;
      default = {};
      description = ''
        Named secret declarations. Each entry specifies a 1Password source and a
        destination path on disk.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = validate {
      inherit lib;
      secrets    = cfg.secrets;
      moduleName = "op-secrets (hm)";
    } ++ [
      {
        assertion = !(cfg.serviceAccountTokenFile != null && (cfg.connectHost != null || cfg.connectTokenFile != null));
        message   = "op-secrets (hm): 'serviceAccountTokenFile' and connect options ('connectHost'/'connectTokenFile') are mutually exclusive";
      }
      {
        assertion = (cfg.connectHost == null) == (cfg.connectTokenFile == null);
        message   = "op-secrets (hm): 'connectHost' and 'connectTokenFile' must both be set or both be null";
      }
    ];

    home.activation.op-secrets = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      # String-interpolating the derivation yields its executable store path
      ${mkActivation { inherit pkgs lib cfg; }}
    '';
  };
}
