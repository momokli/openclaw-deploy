#!/bin/bash
# Deploy OpenClaw: sync config (git) + images (GHCR), then swap containers
# - Config: pulled from git on .149 (openclaw.json, agents/, workspace/)
# - Images: pulled from GHCR (built in GitHub Actions on projectmellon.de)
# Triggers on config OR image change.

set -euo pipefail

IMAGE="ghcr.io/momokli/openclaw-deploy:latest"
OBSIDIAN_IMAGE="ghcr.io/momokli/openclaw-obsidian-sync:latest"
LOCAL_DIR="/opt/apps/openclaw"
GIT_HASH_FILE="$LOCAL_DIR/.deploy-git-hash"
IMG_HASH_FILE="$LOCAL_DIR/.deploy-img-hash"
OBSIDIAN_IMG_HASH_FILE="$LOCAL_DIR/.deploy-obsidian-img-hash"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ── 1. Sync config from git ─────────────────────────────────────
log "Syncing config from git..."
cd "$LOCAL_DIR"
git pull origin main

NEW_GIT="$(git rev-parse HEAD)"
OLD_GIT="$(cat "$GIT_HASH_FILE" 2>/dev/null || echo '')"

# ── 2. Pull images from GHCR ─────────────────────────────────────
log "Pulling images..."
docker pull "$IMAGE"
docker pull "$OBSIDIAN_IMAGE"
NEW_IMG="$(docker images -q "$IMAGE" 2>/dev/null || echo '')"
NEW_OBSIDIAN_IMG="$(docker images -q "$OBSIDIAN_IMAGE" 2>/dev/null || echo '')"
OLD_IMG="$(cat "$IMG_HASH_FILE" 2>/dev/null || echo '')"
OLD_OBSIDIAN_IMG="$(cat "$OBSIDIAN_IMG_HASH_FILE" 2>/dev/null || echo '')"

# ── 3. Skip if nothing changed ──────────────────────────────────
if [ "$OLD_GIT" = "$NEW_GIT" ] && [ "$OLD_IMG" = "$NEW_IMG" ] && [ "$OLD_OBSIDIAN_IMG" = "$NEW_OBSIDIAN_IMG" ]; then
    log "No changes (config + images) — skipping deploy"
    exit 0
fi

log "Changes detected — recreating containers..."

# ── 4. Swap containers — recreate so entrypoint re-copies config ──
# Clean up stale EXITED openclaw containers first: leftovers from old
# compose project names caused "container name ... already in use".
docker ps -aq --filter name=openclaw --filter status=exited | xargs -r docker rm -f 2>/dev/null || true

docker compose up -d --force-recreate --remove-orphans openclaw obsidian-sync

# ── 6. Wait for healthy ─────────────────────────────────────────
for i in $(seq 1 30); do
    if docker exec openclaw curl -sf http://localhost:18789/healthz > /dev/null 2>&1; then
        log "Container healthy"
        break
    fi
    sleep 2
done

# ── 7. Reconnect to Caddy network (idempotent) ──────────────────
docker network connect caddy_default openclaw 2>/dev/null || true

# ── 8. Persist hashes ───────────────────────────────────────────
echo "$NEW_GIT" > "$GIT_HASH_FILE"
echo "$NEW_IMG" > "$IMG_HASH_FILE"
echo "$NEW_OBSIDIAN_IMG" > "$OBSIDIAN_IMG_HASH_FILE"
log "Deploy complete"
