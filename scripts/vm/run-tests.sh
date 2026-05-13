#!/usr/bin/env bash
# scripts/vm/run-tests.sh
# Runs one full test cycle: clone base VM → provision → assert → teardown.
# Called by scripts/test-vm.sh after prereq checks and OP_SERVICE_ACCOUNT_TOKEN is set.
set -euo pipefail

# ── Cleanup trap — registered FIRST, before any side effects ──────────────
# Variables used in cleanup are initialised empty here so cleanup() is safe
# to call at any point, even if the script exits before they are assigned.
TEST_VM="" FIELD_ID="" SSH_ID="" DOC_ID=""
VAULT="nix-op-secrets-test"

cleanup() {
  echo "==> Cleanup..."
  [[ -n "$TEST_VM"   ]] && prlctl stop   "$TEST_VM" --kill 2>/dev/null || true
  [[ -n "$TEST_VM"   ]] && prlctl delete "$TEST_VM"        2>/dev/null || true
  for ID in ${FIELD_ID:-} ${SSH_ID:-} ${DOC_ID:-}; do
    [[ -n "$ID" ]] && op item delete "$ID" --vault "$VAULT" 2>/dev/null || true
  done
  echo "    Cleanup done"
}
trap cleanup EXIT

# ── Variables (after trap registration) ───────────────────────────────────
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
KEY_DIR="$REPO_ROOT/tests/vm/keys"
BASE_VM="nix-op-secrets-base"
TEST_VM="nix-op-secrets-test-$(date +%s)"
SSH_OPTS="-i $KEY_DIR/vm_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# ── 1. Clone base VM ──────────────────────────────────────────────────────
echo "==> Cloning '$BASE_VM' → '$TEST_VM'..."
prlctl clone "$BASE_VM" --name "$TEST_VM" --snapshot "clean"
prlctl start "$TEST_VM"

# ── 2. Mount repo + get IP ────────────────────────────────────────────────
echo "==> Mounting repo as shared folder..."
prlctl set "$TEST_VM" \
  --shf-host-add nix-op-secrets \
  --shf-host-path "$REPO_ROOT" \
  --shf-host-ro off

echo -n "==> Waiting for VM IP (up to 60s)..."
DEADLINE=$(( $(date +%s) + 60 ))
VM_IP=""
while [[ -z "$VM_IP" || "$VM_IP" == "-" ]]; do
  [[ "$(date +%s)" -ge "$DEADLINE" ]] && { echo; echo "ERROR: Timed out waiting for VM IP" >&2; exit 1; }
  sleep 3
  VM_IP=$(prlctl list "$TEST_VM" -o ip --no-header | tr -d ' ')
done
echo " $VM_IP"

echo -n "==> Waiting for SSH..."
until ssh $SSH_OPTS nixtest@"$VM_IP" true 2>/dev/null; do
  printf '.'; sleep 3
done
echo " ready"

SSH="ssh $SSH_OPTS nixtest@$VM_IP"

# ── 3. Create test 1Password items ────────────────────────────────────────
echo "==> Creating test 1Password items in vault '$VAULT'..."
FIELD_ID=$(op item create \
  --vault "$VAULT" \
  --category Login \
  --title "nix-op-secrets-test-field" \
  "password=test-field-value" \
  --format json | jq -r '.id')
echo "    Field item: $FIELD_ID"

SSH_ID=$(op item create \
  --vault "$VAULT" \
  --category "SSH Key" \
  --title "nix-op-secrets-test-ssh" \
  --format json | jq -r '.id')
echo "    SSH Key item: $SSH_ID"

DOC_ID=$(op document create "$REPO_ROOT/tests/vm/fixtures/test-doc.txt" \
  --vault "$VAULT" \
  --title "nix-op-secrets-test-doc" \
  --format json | jq -r '.id')
echo "    Document item: $DOC_ID"
# Template uses fixtures/infra.env.tpl which references the field item — no extra item needed

# ── 4. Inject service account token into VM ───────────────────────────────
echo "==> Injecting service account token into VM..."
$SSH "printf '%s' '$OP_SERVICE_ACCOUNT_TOKEN' | sudo tee /etc/op-secrets-test-token > /dev/null"

# ── 5. Build and switch ───────────────────────────────────────────────────
echo "==> Running nixos-rebuild switch (this takes several minutes)..."
$SSH "sudo nixos-rebuild switch \
  --flake /media/psf/nix-op-secrets/tests/vm#test-vm \
  --override-input op-secrets path:/media/psf/nix-op-secrets \
  --no-write-lock-file 2>&1"
echo "    Switch complete"

# ── 6. Assertions ─────────────────────────────────────────────────────────
echo "==> Running assertions..."

fail()          { echo "FAIL: $1" >&2; exit 1; }
check_file()    { $SSH "test -f '$1'" || fail "missing file: $1"; }
check_mode()    { MODE=$($SSH "stat -c '%a' '$1'"); [[ "$MODE" == "$2" ]] || fail "mode $MODE != $2 on $1"; }
check_content() { $SSH "grep -qF '$2' '$1'" || fail "expected '$2' in $1"; }

# Field
check_file "/home/nixtest/.local/secrets/field.txt"
check_mode "/home/nixtest/.local/secrets/field.txt" "600"

# SSH key pair
check_file "/home/nixtest/.ssh/test-vm-key"
check_mode "/home/nixtest/.ssh/test-vm-key" "600"
check_file "/home/nixtest/.ssh/test-vm-key.pub"
check_mode "/home/nixtest/.ssh/test-vm-key.pub" "644"

# Document
check_file "/home/nixtest/.local/secrets/doc.txt"
check_mode "/home/nixtest/.local/secrets/doc.txt" "600"

# Template output — must contain the resolved field value
check_file    "/home/nixtest/.local/secrets/infra.env"
check_mode    "/home/nixtest/.local/secrets/infra.env" "600"
check_content "/home/nixtest/.local/secrets/infra.env" "test-field-value"

# Manifest — all five entries (including __pub synthetic key for sshKey)
for KEY in test-field test-ssh "test-ssh__pub" test-doc test-template; do
  $SSH "jq -e '.\"$KEY\"' /home/nixtest/.local/state/op-secrets/manifest.json" > /dev/null \
    || fail "manifest missing key: $KEY"
done

echo ""
echo "✓ All VM integration tests passed"
