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
SELF="$LOCAL_DIR/scripts/build-and-deploy.sh"
SELF_BEFORE="$(sha256sum "$SELF" 2>/dev/null | cut -d' ' -f1 || true)"
git pull origin main
# Re-exec if this deploy script itself was updated by the pull above. bash
# keeps the OLD file open while executing; `git pull` atomically replaces the
# file, so without this we'd finish the run on stale logic (one deploy behind).
if [ "$(sha256sum "$SELF" 2>/dev/null | cut -d' ' -f1 || true)" != "$SELF_BEFORE" ]; then
    log "deploy script self-updated — re-executing"
    exec bash "$SELF" "$@"
fi

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

# ── 3b. Runtime-state migrations (idempotent, writers stopped) ──
# Upgrades (e.g. 2026.7.1 → 2026.8.1) need `openclaw doctor --fix` against the
# state volumes (agent-DB schema, session store, exec-approvals, device
# identity, …). It runs BEFORE `docker compose up`, so the gateway is stopped.
# Also clear a stale `startup-migrations` lease left by a previously SIGTERM'd
# gateway, which would otherwise block the next boot for its ~5 min TTL.
log "Clearing stale startup-migrations lease..."
"$LOCAL_DIR/scripts/clear-openclaw-lease.sh" 2>/dev/null || true

log "Running state migrations (doctor --fix)..."
if docker run --rm -u node \
    -e HOME=/home/node \
    -e OPENCLAW_STATE_DIR=/home/node/.openclaw \
    -v openclaw_home:/home/node/.openclaw \
    -v openclaw_workspace:/home/node/.openclaw/workspace \
    -v "$LOCAL_DIR/config:/openclaw-config:ro" \
    --env-file "$LOCAL_DIR/config/.env" \
    --entrypoint sh "$IMAGE" -c \
    'cp /openclaw-config/openclaw.json /home/node/.openclaw/openclaw.json && exec openclaw doctor --fix --non-interactive' \
    > "$LOCAL_DIR/.doctor-fix.log" 2>&1; then
    log "doctor --fix OK"
else
    log "WARN: doctor --fix exited non-zero (see .doctor-fix.log) — continuing, health check will fail-closed"
fi

# ── 4. Swap containers — recreate so entrypoint re-copies config ──
# Clean up stale EXITED openclaw containers first: leftovers from old
# compose project names caused "container name ... already in use".
docker ps -aq --filter name=openclaw --filter status=exited | xargs -r docker rm -f 2>/dev/null || true

docker compose up -d --force-recreate --remove-orphans openclaw obsidian-sync ollama

# ── 5. Ensure ollama embedding model is present (idempotent) ─────
for i in $(seq 1 15); do
    if docker exec openclaw-ollama ollama list > /dev/null 2>&1; then break; fi
    sleep 2
done
if ! docker exec openclaw-ollama ollama list 2>/dev/null | grep -q "nomic-embed-text"; then
    log "Pulling embedding model nomic-embed-text..."
    docker exec openclaw-ollama ollama pull nomic-embed-text || log "WARN: embedding model pull failed"
fi

# ── 6. Wait for healthy (fail-closed) ───────────────────────────
# The entrypoint runs openclaw CLI steps (auth seeding, plugin ensure) before
# the gateway binds its HTTP port, so startup can take up to ~2 min on a cold
# boot. Give it a generous window before declaring failure.
# Health wait with one restart retry as convergence safety net (first boot after
# an image upgrade may need a restart to settle; see PR #7).
HEALTHY=0
for attempt in 1 2; do
    HEALTHY=0
    for i in $(seq 1 45); do
        if docker exec openclaw curl -sf http://localhost:18789/healthz > /dev/null 2>&1; then
            HEALTHY=1
            log "Container healthy"
            break
        fi
        sleep 2
    done
    if [ "$HEALTHY" = "1" ]; then
        break
    fi
    if [ "$attempt" = "1" ]; then
        log "Gateway not healthy after first window — one restart for first-boot convergence"
        docker restart openclaw >/dev/null 2>&1 || true
        sleep 10
    fi
done

if [ "$HEALTHY" != "1" ]; then
    log "ERROR: gateway did not become healthy — aborting (hashes not persisted)"
    exit 1
fi

# ── 7. Reconnect to Caddy network (idempotent) ──────────────────
docker network connect caddy_default openclaw 2>/dev/null || true

# ── 8. Persist hashes ───────────────────────────────────────────
echo "$NEW_GIT" > "$GIT_HASH_FILE"
echo "$NEW_IMG" > "$IMG_HASH_FILE"
echo "$NEW_OBSIDIAN_IMG" > "$OBSIDIAN_IMG_HASH_FILE"
log "Deploy complete"
