# lib/options.nix
{ lib }:
lib.types.submodule {
  options = {
    type = lib.mkOption {
      type    = lib.types.enum [ "field" "document" "sshKey" ];
      default = "field";
      description = lib.mdDoc ''
        The 1Password item type. Determines which `op` CLI command fetches the secret.
        - `field`: reads a single text/concealed field via `op read`
        - `document`: retrieves a file stored as a 1Password Document via `op document get`
        - `sshKey`: reads an SSH Key item; enforces `0600` on the private key
        Note: if `template` is also set, `template` takes precedence over `type`.
      '';
      example = "sshKey";
    };

    source = lib.mkOption {
      type    = lib.types.nullOr lib.types.str;
      default = null;
      description = lib.mdDoc ''
        1Password URI for the secret. Format depends on type:
        - `field`: `op://vault/item/field`
        - `sshKey`: `op://vault/item` — no field segment; the module derives
          `/private key` and `/public key` automatically.
        - `document`: not used — set `vault` and `item` instead.
        Mutually exclusive with `template`.
      '';
      example = "op://Personal/GitHub SSH Key";
    };

    vault = lib.mkOption {
      type    = lib.types.nullOr lib.types.str;
      default = null;
      description = lib.mdDoc "1Password vault name. Required for `document` type only.";
      example = "Work";
    };

    item = lib.mkOption {
      type    = lib.types.nullOr lib.types.str;
      default = null;
      description = lib.mdDoc "1Password item name. Required for `document` type only.";
      example = "Corp Root CA";
    };

    template = lib.mkOption {
      type    = lib.types.nullOr lib.types.path;
      default = null;
      description = lib.mdDoc ''
        Nix store path to an `op inject` template file containing `op://` references.
        When set, `op inject` is used instead of the `type` dispatch. Mutually exclusive
        with `source`. Templates must contain only `op://` URIs — the Nix store is
        world-readable, so never embed literal secret values in template files.
      '';
      example = ./secrets/infra.env.tpl;
    };

    dest = lib.mkOption {
      type    = lib.types.str;
      description = lib.mdDoc ''
        Absolute path where the secret will be written. Must start with `/`.
        Do not use `~/` — use `config.home.homeDirectory` in Home Manager configs.
      '';
      example = "/Users/me/.ssh/github_ed25519";
    };

    mode = lib.mkOption {
      type    = lib.types.str;
      default = "0600";
      description = lib.mdDoc ''
        File permission mode (chmod format). Ignored for the private key of `sshKey`
        type — that is always forced to `0600`.
      '';
      example = "0644";
    };

    writePublicKey = lib.mkOption {
      type    = lib.types.bool;
      default = false;
      description = lib.mdDoc ''
        `sshKey` type only. When true, also writes the public key to `dest + ".pub"`
        at mode `0644`. The public key is in `authorized_keys` format.
      '';
      example = true;
    };
  };
}
