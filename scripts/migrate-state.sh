#!/bin/bash
# Migrate OpenClaw runtime state from config/ (old bind mount) to named volumes
set -euo pipefail

DEPLOY_DIR="/opt/apps/openclaw"
RUNTIME_DIRS=(state credentials devices npm identity logs media plugin-skills skill-workshop agents)

log() { echo "[migrate] $*"; }

log "Stopping OpenClaw container..."
cd "$DEPLOY_DIR"
docker compose stop openclaw 2>/dev/null || true

log "Creating named volumes..."
docker volume create openclaw_home >/dev/null 2>&1 || true
docker volume create openclaw_workspace >/dev/null 2>&1 || true

log "Migrating runtime state from config/ to openclaw_home volume..."
for dir in "${RUNTIME_DIRS[@]}"; do
    if [ -d "$DEPLOY_DIR/config/$dir" ]; then
        log "  migrating $dir/ ..."
        docker run --rm \
            -v "$DEPLOY_DIR/config/$dir:/src:ro" \
            -v openclaw_home:/dst \
            alpine sh -c "mkdir -p /dst/$dir && cp -a /src/. /dst/$dir/" 2>/dev/null || true
    fi
done

# Migrate workspace runtime state
if [ -d "$DEPLOY_DIR/workspace" ]; then
    log "Migrating workspace runtime state..."
    docker run --rm \
        -v "$DEPLOY_DIR/workspace:/src:ro" \
        -v openclaw_workspace:/dst \
        alpine sh -c "mkdir -p /dst && cp -a /src/. /dst/" 2>/dev/null || true
fi

log "Migration complete."
