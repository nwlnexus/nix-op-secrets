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
      description = lib.mdDoc ''
        1Password sign-in address (e.g. `my.1password.com`). `null` uses the most
        recently used account. Overridden at runtime by the `OP_ACCOUNT` env var.
      '';
      example = "my.1password.com";
    };

    serviceAccountTokenFile = lib.mkOption {
      type    = lib.types.nullOr lib.types.str;
      default = null;
      description = lib.mdDoc ''
        Path to a file containing a 1Password service account token. For headless
        hosts without a desktop app. Overridden by `OP_SERVICE_ACCOUNT_TOKEN` env var.
      '';
      example = "/run/secrets/op-token";
    };

    secrets = lib.mkOption {
      type    = lib.types.attrsOf secretSpec;
      default = {};
      description = lib.mdDoc ''
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
    };

    home.activation.op-secrets = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      # String-interpolating the derivation yields its executable store path
      ${mkActivation { inherit pkgs lib cfg; }}
    '';
  };
}
