# tests/vm/configuration.nix
# Home Manager configuration for VM integration tests.
# Declares all four op-secrets secret types against the fixed test vault.
{ ... }:
{
  # Home Manager config for nixtest user (wired via flake.nix)
  home-manager.users.nixtest = {
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

        # 4. Template — op inject using committed fixture
        test-template = {
          type     = "template";
          template = ./fixtures/infra.env.tpl;
          dest     = "/home/nixtest/.local/secrets/infra.env";
        };
      };
    };
  };
}
