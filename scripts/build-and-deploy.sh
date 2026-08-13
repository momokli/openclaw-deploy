#!/bin/bash
# Deploy OpenClaw: pull latest image from GHCR and swap container
# Build happens in GitHub Actions (self-hosted runner on projectmellon.de)
# Run via systemd timer every 30 min, or manually: systemctl start openclaw-build

set -euo pipefail

IMAGE="ghcr.io/momokli/openclaw-deploy:latest"
LOCAL_DIR="/opt/apps/openclaw"
HASH_FILE="$LOCAL_DIR/.deploy-hash"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ── Pull latest image from GHCR ─────────────────────────────────
log "Pulling $IMAGE..."
OLD_ID="$(docker images -q "$IMAGE" 2>/dev/null || echo '')"
docker pull "$IMAGE"

NEW_ID="$(docker images -q "$IMAGE" 2>/dev/null || echo '')"

if [ -n "$OLD_ID" ] && [ "$OLD_ID" = "$NEW_ID" ]; then
    log "Image unchanged — skipping deploy"
    exit 0
fi

log "New image pulled — swapping container..."

# ── Atomic swap: compose re-creates container only if image changed ──
cd "$LOCAL_DIR"
docker compose up -d openclaw

# ── Wait for healthy ─────────────────────────────────────────────
for i in $(seq 1 30); do
    if docker exec openclaw curl -sf http://localhost:18789/healthz > /dev/null 2>&1; then
        log "Container healthy"
        break
    fi
    sleep 2
done

# ── Reconnect to Caddy network (if needed) ───────────────────────
docker network connect caddy_default openclaw 2>/dev/null || true

echo "$NEW_ID" > "$HASH_FILE"
log "Deploy complete"
