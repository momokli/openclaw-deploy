#!/bin/bash
# Deploy OpenClaw: sync config (git) + image (GHCR), then swap container
# - Config: pulled from git on .149 (openclaw.json, agents/, workspace/)
# - Image: pulled from GHCR (built in GitHub Actions on projectmellon.de)
# Triggers on EITHER config OR image change.

set -euo pipefail

IMAGE="ghcr.io/momokli/openclaw-deploy:latest"
LOCAL_DIR="/opt/apps/openclaw"
GIT_HASH_FILE="$LOCAL_DIR/.deploy-git-hash"
IMG_HASH_FILE="$LOCAL_DIR/.deploy-img-hash"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ── 1. Sync config from git ─────────────────────────────────────
log "Syncing config from git..."
cd "$LOCAL_DIR"
git pull origin main

NEW_GIT="$(git rev-parse HEAD)"
OLD_GIT="$(cat "$GIT_HASH_FILE" 2>/dev/null || echo '')"

# ── 2. Pull image from GHCR ─────────────────────────────────────
log "Pulling $IMAGE..."
docker pull "$IMAGE"
NEW_IMG="$(docker images -q "$IMAGE" 2>/dev/null || echo '')"
OLD_IMG="$(cat "$IMG_HASH_FILE" 2>/dev/null || echo '')"

# ── 3. Skip if nothing changed ──────────────────────────────────
if [ "$OLD_GIT" = "$NEW_GIT" ] && [ "$OLD_IMG" = "$NEW_IMG" ]; then
    log "No changes (config + image) — skipping deploy"
    exit 0
fi

log "Changes detected — recreating container..."

# ── 4. Atomic swap (compose re-creates container) ───────────────
docker compose up -d openclaw

# ── 5. Wait for healthy ─────────────────────────────────────────
for i in $(seq 1 30); do
    if docker exec openclaw curl -sf http://localhost:18789/healthz > /dev/null 2>&1; then
        log "Container healthy"
        break
    fi
    sleep 2
done

# ── 6. Reconnect to Caddy network (idempotent) ──────────────────
docker network connect caddy_default openclaw 2>/dev/null || true

# ── 7. Persist hashes ───────────────────────────────────────────
echo "$NEW_GIT" > "$GIT_HASH_FILE"
echo "$NEW_IMG" > "$IMG_HASH_FILE"
log "Deploy complete"
