#!/bin/bash
# Native OpenClaw-Setup.
# Idempotent: kann mehrfach laufen. Richtet ein: OpenClaw-Install, Config-Sync,
# Secrets (.env), Provider-Plugins, git-Identity, Gateway-Service.
#
# Nutzung:  sudo bash scripts/setup-native.sh [RUN_USER]
#   RUN_USER  = User, unter dem der Gateway läuft (Default: momo). NICHT root.

set -euo pipefail

RUN_USER="${1:-momo}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # openclaw-deploy Repo-Root
CONFIG_SRC="$REPO_DIR/config/openclaw.json"
ENV_SRC="$REPO_DIR/config/.env"
OPENCLAW_VERSION="2026.8.1"

log() { echo "[setup-native] $*"; }

if [ "$(id -u)" -ne 0 ]; then
    log "Bitte als root ausführen (sudo bash scripts/setup-native.sh $RUN_USER)"
    exit 1
fi
if ! id "$RUN_USER" >/dev/null 2>&1; then
    log "User '$RUN_USER' existiert nicht."; exit 1
fi

# ── 1. Node + OpenClaw installieren (headless, ohne Onboarding) ────────────
if ! command -v openclaw >/dev/null 2>&1; then
    log "Installiere OpenClaw (install.sh --no-onboard)..."
    curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard
else
    log "openclaw vorhanden: $(openclaw --version 2>/dev/null | head -1)"
fi

NODE_VER="$(node -v 2>/dev/null || echo 'missing')"
log "Node: $NODE_VER (benötigt >=24.16 oder >=26.1)"

# ── 2. Runtime-Home + Config-Sync ──────────────────────────────────────────
HOME_DIR="$(getent passwd "$RUN_USER" | cut -d: -f6)"
STATE_DIR="$HOME_DIR/.openclaw"
mkdir -p "$STATE_DIR"
chown "$RUN_USER":"$RUN_USER" "$STATE_DIR"

# Config kopieren (kein Symlink — OpenClaw ersetzt atomar). Alternativ:
# OPENCLAW_CONFIG_PATH=$CONFIG_SRC im Service setzen; hier bewusst Kopie für
# klare Trennung "git = read-only source" vs "runtime = ~/.openclaw".
log "Sync openclaw.json -> $STATE_DIR/openclaw.json"
install -m 600 -o "$RUN_USER" -g "$RUN_USER" "$CONFIG_SRC" "$STATE_DIR/openclaw.json"

# ── 3. Secrets -> ~/.openclaw/.env (gitignored, NICHT im Repo) ─────────────
if [ -f "$ENV_SRC" ]; then
    log "Sync secrets -> $STATE_DIR/.env"
    install -m 600 -o "$RUN_USER" -g "$RUN_USER" "$ENV_SRC" "$STATE_DIR/.env"
else
    log "WARN: $ENV_SRC fehlt — .env nicht angelegt (Secrets müssen manuell rein)"
fi

# ── 4. Provider-Plugins (gepinnt auf Version) ──────────────────────────────
log "Installiere Provider-Plugins (gepinnt $OPENCLAW_VERSION)..."
sudo -u "$RUN_USER" -H openclaw plugins install "@openclaw/groq-provider@$OPENCLAW_VERSION" --pin

# ── 5. git-Identity für den Runtime-User (ersetzt gh auth setup-git) ───────
log "Setze git-Identity für $RUN_USER..."
sudo -u "$RUN_USER" -H git config --global user.name "Molty 🦞"
sudo -u "$RUN_USER" -H git config --global user.email "molty@openclaw.simonklimke.de"
sudo -u "$RUN_USER" -H git config --global init.defaultBranch main

# ── 6. Gateway als systemd-User-Service installieren ───────────────────────
log "Installiere Gateway-Service..."
sudo -u "$RUN_USER" -H openclaw gateway install || true
loginctl enable-linger "$RUN_USER" || true

log "Fertig. Nächste Schritte (manuell):"
log "  systemctl --user -M ${RUN_USER}@ enable --now openclaw-gateway.service"
log "  openclaw gateway status"
log "  openclaw doctor && openclaw models status"
