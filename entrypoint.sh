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
    elif [ "$base" = "thinking-orchestrator" ]; then
        id="thinking-orchestrator"
    elif [ "$base" = "planning-orchestrator" ]; then
        id="planning-orchestrator"
    elif [ "$base" = "operator" ]; then
        id="operator"
    elif [ "$base" = "plan-builder" ]; then
        id="plan-builder"
    elif [ "$base" = "researcher" ]; then
        id="researcher"
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

# 4b. Agent skills — copy git-tracked workspace skills (source of truth).
#     OpenClaw discovers skills at <workspace>/skills (highest precedence).
mkdir -p "$HOME_DIR/workspace/skills"
if [ -d "$SRC/workspace/skills" ]; then
    cp -R "$SRC/workspace/skills/." "$HOME_DIR/workspace/skills/"
    log "agent skills synced"
fi

# 5. Ensure runtime home is owned by node (entrypoint runs as root)
chown -R node:node "$HOME_DIR" 2>/dev/null || true
chown -R node:node "$HOME_DIR/workspace" 2>/dev/null || true
chown -R node:node "$HOME_DIR/workspaces" 2>/dev/null || true

# 5b. Seed DeepSeek auth profile on main so sub-agents inherit via read-through.
#     env-only auth does NOT reach sub-agent model auth (they resolve through
#     their own store + read-through to main's store), so persist the key once.
#     Re-seed not only when the profile is absent, but also when it is stale:
#     a rotated key in config/.env leaves the OLD key behind, and a transient
#     provider error can flag the profile "disabled:billing" (cooldown). Both
#     would otherwise shadow the valid env key and fail every turn with a
#     misleading "billing issue" — so detect those and re-seed.
if [ -n "$DEEPSEEK_API_KEY" ]; then
    # OpenClaw masks keys as "<first 8>...<last 8>" in `models status` output.
    masked_env_key="$(printf '%s' "$DEEPSEEK_API_KEY" | sed -E 's/^(.{8}).*(.{8})$/\1...\2/')"
    deepseek_status="$(gosu node openclaw models status --agent main 2>/dev/null | grep 'deepseek:manual=' || true)"
    reseed=0
    if [ -z "$deepseek_status" ]; then
        reseed=1
    elif printf '%s\n' "$deepseek_status" | grep -q 'disabled'; then
        log "deepseek auth profile disabled (cooldown) — re-seeding"
        reseed=1
    elif ! printf '%s\n' "$deepseek_status" | grep -qF "$masked_env_key"; then
        log "deepseek auth profile key stale (rotated) — re-seeding"
        reseed=1
    fi

    if [ "$reseed" = "1" ]; then
        # Remove the stale profile first: paste-api-key alone may leave a
        # "disabled:billing" flag on the existing profile intact.
        gosu node openclaw models auth logout --agent main deepseek:manual --yes >/dev/null 2>&1 || true
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
#
#     MODE A (GitHub App „momo-bot" — migration target): if the app env vars
#     are set, fetch a FRESH installation token (~1h lifetime) via the
#     gh-app-auth.sh helper (baked into the image, /usr/local/bin) and seed
#     hosts.yml from it. The token is short-lived by design: agents re-run
#     `gh-app-auth.sh` whenever a push/gh call returns 401.
#     MODE B (classic PAT — current state): legacy block below, unchanged.
APP_MODE=0
if [ -n "$GH_APP_ID" ] && [ -n "$GH_APP_INSTALLATION_ID" ] && [ -n "$GH_APP_PRIVATE_KEY_FILE" ]; then
    APP_MODE=1
    log "gh auth: GitHub App mode (momo-bot) — fetching fresh installation token"
    if gosu node env GH_APP_ID="$GH_APP_ID" GH_APP_INSTALLATION_ID="$GH_APP_INSTALLATION_ID" \
        GH_APP_PRIVATE_KEY_FILE="$GH_APP_PRIVATE_KEY_FILE" gh-app-auth.sh; then
        log "gh auth seeded via GitHub App (fresh ~1h token)"
    else
        log "WARN: GitHub App auth failed"
    fi
fi

if [ -n "$GH_TOKEN" ]; then
    # Legacy PAT path: seed hosts.yml only if app mode did not already do so
    # (a fresh app token wins over the PAT).
    if [ "$APP_MODE" = "0" ] && [ ! -f /home/node/.config/gh/hosts.yml ]; then
        GH_USER="$(GH_TOKEN="$GH_TOKEN" gh api user --jq '.login' 2>/dev/null || echo momokli)"
        # dir must be node-owned (entrypoint runs as root; gh runs as node)
        install -d -o node -g node -m 700 /home/node/.config/gh
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
    elif [ "$APP_MODE" = "0" ]; then
        log "gh auth already present"
    fi
    if gosu node gh auth setup-git --hostname github.com; then
        log "gh credential helper configured for github.com"
    else
        log "WARN: failed to configure gh credential helper"
    fi
    if ! gosu node gh api user --jq .login >/dev/null 2>&1; then
        log "WARN: gh is NOT authenticated — check token format/scope"
    fi
elif [ "$APP_MODE" = "0" ]; then
    log "WARN: GH_TOKEN not set and GitHub App not configured — gh CLI / git HTTPS will fail"
fi

# 5d. Ensure external provider plugins (deepseek + groq) are installed at the
#     pinned version. Baking them into the image seeds only FRESH volumes;
#     pre-existing volumes (this host) converge here idempotently — no
#     destructive volume wipe. Pinned to the runtime version so plugin and
#     config schema stay in lockstep. Failures are non-fatal: the gateway still
#     starts, just possibly with a stale plugin version.
PLUGIN_LIST="$(gosu node env HOME=/home/node OPENCLAW_STATE_DIR=/home/node/.openclaw openclaw plugins list --json 2>/dev/null || true)"
ensure_plugin() {
    pkg="$1"; id="$2"; ver="$3"
    if printf '%s\n' "$PLUGIN_LIST" \
        | jq -e --arg id "$id" --arg ver "$ver" \
            '.plugins[] | select(.id == $id and .version == $ver)' >/dev/null 2>&1; then
        log "plugin $id@$ver present"
    else
        log "installing plugin $pkg@$ver"
        if gosu node env HOME=/home/node OPENCLAW_STATE_DIR=/home/node/.openclaw \
            openclaw plugins install "$pkg@$ver" --force --accept-capabilities --pin; then
            log "plugin $pkg@$ver installed"
        else
            log "WARN: failed to install $pkg@$ver"
        fi
    fi
}
ensure_plugin "@openclaw/deepseek-provider" "deepseek" "2026.8.1"
ensure_plugin "@openclaw/groq-provider" "groq" "2026.8.1"

# 6. Start gateway as node (original entrypoint: tini)
exec gosu node tini -s -- "$@"
