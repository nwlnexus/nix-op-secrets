# tests/vm/home.nix
# Standalone Home Manager configuration for the Ubuntu VM integration tests.
# Declares all four op-secrets secret types against the fixed test vault.
{ ... }:
{
  home.username    = "nixtest";
  home.homeDirectory = "/home/nixtest";
  home.stateVersion = "25.05";

  op-secrets = {
    enable  = true;
    serviceAccountTokenFile = "/etc/op-secrets-test-token";

    secrets = {
      # 1. Field — plain op:// reference
      test-field = {
        type   = "field";
        source = "op://nix-op-secrets-test/nix-op-secrets-test-field/password";
        dest   = "/home/nixtest/.local/secrets/field.txt";
      };

      # 2. SSH key — writes private + public key pair
      test-ssh = {
        type           = "sshKey";
        source         = "op://nix-op-secrets-test/nix-op-secrets-test-ssh";
        dest           = "/home/nixtest/.ssh/test-vm-key";
        writePublicKey = true;
      };

      # 3. Document — binary/text blob from 1Password
      test-doc = {
        type  = "document";
        vault = "nix-op-secrets-test";
        item  = "nix-op-secrets-test-doc";
        dest  = "/home/nixtest/.local/secrets/doc.txt";
      };

      # 4. Template — op inject using committed fixture.
      # When `template` is set, it takes precedence over `type` and the module
      # invokes `op inject` instead of `op read`.
      test-template = {
        template = ./fixtures/infra.env.tpl;
        dest     = "/home/nixtest/.local/secrets/infra.env";
      };
    };
  };
}
