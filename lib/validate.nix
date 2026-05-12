# lib/validate.nix
# Returns a list of Nix module assertions for all declared secrets.
# Usage: assertions = (import ../lib/validate.nix) { inherit lib secrets; };
{ lib, secrets, moduleName ? "op-secrets" }:
lib.concatMap
  (name:
    let
      cfg = secrets.${name};
      pfx = "${moduleName}: secret '${name}'";
    in [
      {
        assertion = !(cfg.source != null && cfg.template != null);
        message   = "${pfx}: 'source' and 'template' are mutually exclusive";
      }
      {
        assertion = cfg.type == "document"
          || cfg.source != null
          || cfg.template != null;
        message   = "${pfx}: 'source' or 'template' is required for type '${cfg.type}'";
      }
      {
        assertion = cfg.type != "document"
          || (cfg.vault != null && cfg.item != null);
        message   = "${pfx}: 'vault' and 'item' are required for type 'document'";
      }
      {
        assertion = cfg.type != "document" || cfg.source == null;
        message   = "${pfx}: 'source' must not be set for type 'document'; use 'vault' and 'item'";
      }
      {
        # sshKey source must be op://vault/item — no third path component (field segment)
        assertion =
          cfg.type != "sshKey"
          || cfg.source == null
          || (let parts = lib.splitString "/" (lib.removePrefix "op://" cfg.source);
              in builtins.length parts == 2);
        message = "${pfx}: 'source' for sshKey must be 'op://vault/item' (no field segment)";
      }
      {
        assertion = !cfg.writePublicKey || cfg.type == "sshKey";
        message   = "${pfx}: 'writePublicKey' is only valid for type 'sshKey'";
      }
      {
        assertion = lib.hasPrefix "/" cfg.dest;
        message   = "${pfx}: 'dest' must be an absolute path (got '${cfg.dest}')";
      }
    ])
  (lib.attrNames secrets)
