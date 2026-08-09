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

| Module                  | macOS | Linux |
| ----------------------- | ----- | ----- |
| `hmModules.default`     | ✓     | ✓     |
| `darwinModules.default` | ✓     | —     |

## Auth

Activation uses `op` CLI with this precedence (module-level):

1. `OP_SERVICE_ACCOUNT_TOKEN` in environment → used directly
2. `serviceAccountTokenFile` option → token read from file
3. 1Password Connect credentials → `OP_CONNECT_HOST` + `OP_CONNECT_TOKEN`, or
   `connectHost` + `connectTokenFile`
4. `op whoami` succeeds → already authenticated (app agent or existing session)
5. Per-secret auth overrides → each secret supplies its own account/token source
6. Fallback → `op signin` interactively (requires a TTY; system activation
   exits immediately instead)

For headless hosts: use a service-account token or Connect credentials. System
activation (`darwinModules.default`) cannot fall back to interactive signin.

### Connect auth

Use Connect when a self-hosted 1Password Connect server should serve activation
requests instead of a service-account token:

```nix
op-secrets = {
  enable = true;

  # Both are required, and they are mutually exclusive with
  # serviceAccountTokenFile.
  connectHost = "https://op-connect.internal:8080";
  connectTokenFile = "/run/secrets/op-connect-token";

  secrets = {
    "infra-env" = {
      template = ./secrets/infra.env.tpl;
      dest = "${config.home.homeDirectory}/projects/infra/.env";
    };
  };
};
```

Runtime environment variables override the module values:

```bash
OP_CONNECT_HOST=https://op-connect.internal:8080
OP_CONNECT_TOKEN=...
```

`OP_CONNECT_HOST` and `OP_CONNECT_TOKEN` are resolved independently, so one half
may come from the environment while the other comes from module config. When
service-account auth wins, activation unsets Connect env vars before invoking
`op`; when Connect wins, activation unsets `OP_SERVICE_ACCOUNT_TOKEN`. This
prevents the `op` CLI from seeing two auth modes at once.

`serviceAccountTokenFile` is mutually exclusive with `connectHost` /
`connectTokenFile`, and `connectHost` and `connectTokenFile` must be set
together.

### Multi-account configs

Each secret may carry its own `account` and/or `serviceAccountTokenCommand`
override (see [Usage](#usage) and the [options reference](#options-reference)),
letting a single `op-secrets` block pull from more than one 1Password account.

When a secret declares its own `account` *without* a matching
`serviceAccountTokenCommand`, the module-level service-account token is
explicitly dropped for that secret's fetch — tokens are account-scoped and the
module token would be invalid against a different account. The fetch falls
back to whatever interactive `op` session exists for the per-secret account
(typically provided by the 1Password desktop app's CLI integration).

For fully autonomous runs (no desktop session, no TTY), keep every secret on
the module-level account so the module-level token applies to all of them, or
supply a per-secret `serviceAccountTokenCommand` for each off-account secret.

## Usage

```nix
op-secrets = {
  enable  = true;
  account = "my.1password.com";  # optional for single-account users

  # Optional headless auth. Use either service-account auth:
  serviceAccountTokenFile = "/run/secrets/op-token";
  # ...or Connect auth:
  # connectHost = "https://op-connect.internal:8080";
  # connectTokenFile = "/run/secrets/op-connect-token";

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

Multi-account example:

```nix
op-secrets = {
  enable = true;
  account = "personal.1password.com";
  serviceAccountTokenFile = "/run/secrets/op-personal-token";

  secrets = {
    "personal-key" = {
      type = "field";
      source = "op://Private/GitHub/token";
      dest = "${config.home.homeDirectory}/.config/github/token";
    };

    "work-key" = {
      type = "field";
      account = "work.1password.com";
      serviceAccountTokenCommand = "cat /run/secrets/op-work-token";
      source = "op://Employee/API/credential";
      dest = "${config.home.homeDirectory}/.config/work/api-token";
    };
  };
};
```

When any secret declares `account` or `serviceAccountTokenCommand`, the
module-level auth probe becomes a soft check because per-secret auth will be
applied during each fetch. Per-secret overrides affect `OP_ARGS` and
`OP_SERVICE_ACCOUNT_TOKEN`; they do not swap Connect credentials per secret, so
use service-account token commands for autonomous multi-account fetches.

## Options Reference

See the [generated options reference](https://nwlnexus.github.io/nix-op-secrets/).

## Testing

Two test layers — start with the fast one. The VM test is opt-in for
real-cloud regressions only.

### Fast hermetic test (`nix flake check`)

Runs in ~5 s on any platform with Nix. Uses a mocked `op` binary; no
1Password account, vault, or VM required. Exercises the actual activation
script the module emits against all four secret types, with idempotent
re-run and orphan-removal phases.

```bash
nix flake check
# or, just the integration check:
nix build .#checks.<system>.integration --no-link
```

This is the test loop for any change to `lib/`, `modules/`, or the
activation script. It runs in CI on every PR.

### VM integration test (opt-in real-API smoke)

Drives a Parallels Ubuntu VM through cloud-init autoinstall, then runs
`home-manager switch` against a real 1Password service account. Catches
regressions in the real `op` CLI / cloud round-trip / activation
lifecycle that the hermetic test can't see.

```bash
# Prerequisites: macOS + Parallels Pro/Business, Nix on host, op CLI v2+,
# a service account token in .env (see .env.sample).
./scripts/test-vm.sh
```

- **Linux / Home-Manager** path (automated): see `scripts/` and `tests/vm/`.
- **macOS / nix-darwin** path (manual): [`docs/vm-testing-macos.md`](docs/vm-testing-macos.md).

First base-VM build takes ~20 min; subsequent cycles are ~3–5 min via
linked clones. Macs only — for non-macOS contributors the fast test above
is the supported flow.

## Known Limitations

- Files written during a partial first run (before any successful run) are not
  tracked in the manifest and must be manually removed.
- Interactive `op signin` requires a TTY — use a service-account token or
  Connect credentials for scripts/CI. System-level activation (nix-darwin)
  requires one of those non-interactive auth methods unless every fetch supplies
  per-secret auth.
- Templates stored in the Nix store are world-readable; they must contain only `op://`
  URI references, never literal secret values.
