#!/usr/bin/env bash
# scripts/test-vm.sh
# Entry point for VM-based integration tests.
# Usage: ./scripts/test-vm.sh
#
# Prerequisites:
#   - Parallels Desktop ≥26 with prlctl on PATH
#   - 1Password CLI (op) on PATH
#   - .env at repo root containing OP_SERVICE_ACCOUNT_TOKEN
#   - The "nix-op-secrets-test" vault must exist in your 1Password account
set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
ENV_FILE="$REPO_ROOT/.env"

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
  echo "The vault 'nix-op-secrets-test' does not exist in your 1Password account."
  printf "Create it now? [y/N] "
  read -r REPLY
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    op vault create nix-op-secrets-test
    echo "Vault created."
  else
    echo "ERROR: Please create the vault manually: op vault create nix-op-secrets-test" >&2
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
