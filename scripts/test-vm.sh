#!/usr/bin/env bash
# scripts/test-vm.sh
# Entry point for VM-based integration tests.
# Usage: ./scripts/test-vm.sh
#
# Prerequisites:
#   - Apple Silicon Mac with nix.linux-builder.enable = true in nix-darwin config
#   - Parallels Desktop ≥26 with prlctl on PATH
#   - 1Password CLI (op) on PATH
#   - .env at repo root containing OP_SERVICE_ACCOUNT_TOKEN
#   - The "nix-op-secrets-test" vault must exist in your 1Password account
#     with your service account granted access to it
set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
# When running from a worktree, also check the main repo root for .env
MAIN_ROOT="$(dirname "$(git -C "$(dirname "$0")" rev-parse --git-common-dir)")"
ENV_FILE="$REPO_ROOT/.env"
if [[ ! -f "$ENV_FILE" && -f "$MAIN_ROOT/.env" ]]; then
  ENV_FILE="$MAIN_ROOT/.env"
fi

# ── Prereq: aarch64-linux builder ────────────────────────────────────────
# Building a NixOS ISO on Apple Silicon requires a Linux builder — some
# derivations (e.g. GRUB configs, generated text files) are aarch64-linux
# and are not in the binary cache.  nix-darwin's linux-builder provides this.
if ! nix store info --store "ssh-ng://builder@linux-builder" &>/dev/null; then
  echo "ERROR: No aarch64-linux builder available." >&2
  echo "" >&2
  echo "  Building a NixOS ISO on Apple Silicon (aarch64-darwin) requires a" >&2
  echo "  Linux builder for derivations that are not in the binary cache." >&2
  echo "" >&2
  echo "  Enable the nix-darwin Linux builder by adding this to your" >&2
  echo "  nix-darwin configuration and running 'darwin-rebuild switch':" >&2
  echo "" >&2
  echo "    nix.linux-builder.enable = true;" >&2
  echo "" >&2
  echo "  After rebuilding, start the builder service:" >&2
  echo "    sudo launchctl kickstart -k system/org.nixos.linux-builder" >&2
  echo "" >&2
  echo "  Then re-run this script." >&2
  exit 1
fi

# ── Prereq: prlctl ────────────────────────────────────────────────────────
if ! command -v prlctl &>/dev/null; then
  echo "ERROR: prlctl not found." >&2
  echo "  Install Parallels Desktop ≥26 and ensure prlctl is on your PATH." >&2
  echo "  Typically: /usr/local/bin/prlctl" >&2
  exit 1
fi
if ! prlctl list &>/dev/null; then
  echo "ERROR: prlctl is available but 'prlctl list' failed." >&2
  echo "  This usually means Parallels Desktop is not licensed or not running." >&2
  exit 1
fi

# ── Prereq: op CLI ────────────────────────────────────────────────────────
if ! command -v op &>/dev/null; then
  echo "ERROR: 1Password CLI (op) not found." >&2
  echo "  Install it: brew install 1password-cli" >&2
  echo "  Or: https://developer.1password.com/docs/cli/get-started/" >&2
  exit 1
fi

# ── Prereq: .env ──────────────────────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env not found at $ENV_FILE" >&2
  echo "  Copy .env.sample to .env and fill in your service account token:" >&2
  echo "    cp .env.sample .env && \$EDITOR .env" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

# ── Prereq: OP_SERVICE_ACCOUNT_TOKEN ─────────────────────────────────────
if [[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
  echo "ERROR: OP_SERVICE_ACCOUNT_TOKEN is not set in .env" >&2
  echo "  Generate a service account token at:" >&2
  echo "    https://developer.1password.com/docs/service-accounts/" >&2
  exit 1
fi
export OP_SERVICE_ACCOUNT_TOKEN

# ── Prereq: op auth ───────────────────────────────────────────────────────
if ! op vault list &>/dev/null; then
  echo "ERROR: 'op vault list' failed — service account token may be invalid or expired." >&2
  echo "  Check your token at: https://1password.com/sign-in" >&2
  exit 1
fi

# ── Prereq: test vault ────────────────────────────────────────────────────
if ! op vault get nix-op-secrets-test &>/dev/null; then
  echo ""
  echo "The vault 'nix-op-secrets-test' is not accessible via your service account token."
  echo ""
  echo "This can mean one of two things:"
  echo "  A) The vault does not exist yet."
  echo "  B) The vault exists but your service account has not been granted access to it."
  echo ""
  echo "If (A) — create the vault with a human user account, then grant your service"
  echo "         account access before re-running this script:"
  echo ""
  echo "           op vault create nix-op-secrets-test   # as a human user"
  echo ""
  echo "If (B) — skip vault creation and go straight to granting access."
  echo ""
  echo "Either way, grant the service account vault access via the 1Password web UI:"
  echo "  1. Sign in at https://start.1password.com"
  echo "  2. Go to Developer Tools → Service Accounts → <your service account>"
  echo "  3. Under 'Vault Access', click 'Add vault' → 'nix-op-secrets-test'"
  echo "     (Read & Write permissions required)"
  echo ""
  printf "Create the vault now with op CLI (choose only if it doesn't exist yet)? [y/N] "
  read -r REPLY
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    op vault create nix-op-secrets-test
    echo ""
    echo "Vault created. IMPORTANT: You must still grant your service account access to"
    echo "this vault via the 1Password web UI before re-running this script:"
    echo "  https://start.1password.com → Developer Tools → Service Accounts"
    exit 1
  else
    echo ""
    echo "Re-run this script after granting your service account access to the vault." >&2
    exit 1
  fi
fi

# ── Run ───────────────────────────────────────────────────────────────────
echo "==> All prerequisites satisfied"
echo ""
echo "==> Step 1: Ensure base VM exists (idempotent)"
bash "$REPO_ROOT/scripts/vm/setup-base.sh"

echo ""
echo "==> Step 2: Run integration tests"
bash "$REPO_ROOT/scripts/vm/run-tests.sh"
