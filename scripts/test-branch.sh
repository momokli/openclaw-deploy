#!/bin/bash
# Test an OpenClaw image from a feature branch without disturbing main
# Usage: ./scripts/test-branch.sh <branch-name>
# Example: ./scripts/test-branch.sh feat/himalaya

set -euo pipefail
BRANCH="${1:-}"
[ -z "$BRANCH" ] && { echo "Usage: $0 <branch-name>"; exit 1; }

BUILD_HOST="root@projectmellon.de"
BUILD_DIR="/tmp/openclaw-build-test"
TAG="openclaw-test:${BRANCH//\//-}"           # feat/himalaya → openclaw-test:feat-himalaya
TEST_PORT=18790

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "Building test image for branch '$BRANCH'..."

# ── Get Dockerfile + context from the branch ──────────────────────
git fetch origin "$BRANCH"
git checkout "origin/$BRANCH" -- Dockerfile ssh_config
mv Dockerfile ssh_config /tmp/test-build/
git checkout main -- Dockerfile ssh_config  # restore

# ── Build on projectmellon.de ─────────────────────────────────────
scp -q /tmp/test-build/Dockerfile /tmp/test-build/ssh_config "$BUILD_HOST:$BUILD_DIR/"
ssh "$BUILD_HOST" "cd $BUILD_DIR && docker build -t $TAG ."

# ── Transfer ──────────────────────────────────────────────────────
log "Transferring test image..."
ssh "$BUILD_HOST" "docker save $TAG | gzip" | docker load

# ── Start test container ──────────────────────────────────────────
log "Starting test container on port $TEST_PORT..."

# Stop any previous test container
docker rm -f openclaw-test 2>/dev/null || true

docker run -d --name openclaw-test \
    -p "127.0.0.1:$TEST_PORT:18789" \
    -v "$(pwd)/config:/home/node/.openclaw:ro" \
    -v "$(pwd)/workspace:/home/node/.openclaw/workspace:ro" \
    --network caddy_default \
    -e OPENCLAW_GATEWAY_BIND=lan \
    --env-file config/.env \
    "$TAG"

# Wait for healthy
log "Waiting for test container..."
for i in $(seq 1 20); do
    if curl -sf "http://127.0.0.1:$TEST_PORT/healthz" > /dev/null 2>&1; then
        log "Test container HEALTHY on :$TEST_PORT"
        break
    fi
    sleep 2
done

echo ""
echo "═══ Test Image Ready ═══"
echo "  Image: $TAG"
echo "  Port:  $TEST_PORT"
echo "  Logs:  docker logs -f openclaw-test"
echo ""
echo "Test it: curl http://127.0.0.1:$TEST_PORT/healthz"
echo ""
echo "When done:"
echo "  Promote: docker tag $TAG openclaw-local:latest && docker compose up -d openclaw"
echo "  Cleanup: docker rm -f openclaw-test"
