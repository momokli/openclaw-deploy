#!/bin/bash
# Build OpenClaw image on projectmellon.de and deploy locally
# Run via systemd timer every 30 min or manually: systemctl start openclaw-build

set -euo pipefail

BUILD_HOST="root@projectmellon.de"
BUILD_DIR="/tmp/openclaw-build"
LOCAL_DIR="/opt/apps/openclaw"
HASH_FILE="$LOCAL_DIR/.dockerfile-hash"
IMAGE_NAME="openclaw-local:latest"
TARBALL="/tmp/openclaw-local.tar.gz"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ── Check if Dockerfile changed ──────────────────────────────────
OLD_HASH="$(cat "$HASH_FILE" 2>/dev/null || echo '')"
NEW_HASH="$(md5sum "$LOCAL_DIR/Dockerfile" "$LOCAL_DIR/ssh_config" | md5sum | cut -d' ' -f1)"

if [ "$OLD_HASH" = "$NEW_HASH" ]; then
    log "No changes — skipping build"
    exit 0
fi

log "Dockerfile changed — starting build on $BUILD_HOST"

# ── Copy build context to build host ─────────────────────────────
scp -q "$LOCAL_DIR/Dockerfile" "$LOCAL_DIR/ssh_config" "$BUILD_HOST:$BUILD_DIR/"

# ── Build on fast server ─────────────────────────────────────────
log "Building image on $BUILD_HOST..."
ssh "$BUILD_HOST" "cd $BUILD_DIR && docker build --no-cache -t $IMAGE_NAME ."

# ── Validate ─────────────────────────────────────────────────────
log "Validating image..."
ssh "$BUILD_HOST" "docker run --rm $IMAGE_NAME which himalaya > /dev/null"
log "Image OK"

# ── Transfer to local host ───────────────────────────────────────
log "Transferring image..."
ssh "$BUILD_HOST" "docker save $IMAGE_NAME | gzip" > "$TARBALL"
docker load < "$TARBALL"

# ── Deploy ───────────────────────────────────────────────────────
log "Redeploying container..."
cd "$LOCAL_DIR"
docker compose down 2>/dev/null || true
docker compose up -d

# Wait for healthy
for i in $(seq 1 30); do
    if docker exec openclaw curl -sf http://localhost:18789/healthz > /dev/null 2>&1; then
        break
    fi
    sleep 2
done

# Reconnect to Caddy network
docker network connect caddy_default openclaw 2>/dev/null || true

# ── Cleanup ──────────────────────────────────────────────────────
rm -f "$TARBALL"
echo "$NEW_HASH" > "$HASH_FILE"
log "Deploy complete — container running"
