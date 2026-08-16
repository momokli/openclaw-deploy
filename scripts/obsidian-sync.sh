#!/bin/sh
# Idempotent entrypoint for the obsidian-sync sidecar.
#
# 1. Ensures we're logged in (credentials persist in the obsidian_config volume).
# 2. Ensures the vault is set up for syncing.
# 3. Runs continuous sync.
set -eu

VAULT_DIR="${VAULT_DIR:-/data/quill}"
VAULT_NAME="${VAULT_NAME:-}"

log() { printf '[obsidian-sync] %s\n' "$*"; }

mkdir -p "$VAULT_DIR"

# ── 1. Login check ────────────────────────────────────────────────
# `sync-list-remote` requires auth; without a stored token it exits non-zero.
if ! ob sync-list-remote --json >/dev/null 2>&1; then
  log "Not logged in to Obsidian Sync."
  log "Authenticate once, interactively:"
  log "    docker compose exec obsidian-sync ob login"
  log "Credentials are stored in the persistent 'obsidian_config' volume,"
  log "so image rebuilds keep you logged in."
  log "Then restart to start syncing:"
  log "    docker compose restart obsidian-sync"
  log "Keeping the container alive for the interactive login session."
  exec sleep infinity
fi
log "Logged in."

# ── 2. Ensure sync is set up ──────────────────────────────────────
if ob sync-status --path "$VAULT_DIR" --json >/dev/null 2>&1; then
  log "Sync already configured for $VAULT_DIR."
elif [ -n "$VAULT_NAME" ]; then
  log "Setting up sync for remote vault '$VAULT_NAME'..."
  ob sync-setup --vault "$VAULT_NAME" --path "$VAULT_DIR"
else
  log "Sync is not configured for $VAULT_DIR."
  log "List your remote vaults:"
  log "    docker compose exec obsidian-sync ob sync-list-remote"
  log "Then set up sync (add --password '<pwd>' for end-to-end encrypted vaults):"
  log "    docker compose exec obsidian-sync ob sync-setup --vault \"<Vault Name>\" --path /data/quill"
  log "After setup, restart to start syncing:"
  log "    docker compose restart obsidian-sync"
  exec sleep infinity
fi

# ── 3. Continuous sync ────────────────────────────────────────────
log "Starting continuous sync for $VAULT_DIR..."
exec ob sync --path "$VAULT_DIR" --continuous
