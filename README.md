# nix-op-secrets

Nix flake modules for writing [1Password](https://1password.com) secrets to disk
at activation time. Works with nix-darwin (macOS) and Home Manager (macOS + Linux).

## Requirements

- `nixpkgs.config.allowUnfree = true` — required for `_1password-cli`
- [1Password CLI v2](https://developer.1password.com/docs/cli) installed (provided
  automatically by this flake's `default` package if you add it to your packages)

## Quick Install

```nix
# flake.nix
inputs.op-secrets.url = "github:nwlnexus/nix-op-secrets";

# In your Home Manager config:
imports = [ inputs.op-secrets.hmModules.default ];
```

## Platform Support

| Module | macOS | Linux |
|--------|-------|-------|
| `hmModules.default` | ✓ | ✓ |
| `darwinModules.default` | ✓ | — |

## Auth

Activation uses `op` CLI with this precedence:

1. `OP_SERVICE_ACCOUNT_TOKEN` in environment → used directly
2. `serviceAccountTokenFile` option → token read from file
3. `op whoami` succeeds → already authenticated (app agent or existing session)
4. Fallback → `op signin` interactively (requires a TTY; system activation exits immediately instead)

For headless Linux hosts: set `OP_SERVICE_ACCOUNT_TOKEN` or `serviceAccountTokenFile`.

## Usage

```nix
op-secrets = {
  enable  = true;
  account = "my.1password.com";  # optional for single-account users

  secrets = {
    # SSH Key item (enforces 0600, optionally writes .pub in authorized_keys format)
    "github-ssh" = {
      type           = "sshKey";
      source         = "op://Personal/GitHub SSH Key";   # no field segment
      dest           = "${config.home.homeDirectory}/.ssh/github_ed25519";
      writePublicKey = true;
    };

    # Single concealed/text field
    "stripe-key" = {
      type   = "field";
      source = "op://Work/Stripe/secret key";
      dest   = "${config.home.homeDirectory}/.config/stripe/key";
    };

    # Multi-field .env via op inject template
    "infra-env" = {
      template = ./secrets/infra.env.tpl;  # must contain only op:// refs
      dest     = "${config.home.homeDirectory}/projects/infra/.env";
    };

    # File stored as a 1Password Document item
    "corp-cert" = {
      type  = "document";
      vault = "Work";
      item  = "Corp Root CA";
      dest  = "${config.home.homeDirectory}/.local/share/ca/corp.pem";
      mode  = "0644";
    };
  };
};
```

## Options Reference

See the [generated options reference](https://nwlnexus.github.io/nix-op-secrets/).

## Known Limitations

- Files written during a partial first run (before any successful run) are not tracked in
  the manifest and must be manually removed.
- Interactive `op signin` requires a TTY — use a service account token for scripts/CI.
  System-level activation (nix-darwin) always requires a service account token.
- Templates stored in the Nix store are world-readable; they must contain only `op://`
  URI references, never literal secret values.
