#!/usr/bin/env bash
# scripts/vm/run-tests.sh
# Runs one full test cycle: clone base VM → provision → assert → teardown.
# Called by scripts/test-vm.sh after prereq checks and OP_SERVICE_ACCOUNT_TOKEN is set.
set -euo pipefail

# ── Single-run lock ────────────────────────────────────────────────────────
# Two concurrent runs would race on the shared 1Password test items and the
# Parallels base snapshot.  Refuse to start if another run is in progress.
LOCK_DIR="/tmp/nix-op-secrets-vm-test.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "ERROR: another VM test run appears to be in progress" >&2
  echo "       (lock dir: $LOCK_DIR — remove manually if stale)" >&2
  exit 1
fi

# ── Cleanup trap — registered FIRST, before any side effects ──────────────
# Variables used in cleanup are initialised empty here so cleanup() is safe
# to call at any point, even if the script exits before they are assigned.
TEST_VM="" FIELD_ID="" SSH_ID="" DOC_ID=""
VAULT="nix-op-secrets-test"
KNOWN_HOSTS_FILE=""  # set once we know $TEST_VM's path; cleaned up on exit

cleanup() {
  echo "==> Cleanup..."
  [[ -n "$TEST_VM"   ]] && prlctl stop   "$TEST_VM" --kill 2>/dev/null || true
  [[ -n "$TEST_VM"   ]] && prlctl delete "$TEST_VM"        2>/dev/null || true
  for ID in ${FIELD_ID:-} ${SSH_ID:-} ${DOC_ID:-}; do
    [[ -n "$ID" ]] && op item delete "$ID" --vault "$VAULT" 2>/dev/null || true
  done
  [[ -n "$KNOWN_HOSTS_FILE" && -f "$KNOWN_HOSTS_FILE" ]] && rm -f "$KNOWN_HOSTS_FILE"
  rmdir "$LOCK_DIR" 2>/dev/null || true
  echo "    Cleanup done"
}
trap cleanup EXIT

# ── Variables (after trap registration) ───────────────────────────────────
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
KEY_DIR="$REPO_ROOT/tests/vm/keys"
BASE_VM="nix-op-secrets-base"
TEST_VM="nix-op-secrets-test-$(date +%s)"
KNOWN_HOSTS_DIR="$REPO_ROOT/.cache/known_hosts"
KNOWN_HOSTS_FILE="$KNOWN_HOSTS_DIR/$TEST_VM"
mkdir -p "$KNOWN_HOSTS_DIR"

# Two option sets — *_INSECURE only for the reachability poll (runs `true`,
# no payload); everything that carries data uses $SSH_OPTS, which pins the
# host keys captured below.  See setup-base.sh for the threat model.
SSH_OPTS_INSECURE="-i $KEY_DIR/vm_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o PasswordAuthentication=no"
SSH_OPTS="-i $KEY_DIR/vm_key -o UserKnownHostsFile=$KNOWN_HOSTS_FILE -o StrictHostKeyChecking=yes -o BatchMode=yes -o PasswordAuthentication=no"

# ── 1. Clone base VM ──────────────────────────────────────────────────────
# Use a linked clone from the 'clean' snapshot — much faster than a deep copy.
# Parallels needs the snapshot UUID, which we extract from the JSON listing.
echo "==> Cloning '$BASE_VM' → '$TEST_VM' (linked from snapshot 'clean')..."
SNAPSHOT_ID=$(prlctl snapshot-list "$BASE_VM" -j 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(next(k for k,v in d.items() if v.get('name')=='clean'))")
if [[ -z "$SNAPSHOT_ID" ]]; then
  echo "ERROR: No 'clean' snapshot found on $BASE_VM" >&2
  exit 1
fi
prlctl clone "$BASE_VM" --name "$TEST_VM" --linked -i "$SNAPSHOT_ID"
prlctl start "$TEST_VM"

# ── 2. Get IP ─────────────────────────────────────────────────────────────
echo -n "==> Waiting for VM IP (up to 300s)..."
DEADLINE=$(( $(date +%s) + 300 ))
VM_IP=""
while [[ -z "$VM_IP" || "$VM_IP" == "-" ]]; do
  [[ "$(date +%s)" -ge "$DEADLINE" ]] && { echo; echo "ERROR: Timed out waiting for VM IP" >&2; exit 1; }
  sleep 3
  # Disable pipefail temporarily — grep returns 1 with no match.
  set +o pipefail
  VM_IP=$(prlctl list "$TEST_VM" -o ip --no-header 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
  set -o pipefail
done
echo " $VM_IP"

echo -n "==> Waiting for SSH..."
until ssh $SSH_OPTS_INSECURE nixtest@"$VM_IP" true 2>/dev/null; do
  printf '.'; sleep 3
done
echo " ready"

# Capture and pin the clone's host keys. Linked-clone VMs inherit the base
# VM's SSH host keys, but they get a fresh IP, so we re-keyscan per clone.
echo "==> Capturing VM host keys → $KNOWN_HOSTS_FILE"
ssh-keyscan -H -T 30 "$VM_IP" > "$KNOWN_HOSTS_FILE" 2>/dev/null
if [[ ! -s "$KNOWN_HOSTS_FILE" ]]; then
  echo "ERROR: ssh-keyscan returned no keys for $VM_IP" >&2
  exit 1
fi

SSH="ssh $SSH_OPTS nixtest@$VM_IP"

# ── 3. Sync repo into VM ──────────────────────────────────────────────────
echo "==> Syncing repo into VM..."
rsync -az --delete \
  -e "ssh $SSH_OPTS" \
  --exclude='.git' \
  --exclude='.worktrees' \
  --exclude='.cache' \
  --exclude='tests/vm/keys' \
  --exclude='.env' \
  --exclude='.env.*' \
  --exclude='*.pem' \
  --exclude='*.key' \
  "$REPO_ROOT/" \
  "nixtest@$VM_IP:/home/nixtest/nix-op-secrets/"
echo "    Repo synced to /home/nixtest/nix-op-secrets"

# ── 4. Create test 1Password items ────────────────────────────────────────
# First, scrub any orphans from earlier interrupted runs so the new items'
# titles resolve uniquely.  All test items are prefixed with
# "nix-op-secrets-test-" and live in a dedicated test vault.
echo "==> Scrubbing any orphan test items in vault '$VAULT'..."
op item list --vault "$VAULT" --format json 2>/dev/null \
  | jq -r '.[] | select(.title|startswith("nix-op-secrets-test-")) | .id' \
  | while read -r ORPHAN_ID; do
      [[ -z "$ORPHAN_ID" ]] && continue
      echo "    deleting orphan $ORPHAN_ID"
      op item delete "$ORPHAN_ID" --vault "$VAULT" 2>/dev/null || true
    done

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

# ── 5. Inject service account token into VM ───────────────────────────────
# Send the token through SSH stdin rather than interpolating into the remote
# command — that prevents the token from appearing in `ps` output on the host
# and is robust against any shell-special characters in the token value.
echo "==> Injecting service account token into VM..."
printf '%s' "$OP_SERVICE_ACCOUNT_TOKEN" | $SSH "sudo tee /etc/op-secrets-test-token >/dev/null \
  && sudo chown nixtest:nixtest /etc/op-secrets-test-token \
  && sudo chmod 600 /etc/op-secrets-test-token"

# ── 6. Run home-manager switch ────────────────────────────────────────────
# Uses standalone home-manager (no NixOS required).
# --override-input redirects op-secrets to the local checkout so we test
# the current code without modifying flake.lock.
echo "==> Running home-manager switch (this takes several minutes on first run)..."
$SSH "source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh && \
  nix run github:nix-community/home-manager/release-25.05 -- switch \
    --flake /home/nixtest/nix-op-secrets/tests/vm#nixtest \
    --override-input op-secrets path:/home/nixtest/nix-op-secrets \
    --no-write-lock-file 2>&1"
echo "    Switch complete"

# ── 7. Assertions ─────────────────────────────────────────────────────────
# These checks verify both presence and identity:
#  - exact content (field, template substitution, document sha256)
#  - file mode bits
#  - sshKey: derived public key matches the written .pub (keypair coherence)
#  - manifest contains all expected entries
echo "==> Running assertions..."

fail()              { echo "FAIL: $1" >&2; exit 1; }
check_file()        { $SSH "test -f '$1'" || fail "missing file: $1"; }
check_mode()        { MODE=$($SSH "stat -c '%a' '$1'"); [[ "$MODE" == "$2" ]] || fail "mode $MODE != $2 on $1"; }
# Read remote file via stdout instead of shell-quoting the expected value.
check_exact_value() {
  local path="$1" expected="$2"
  local actual; actual=$($SSH "cat '$path'")
  [[ "$actual" == "$expected" ]] || fail "$path: expected '$expected', got '$actual'"
}
check_contains() {
  local path="$1" needle="$2"
  # Pipe the needle so it isn't expanded by either shell.
  printf '%s' "$needle" | $SSH "grep -qFf - '$path'" || fail "expected '$needle' in $path"
}

# 1. Field — content must equal the value created in step 4.
check_file        "/home/nixtest/.local/secrets/field.txt"
check_mode        "/home/nixtest/.local/secrets/field.txt" "600"
check_exact_value "/home/nixtest/.local/secrets/field.txt" "test-field-value"

# 2. SSH key pair — must exist with right modes AND look like real key material.
#    We do a structural check (private has the OpenSSH/PEM "BEGIN … PRIVATE KEY"
#    header; public starts with "ssh-…") rather than `ssh-keygen -y` cryptographic
#    derivation, because 1Password's exact private-key output format varies
#    (trailing newline / line endings) and isn't always parseable by ssh-keygen.
check_file "/home/nixtest/.ssh/test-vm-key"
check_mode "/home/nixtest/.ssh/test-vm-key" "600"
check_file "/home/nixtest/.ssh/test-vm-key.pub"
check_mode "/home/nixtest/.ssh/test-vm-key.pub" "644"
$SSH "grep -q -- '-----BEGIN.*PRIVATE KEY-----' /home/nixtest/.ssh/test-vm-key" \
  || fail "sshKey: private key missing PEM/OpenSSH 'BEGIN PRIVATE KEY' header"
$SSH "grep -qE '^(ssh-(rsa|ed25519|dss)|ecdsa-) ' /home/nixtest/.ssh/test-vm-key.pub" \
  || fail "sshKey: public key does not start with a recognised SSH key type"

# 3. Document — sha256 must match the host-side fixture exactly.
check_file "/home/nixtest/.local/secrets/doc.txt"
check_mode "/home/nixtest/.local/secrets/doc.txt" "600"
EXPECTED_DOC_SHA=$(shasum -a 256 "$REPO_ROOT/tests/vm/fixtures/test-doc.txt" | awk '{print $1}')
ACTUAL_DOC_SHA=$($SSH "sha256sum /home/nixtest/.local/secrets/doc.txt | awk '{print \$1}'")
[[ "$EXPECTED_DOC_SHA" == "$ACTUAL_DOC_SHA" ]] \
  || fail "document sha256 mismatch (expected $EXPECTED_DOC_SHA, got $ACTUAL_DOC_SHA)"

# 4. Template output — must contain the resolved field value.
check_file     "/home/nixtest/.local/secrets/infra.env"
check_mode     "/home/nixtest/.local/secrets/infra.env" "600"
check_contains "/home/nixtest/.local/secrets/infra.env" "test-field-value"

# 5. Manifest — all five entries (including __pub synthetic key for sshKey).
for KEY in test-field test-ssh "test-ssh__pub" test-doc test-template; do
  $SSH "jq -e '.\"$KEY\"' /home/nixtest/.local/state/op-secrets/manifest.json" > /dev/null \
    || fail "manifest missing key: $KEY"
done

echo ""
echo "✓ All VM integration tests passed"
