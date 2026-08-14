#!/bin/bash
# Test an OpenClaw image from a feature branch without disturbing main.
# Builds locally from a git worktree (no scp/save-load to projectmellon),
# then runs an isolated container with separate runtime volumes.
#
# Usage: ./scripts/test-branch.sh <branch-name>
# Example: ./scripts/test-branch.sh feat/himalaya

set -euo pipefail
BRANCH="${1:-}"
[ -z "$BRANCH" ] && { echo "Usage: $0 <branch-name>"; exit 1; }

SAFE="$(echo "$BRANCH" | tr '/' '-')"                 # feat/himalaya → feat-himalaya
TAG="openclaw-test:$SAFE"
WORKTREE="/tmp/openclaw-test-$SAFE"
TEST_PORT=18790
DEPLOY_DIR="$(cd "$(dirname "$0")/.." && pwd)"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "Fetching branch '$BRANCH'..."
git fetch origin "$BRANCH"

log "Building test image from branch (git worktree)..."
git worktree remove --force "$WORKTREE" 2>/dev/null || true
git worktree add --detach "$WORKTREE" "origin/$BRANCH"
trap 'git worktree remove --force "$WORKTREE" 2>/dev/null || true' EXIT

docker build -t "$TAG" "$WORKTREE"

log "Starting test container on port $TEST_PORT..."
docker rm -f openclaw-test 2>/dev/null || true

# Separate runtime volumes — production state is never touched
docker volume create openclaw_test_home >/dev/null 2>&1 || true
docker volume create openclaw_test_workspace >/dev/null 2>&1 || true

docker run -d --name openclaw-test \
    -p "127.0.0.1:$TEST_PORT:18789" \
    -v "$DEPLOY_DIR/config:/openclaw-config:ro" \
    -v "$DEPLOY_DIR/workspace:/openclaw-config/workspace:ro" \
    -v openclaw_test_home:/home/node/.openclaw \
    -v openclaw_test_workspace:/home/node/.openclaw/workspace \
    -v /opt/apps/lab:/lab:ro \
    -v "${HOME}/.ssh/id_ed25519:/home/node/.ssh/id_ed25519:ro" \
    -e OPENCLAW_GATEWAY_BIND=lan \
    -e OPENCLAW_ALLOW_INSECURE_PRIVATE_WS=true \
    --env-file "$DEPLOY_DIR/config/.env" \
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
echo "  Cleanup: docker rm -f openclaw-test"
