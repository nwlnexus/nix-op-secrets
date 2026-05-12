# lib/mk-activation.nix
# Returns a pkgs.writeShellScript derivation.
# String-interpolating the derivation in a shell snippet yields its executable store path.
#
# Parameters:
#   pkgs              — nixpkgs instance (real or fake for testing)
#   lib               — nixpkgs lib
#   cfg               — the op-secrets config attrset
#   isSystemActivation — true when called from darwin.nix (root → user boundary)
{ pkgs, lib, cfg, isSystemActivation ? false }:

let
  op = "${pkgs._1password-cli}/bin/op";

  # Generate one fetch_secret call per declared secret.
  # IMPORTANT: template is checked first (before type dispatch) because template
  # is orthogonal to type — a secret can have type="field" and also set template.
  mkSecretCommand = name: secret:
    let
      typeArg     = if secret.template != null then "template" else secret.type;
      sourceArg   = if secret.source   != null then secret.source   else "";
      vaultArg    = if secret.vault    != null then secret.vault    else "";
      itemArg     = if secret.item     != null then secret.item     else "";
      templateArg = if secret.template != null then toString secret.template else "";
    in ''
      fetch_secret \
        ${lib.escapeShellArg name} \
        ${lib.escapeShellArg typeArg} \
        ${lib.escapeShellArg sourceArg} \
        ${lib.escapeShellArg vaultArg} \
        ${lib.escapeShellArg itemArg} \
        ${lib.escapeShellArg templateArg} \
        ${lib.escapeShellArg secret.dest} \
        ${lib.escapeShellArg secret.mode} \
        ${if secret.writePublicKey then "1" else "0"}
    '';

  secretCommands = lib.concatStringsSep "\n" (
    lib.mapAttrsToList mkSecretCommand cfg.secrets
  );

  secretNames = lib.concatStringsSep "\n" (lib.attrNames cfg.secrets);

  manifestJqArgs = lib.concatStringsSep " \\\n    " (
    lib.mapAttrsToList (name: secret:
      "--arg ${lib.escapeShellArg name} ${lib.escapeShellArg secret.dest}"
    ) cfg.secrets
  );

in pkgs.writeShellScript "op-secrets-activate" ''
  set -euo pipefail
  umask 077

  OP=${lib.escapeShellArg op}
  MODULE_ACCOUNT=${lib.escapeShellArg (if cfg.account != null then cfg.account else "")}
  SERVICE_ACCOUNT_TOKEN_FILE=${lib.escapeShellArg (
    if cfg.serviceAccountTokenFile != null then cfg.serviceAccountTokenFile else ""
  )}
  IS_SYSTEM_ACTIVATION=${if isSystemActivation then "1" else "0"}
  ${lib.optionalString isSystemActivation ''
  ACTIVATION_USER=${lib.escapeShellArg cfg.user}
  ACTIVATION_GROUP=${lib.escapeShellArg cfg.group}
  ''}

  # ── Account / auth args ──────────────────────────────────────────────────────
  ACCOUNT="''${OP_ACCOUNT:-$MODULE_ACCOUNT}"
  OP_ARGS=()
  [[ -n "$ACCOUNT" ]] && OP_ARGS+=(--account "$ACCOUNT")

  # ── Auth ─────────────────────────────────────────────────────────────────────
  if [[ -n "''${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
    : # token in env — op picks it up natively
  elif [[ -n "$SERVICE_ACCOUNT_TOKEN_FILE" && -f "$SERVICE_ACCOUNT_TOKEN_FILE" ]]; then
    OP_SERVICE_ACCOUNT_TOKEN="$(cat "$SERVICE_ACCOUNT_TOKEN_FILE")"
    export OP_SERVICE_ACCOUNT_TOKEN
  elif "$OP" whoami "''${OP_ARGS[@]}" &>/dev/null; then
    : # already authenticated
  else
    echo "op-secrets: not authenticated — running op signin" >&2
    echo "op-secrets: NOTE: interactive signin requires a TTY; use OP_SERVICE_ACCOUNT_TOKEN for non-interactive contexts" >&2
    "$OP" signin "''${OP_ARGS[@]}" || {
      echo "op-secrets: authentication failed — aborting" >&2
      exit 1
    }
  fi

  # ── Helpers ──────────────────────────────────────────────────────────────────
  run_op() {
    if [[ "$IS_SYSTEM_ACTIVATION" == "1" ]]; then
      sudo -u "$ACTIVATION_USER" -- "$OP" "''${OP_ARGS[@]}" "$@"
    else
      "$OP" "''${OP_ARGS[@]}" "$@"
    fi
  }

  run_op_document() {
    # document get writes to --output path; needs umask in the child process
    local item="$1" vault="$2" dest_tmp="$3"
    if [[ "$IS_SYSTEM_ACTIVATION" == "1" ]]; then
      # Preserve umask across sudo boundary by wrapping in sh -c
      sudo -u "$ACTIVATION_USER" sh -c \
        "umask 077; ${lib.escapeShellArg op} ''${OP_ARGS[*]+''${OP_ARGS[*]}} document get \"$item\" --vault \"$vault\" --output \"$dest_tmp\""
    else
      "$OP" "''${OP_ARGS[@]}" document get "$item" --vault "$vault" --output "$dest_tmp"
    fi
  }

  # ── Secret handlers ──────────────────────────────────────────────────────────
  fetch_secret() {
    local name="$1" eff_type="$2" source="$3" vault="$4" item="$5" \
          template="$6" dest="$7" mode="$8" write_pub="$9"
    local dest_tmp="''${dest}.tmp"

    mkdir -p "$(dirname "$dest")"

    case "$eff_type" in
      template)
        # op inject: template path is a Nix store path (world-readable skeleton only)
        run_op inject -i "$template" -o "$dest_tmp"
        mv "$dest_tmp" "$dest"
        chmod "$mode" "$dest"
        ;;
      field)
        run_op read "$source" > "$dest_tmp"
        mv "$dest_tmp" "$dest"
        chmod "$mode" "$dest"
        ;;
      document)
        run_op_document "$item" "$vault" "$dest_tmp"
        mv "$dest_tmp" "$dest"
        if [[ "$IS_SYSTEM_ACTIVATION" == "1" ]]; then
          chown "$ACTIVATION_USER:$ACTIVATION_GROUP" "$dest"
        fi
        chmod "$mode" "$dest"
        ;;
      sshKey)
        # Field names are exact — lowercase with space; required by op CLI
        run_op read "''${source}/private key" > "$dest_tmp"
        mv "$dest_tmp" "$dest"
        chmod 0600 "$dest"  # forced; mode option is ignored for private keys
        if [[ "$write_pub" == "1" ]]; then
          run_op read "''${source}/public key" > "''${dest}.pub.tmp"
          mv "''${dest}.pub.tmp" "''${dest}.pub"
          chmod 0644 "''${dest}.pub"
        fi
        ;;
      *)
        echo "op-secrets: unknown effective type '$eff_type' for secret '$name'" >&2
        exit 1
        ;;
    esac

    echo "op-secrets: wrote $name → $dest"
  }

  # ── Manifest ─────────────────────────────────────────────────────────────────
  if [[ "$IS_SYSTEM_ACTIVATION" == "1" ]]; then
    USER_HOME="$(sudo -u "$ACTIVATION_USER" sh -c 'echo $HOME')"
  else
    USER_HOME="$HOME"
  fi
  MANIFEST_DIR="$USER_HOME/.local/state/op-secrets"
  MANIFEST="$MANIFEST_DIR/manifest.json"

  OLD_MANIFEST="{}"
  [[ -f "$MANIFEST" ]] && OLD_MANIFEST="$(cat "$MANIFEST")"

  # Orphan cleanup: remove files for secrets no longer in config
  NEW_NAMES=$(printf '%s\n' ${lib.escapeShellArg secretNames})
  echo "$OLD_MANIFEST" \
    | ${pkgs.jq}/bin/jq -r 'to_entries[] | "\(.key)\t\(.value)"' \
    | while IFS=$'\t' read -r key path; do
        if ! printf '%s\n' "$NEW_NAMES" | grep -qxF "$key"; then
          if [[ -f "$path" ]]; then
            rm -f "$path"
            echo "op-secrets: removed orphaned secret '$key' ($path)"
          fi
        fi
      done

  # ── Fetch all secrets (fail-fast — any error exits immediately via set -e) ──
  ${secretCommands}

  # ── Write manifest only on full success ───────────────────────────────────
  mkdir -p "$MANIFEST_DIR"
  ${pkgs.jq}/bin/jq -n '$ARGS.named' \
    ${manifestJqArgs} \
    > "$MANIFEST"
  echo "op-secrets: activation complete"
''
