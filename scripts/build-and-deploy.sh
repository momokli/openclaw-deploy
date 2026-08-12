#!/bin/bash
# Build OpenClaw image on projectmellon.de and deploy locally
# Run via systemd timer every 30 min or manually: systemctl start openclaw-build

set -euo pipefail

BUILD_HOST="root@projectmellon.de"
BUILD_DIR="/tmp/openclaw-build"
REPO="https://github.com/momokli/openclaw-deploy"
LOCAL_DIR="/opt/apps/openclaw"
HASH_FILE="$LOCAL_DIR/.deploy-hash"
IMAGE_NAME="openclaw-local:latest"
TARBALL="/tmp/openclaw-local.tar.gz"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ── Check if Dockerfile changed ──────────────────────────────────
# ── Pull latest from GitHub ──────────────────────────────────────
log "Pulling latest from $REPO..."
if [ -d "$LOCAL_DIR/.git" ]; then
    git -C "$LOCAL_DIR" pull origin main
else
    git clone "$REPO" "$LOCAL_DIR"
fi

OLD_HASH="$(cat "$HASH_FILE" 2>/dev/null || echo '')"
NEW_HASH="$(git -C "$LOCAL_DIR" rev-parse HEAD)"

if [ "$OLD_HASH" = "$NEW_HASH" ]; then
    log "No changes — skipping build"
    exit 0
fi

log "Dockerfile changed — starting build on $BUILD_HOST"

# ── Copy build context to build host ─────────────────────────────
scp -q "$LOCAL_DIR/Dockerfile" "$LOCAL_DIR/ssh_config" "$BUILD_HOST:$BUILD_DIR/"

# ── Build on fast server (with commit tag) ───────────────────────
IMAGE_TAG="openclaw:${NEW_HASH:0:8}"
log "Building image $IMAGE_TAG on $BUILD_HOST..."
ssh "$BUILD_HOST" "cd $BUILD_DIR && docker build -t $IMAGE_TAG -t openclaw-local:latest ."

# ── Validate ─────────────────────────────────────────────────────
log "Validating image..."
ssh "$BUILD_HOST" "docker run --rm $IMAGE_TAG which himalaya > /dev/null"
log "Image OK"

# ── Transfer to local host ───────────────────────────────────────
log "Transferring image..."
ssh "$BUILD_HOST" "docker save $IMAGE_TAG | gzip" > "$TARBALL"
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
