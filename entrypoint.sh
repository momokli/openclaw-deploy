#!/bin/sh
# OpenClaw entrypoint: sync git config into runtime home, then start gateway
set -e

SRC="/openclaw-config"
HOME_DIR="/home/node/.openclaw"

log() { echo "[entrypoint] $*"; }

# 1. Gateway config — copy from git if changed
if [ -f "$SRC/openclaw.json" ]; then
    if ! cmp -s "$SRC/openclaw.json" "$HOME_DIR/openclaw.json" 2>/dev/null; then
        cp "$SRC/openclaw.json" "$HOME_DIR/openclaw.json"
        log "openclaw.json updated"
    fi
fi

# 2. Secrets — copy .env into home (OpenClaw reads it there too)
if [ -f "$SRC/.env" ]; then
    cp "$SRC/.env" "$HOME_DIR/.env"
    chmod 600 "$HOME_DIR/.env"
fi

# 3. Agent personas — map flat git files to per-agent WORKSPACE AGENTS.md.
#    (OpenClaw only injects bootstrap files from the agent workspace, NOT agentDir.)
for f in "$SRC"/agents/*.md; do
    [ -f "$f" ] || continue
    base="$(basename "$f" .md)"
    if [ "$base" = "orchestrator" ]; then
        id="coding-orchestrator"
    else
        id="feature-dev-$base"
    fi
    mkdir -p "$HOME_DIR/workspaces/$id"
    cp "$f" "$HOME_DIR/workspaces/$id/AGENTS.md"
done
log "agent personas synced"

# 4. Main agent personas — ALWAYS copy from git (source of truth).
#    MEMORY.md is seeded only if missing (agent writes to it at runtime).
#    Explicit list (not a glob) so runtime files like HEARTBEAT/IDENTITY/TOOLS
#    in the workspace are never overwritten from git.
mkdir -p "$HOME_DIR/workspace"
for base in SOUL.md AGENTS.md USER.md MEMORY.md; do
    f="$SRC/workspace/$base"
    [ -f "$f" ] || continue
    if [ "$base" = "MEMORY.md" ]; then
        [ -f "$HOME_DIR/workspace/$base" ] || cp "$f" "$HOME_DIR/workspace/$base"
    else
        cp "$f" "$HOME_DIR/workspace/$base"
    fi
done

# 5. Ensure runtime home is owned by node (entrypoint runs as root)
chown -R node:node "$HOME_DIR" 2>/dev/null || true
chown -R node:node "$HOME_DIR/workspace" 2>/dev/null || true
chown -R node:node "$HOME_DIR/workspaces" 2>/dev/null || true

# 5b. Seed DeepSeek auth profile on main so sub-agents inherit via read-through.
#     env-only auth does NOT reach sub-agent model auth (they resolve through
#     their own store + read-through to main's store), so persist the key once.
if [ -n "$DEEPSEEK_API_KEY" ]; then
    if ! gosu node openclaw models auth list --agent main --provider deepseek 2>/dev/null | grep -q 'deepseek:'; then
        if printf '%s\n' "$DEEPSEEK_API_KEY" | gosu node openclaw models auth --agent main paste-api-key --provider deepseek; then
            log "seeded deepseek auth profile on main"
        else
            log "WARN: failed to seed deepseek auth profile on main"
        fi
    else
        log "deepseek auth profile already present on main"
    fi
fi

# 5c. Seed gh auth so coding agents can `git push` (HTTPS) and `gh pr create`.
#     env-only GH_TOKEN does NOT reach exec shells reliably; persist the
#     login once via hosts.yml, then wire up git's credential helper.
#     NOTE: `gh auth login --with-token` VALIDATES the token and fails with
#     "missing required scope 'read:org'" for tokens without org access;
#     writing hosts.yml directly skips that validation (token still works).
if [ -n "$GH_TOKEN" ]; then
    if [ ! -f /home/node/.config/gh/hosts.yml ]; then
        GH_USER="$(GH_TOKEN="$GH_TOKEN" gh api user --jq '.login' 2>/dev/null || echo momokli)"
        mkdir -p /home/node/.config/gh
        cat > /tmp/gh-hosts.yml <<EOF
github.com:
    users:
        $GH_USER:
            oauth_token: $GH_TOKEN
    oauth_token: $GH_TOKEN
    user: $GH_USER
    git_protocol: https
EOF
        # entrypoint runs as root; gh runs as node — install with node ownership
        install -o node -g node -m 600 /tmp/gh-hosts.yml /home/node/.config/gh/hosts.yml
        rm -f /tmp/gh-hosts.yml
        log "seeded gh auth (github.com as $GH_USER)"
    else
        log "gh auth already present"
    fi
    if gosu node gh auth setup-git --hostname github.com; then
        log "gh credential helper configured for github.com"
    else
        log "WARN: failed to configure gh credential helper"
    fi
    if ! gosu node gh auth status >/dev/null 2>&1; then
        log "WARN: gh is NOT authenticated — check GH_TOKEN format/scope"
    fi
else
    log "WARN: GH_TOKEN not set — gh CLI / git HTTPS will fail"
fi

# 6. Start gateway as node (original entrypoint: tini)
exec gosu node tini -s -- "$@"
