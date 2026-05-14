# tests/default.nix
# Fast hermetic integration test for the op-secrets activation script.
# Runs in ~5 s in the Nix sandbox, no Parallels, no real 1Password vault.
# Wired to flake `checks.<system>.integration` — runs via `nix flake check`.
#
# Three phases:
#   A. Initial activation     — all four secret types are written correctly.
#   B. Idempotent re-run      — same cfg, second activation does not corrupt
#                                state and leaves files / manifest intact.
#   C. Orphan removal         — re-run with `test-doc` removed; activation
#                                must delete the orphaned file and prune the
#                                manifest entry, while leaving other entries
#                                untouched.
{ pkgs, lib }:
let
  mkActivation = import ../lib/mk-activation.nix;

  # Build a fake _1password-cli package that wraps our mock script.
  # mock-op.sh returns deterministic, predictable output so we can assert
  # against exact content rather than just file presence.
  mockOpPkg = pkgs.runCommand "mock-1password-cli" {} ''
    mkdir -p $out/bin
    cp ${./mock-op.sh} $out/bin/op
    chmod +x $out/bin/op
  '';

  fakePkgs = pkgs // {
    _1password-cli = mockOpPkg;
    # jq is real — we need it for manifest operations
  };

  # Common attributes used by every secret declaration.  Splitting these out
  # avoids the long noisy repetition in each entry.
  baseSecret = {
    vault = null;
    item = null;
    template = null;
    writePublicKey = false;
    mode = "0600";
    source = null;
  };

  mkSecret = attrs: baseSecret // attrs;

  # All dest paths use /DEST_BASE sentinel that gets replaced at test runtime.
  secretsFull = {
    "test-field" = mkSecret {
      type = "field";
      source = "op://Test/Item/password";
      dest = "/DEST_BASE/field.txt";
    };
    "test-ssh" = mkSecret {
      type = "sshKey";
      source = "op://Test/SSH Key";
      dest = "/DEST_BASE/id_ed25519";
      writePublicKey = true;
    };
    "test-doc" = mkSecret {
      type = "document";
      vault = "Test";
      item = "My Doc";
      dest = "/DEST_BASE/doc.txt";
    };
    "test-template" = mkSecret {
      # When `template` is set it takes precedence over `type`; the value of
      # `type` is therefore irrelevant for this entry but the option requires
      # one of the enum values.
      type = "field";
      template = ./infra.env.tpl;
      dest = "/DEST_BASE/infra.env";
    };
  };

  # cfg used for the prune phase — test-doc removed so the script must
  # delete /DEST_BASE/doc.txt and drop its manifest entry.
  secretsPruned = removeAttrs secretsFull [ "test-doc" ];

  mkCfg = secrets: {
    account = null;
    serviceAccountTokenFile = null;
    inherit secrets;
  };

  scriptFull   = mkActivation { pkgs = fakePkgs; inherit lib; cfg = mkCfg secretsFull;   };
  scriptPruned = mkActivation { pkgs = fakePkgs; inherit lib; cfg = mkCfg secretsPruned; };

in {
  integration = pkgs.runCommand "op-secrets-integration-test" {
    buildInputs = [ pkgs.jq pkgs.gnugrep pkgs.coreutils ];
  } ''
    set -euo pipefail

    # ── Sandbox setup ───────────────────────────────────────────────────────
    # Set up a writable HOME and dest directory within the sandbox temp space.
    # The activation script has /DEST_BASE/ in its generated dest paths; we
    # patch those to the actual temp path at runtime so the test is hermetic.
    export HOME="$(mktemp -d)"
    export DEST_BASE="$(mktemp -d)"

    patch_script() {
      local src="$1" out="$2"
      sed "s|/DEST_BASE|$DEST_BASE|g" "$src" > "$out"
      chmod +x "$out"
    }

    SCRIPT_FULL="$(mktemp)"
    SCRIPT_PRUNED="$(mktemp)"
    patch_script "${scriptFull}"   "$SCRIPT_FULL"
    patch_script "${scriptPruned}" "$SCRIPT_PRUNED"

    # ── Helpers ─────────────────────────────────────────────────────────────
    MANIFEST="$HOME/.local/state/op-secrets/manifest.json"

    pass() { echo "PASS: $1"; }
    fail() { echo "FAIL: $1" >&2; exit 1; }

    check_file_present() {
      [[ -f "$2" ]] || fail "$1 — file missing: $2"
    }
    check_file_absent() {
      [[ ! -e "$2" ]] || fail "$1 — file should have been removed: $2"
    }
    check_mode() {
      local mode
      mode=$(stat -c '%a' "$2" 2>/dev/null) || mode=$(stat -f '%Op' "$2" 2>/dev/null)
      [[ "$mode" == "$3" ]] || fail "$1 — mode $mode != $3 on $2"
    }
    check_content_exact() {
      local actual; actual=$(cat "$2")
      [[ "$actual" == "$3" ]] || fail "$1 — expected '$3', got '$actual'"
    }
    check_content_contains() {
      grep -qF -- "$3" "$2" || fail "$1 — expected '$3' inside $2"
    }
    check_manifest_has() {
      jq -e --arg k "$1" '.[$k]' "$MANIFEST" >/dev/null || fail "manifest missing key: $1"
    }
    check_manifest_missing() {
      jq -e --arg k "$1" 'has($k)|not' "$MANIFEST" >/dev/null || fail "manifest still has key: $1"
    }

    # ── Phase A: first activation ───────────────────────────────────────────
    echo ""
    echo "=== Phase A: first activation (all 4 secrets) ==="
    bash "$SCRIPT_FULL" 2>&1

    # Files exist with right modes
    check_file_present "field"            "$DEST_BASE/field.txt"
    check_mode         "field"            "$DEST_BASE/field.txt"     "600"
    check_file_present "ssh private"      "$DEST_BASE/id_ed25519"
    check_mode         "ssh private"      "$DEST_BASE/id_ed25519"    "600"
    check_file_present "ssh public"       "$DEST_BASE/id_ed25519.pub"
    check_mode         "ssh public"       "$DEST_BASE/id_ed25519.pub" "644"
    check_file_present "document"         "$DEST_BASE/doc.txt"
    check_mode         "document"         "$DEST_BASE/doc.txt"       "600"
    check_file_present "template output"  "$DEST_BASE/infra.env"
    check_mode         "template output"  "$DEST_BASE/infra.env"     "600"

    # Exact content — the mock returns deterministic strings keyed off the
    # op:// URI, so we can pin the exact expected bytes.  This catches
    # regressions that previously slipped past existence-only checks (e.g.
    # writing the wrong secret to the wrong dest).
    check_content_exact     "field content"  "$DEST_BASE/field.txt" \
                            "mock-field-value-for-op://Test/Item/password"
    check_content_exact     "doc content"    "$DEST_BASE/doc.txt"   "mock-document-content"
    check_content_contains  "template subst" "$DEST_BASE/infra.env" "MOCK_KEY=mock-injected-value"
    check_content_contains  "ssh priv pem"   "$DEST_BASE/id_ed25519"     "BEGIN OPENSSH PRIVATE KEY"
    check_content_contains  "ssh pub algo"   "$DEST_BASE/id_ed25519.pub" "ssh-ed25519"

    # Manifest contains all 5 entries (the synthetic __pub for the sshKey).
    check_file_present "manifest" "$MANIFEST"
    for key in test-field test-ssh test-ssh__pub test-doc test-template; do
      check_manifest_has "$key"
    done
    pass "phase A — initial activation"

    # Capture content hashes so we can detect any mutation in phase B.
    SHA_FIELD_A=$(sha256sum "$DEST_BASE/field.txt"     | awk '{print $1}')
    SHA_SSH_A=$(  sha256sum "$DEST_BASE/id_ed25519"    | awk '{print $1}')
    SHA_PUB_A=$(  sha256sum "$DEST_BASE/id_ed25519.pub"| awk '{print $1}')
    SHA_DOC_A=$(  sha256sum "$DEST_BASE/doc.txt"       | awk '{print $1}')
    SHA_TPL_A=$(  sha256sum "$DEST_BASE/infra.env"     | awk '{print $1}')
    MANIFEST_A=$( jq -S . "$MANIFEST" )

    # ── Phase B: idempotent re-run ──────────────────────────────────────────
    echo ""
    echo "=== Phase B: idempotent re-run (same cfg) ==="
    bash "$SCRIPT_FULL" 2>&1

    [[ "$(sha256sum "$DEST_BASE/field.txt"      | awk '{print $1}')" == "$SHA_FIELD_A" ]] \
      || fail "phase B — field.txt changed on re-run"
    [[ "$(sha256sum "$DEST_BASE/id_ed25519"     | awk '{print $1}')" == "$SHA_SSH_A"   ]] \
      || fail "phase B — id_ed25519 changed on re-run"
    [[ "$(sha256sum "$DEST_BASE/id_ed25519.pub" | awk '{print $1}')" == "$SHA_PUB_A"   ]] \
      || fail "phase B — id_ed25519.pub changed on re-run"
    [[ "$(sha256sum "$DEST_BASE/doc.txt"        | awk '{print $1}')" == "$SHA_DOC_A"   ]] \
      || fail "phase B — doc.txt changed on re-run"
    [[ "$(sha256sum "$DEST_BASE/infra.env"      | awk '{print $1}')" == "$SHA_TPL_A"   ]] \
      || fail "phase B — infra.env changed on re-run"
    [[ "$(jq -S . "$MANIFEST")" == "$MANIFEST_A" ]] \
      || fail "phase B — manifest mutated on re-run"
    pass "phase B — idempotent re-activation"

    # ── Phase C: orphan removal ─────────────────────────────────────────────
    echo ""
    echo "=== Phase C: orphan removal (test-doc dropped) ==="
    bash "$SCRIPT_PRUNED" 2>&1

    # doc.txt must be gone, its manifest entry pruned.
    check_file_absent     "phase C — orphan doc file"  "$DEST_BASE/doc.txt"
    check_manifest_missing "test-doc"

    # All other declared secrets still present and unchanged.
    check_file_present "phase C — field still present"     "$DEST_BASE/field.txt"
    check_file_present "phase C — ssh priv still present"  "$DEST_BASE/id_ed25519"
    check_file_present "phase C — ssh pub still present"   "$DEST_BASE/id_ed25519.pub"
    check_file_present "phase C — template still present"  "$DEST_BASE/infra.env"
    for key in test-field test-ssh test-ssh__pub test-template; do
      check_manifest_has "$key"
    done
    pass "phase C — orphan removed, others intact"

    echo ""
    echo "All integration tests passed (3 phases, all assertions)"
    touch $out
  '';
}
