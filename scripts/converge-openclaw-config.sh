#!/bin/bash
# converge-openclaw-config.sh — deklarative Config → Runtime-Config
# OHNE die von OpenClaw selbst verwalteten Runtime-Felder zu zerstören.
#
# Hintergrund (OpenClaw-Doku, "Configuration" / "Strict validation"):
#   - OpenClaw ersetzt ~/.openclaw/openclaw.json ATOMAR (rename auf den Pfad).
#   - Beim Start/Migration schreibt OpenClaw eigene Felder in diese Datei:
#       auth.profiles / auth.order        (Model-Auth, z. B. deepseek:manual)
#       plugins.entries / plugins.enabled (installierte/aktivierte Plugins)
#       meta.migrations                   (Startup-Legacy-Key-Migrationen)
#       agents.entries.<id>.{agentDir,identity,name}  (auto-generierte Identity)
#       skills.entries["gh-issues"].apiKey  (frischer Token, ghs_…/PAT)
#   - Ein blindes copy/install der git-Config würde diese Felder löschen UND
#     von OpenClaw als "accidental clobber" abgelehnt werden (Datei schrumpft
#     um mehr als die Hälfte).
#
# Deshalb: git-Config ist Source-of-Truth für alle DEKLARATIVEN Felder;
# eine kleine explizite Deny-Liste übernimmt die Runtime-Felder aus der
# bestehenden Runtime-Config. Ergebnis wird atomar (temp + mv) geschrieben,
# Owner/Mode wie OpenClaw selbst (Runtime-User, 600).
#
# Nutzung (als root): sudo bash scripts/converge-openclaw-config.sh [RUN_USER] [GIT_CONFIG]
#   RUN_USER   = Runtime-User (Default: momo). NICHT root.
#   GIT_CONFIG = deklarative Config (Default: /opt/apps/openclaw/config/openclaw.json)

set -euo pipefail

RUN_USER="${1:-momo}"
GIT_CONFIG="${2:-/opt/apps/openclaw/config/openclaw.json}"

STATE_DIR="$(getent passwd "$RUN_USER" | cut -d: -f6)/.openclaw"
RT_CONFIG="$STATE_DIR/openclaw.json"

log() { echo "[converge-openclaw-config] $*"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "Bitte als root ausfuehren: sudo bash $0 $RUN_USER $GIT_CONFIG" >&2
    exit 1
fi
[ -f "$GIT_CONFIG" ] || { echo "GIT_CONFIG fehlt: $GIT_CONFIG" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq fehlt auf dem Host" >&2; exit 1; }
jq -e . "$GIT_CONFIG" >/dev/null 2>&1 || { echo "GIT_CONFIG ist kein valides JSON: $GIT_CONFIG" >&2; exit 1; }

# ── Bootstrap: noch keine Runtime-Config → git-Config 1:1 übernehmen ──────
if [ ! -f "$RT_CONFIG" ]; then
    log "keine Runtime-Config — Bootstrap aus $GIT_CONFIG"
    install -m 600 -o "$RUN_USER" -g "$RUN_USER" "$GIT_CONFIG" "$RT_CONFIG"
    echo "status=changed"
    exit 0
fi

# Fail-closed: Runtime-Config muss parsebar sein, sonst können wir die
# Runtime-Felder nicht sicher erhalten (JSON5 mit Kommentaren wird hier
# bewusst NICHT stillschweigend überschrieben).
if ! jq -e . "$RT_CONFIG" >/dev/null 2>&1; then
    echo "Runtime-Config ist kein valides JSON: $RT_CONFIG" >&2
    echo "Bitte zuerst bereinigen (openclaw doctor --fix) und erneut ausführen." >&2
    exit 1
fi

# ── Merge: git = Basis, Runtime-Felder aus bestehender Config übernehmen ──
MERGED="$(jq -n \
    --slurpfile g "$GIT_CONFIG" \
    --slurpfile r "$RT_CONFIG" '
    ($g[0]) as $git
    | ($r[0] // {}) as $rt
    | $git
    # 1. auth (profiles/order) — runtime-managed, nicht in git
    | (if ($rt | has("auth"))    then .auth    = $rt.auth    else . end)
    # 2. plugins (entries/enabled/allow/deny) — runtime-managed
    | (if ($rt | has("plugins")) then .plugins = $rt.plugins else . end)
    # 3. meta.migrations — Startup-Migrationen (git behält meta.lastTouchedVersion)
    | (if ($rt.meta.migrations?) then .meta.migrations = $rt.meta.migrations else . end)
    # 4. per-Agent-Identity (agentDir/identity/name) — runtime-generiert
    | (.agents.entries // {}) as $ge
    | ($rt.agents.entries // {}) as $re
    | .agents.entries = (
        reduce ($ge | keys[]) as $id ({};
          .[$id] = $ge[$id]
          | (if $re[$id].agentDir then .[$id].agentDir = $re[$id].agentDir else . end)
          | (if $re[$id].identity then .[$id].identity = $re[$id].identity else . end)
          | (if $re[$id].name     then .[$id].name     = $re[$id].name     else . end)
        )
      )
    # 5. gh-issues-Token — Runtime schreibt frischen Token (ghs_… bzw. PAT)
    | (if ((($rt.skills.entries["gh-issues"].apiKey? // null) | type) == "string")
          and ((($rt.skills.entries["gh-issues"].apiKey? // "") | length) > 0)
       then .skills.entries["gh-issues"].apiKey = $rt.skills.entries["gh-issues"].apiKey
       else . end)
')"

# ── Idempotenz: nur schreiben, wenn sich der Inhalt semantisch geändert hat ──
RT_NORM="$(jq -S -c . "$RT_CONFIG")"
MERGED_NORM="$(printf '%s\n' "$MERGED" | jq -S -c .)"

if [ "$MERGED_NORM" = "$RT_NORM" ]; then
    log "Config unverändert — nichts zu tun"
    echo "status=unchanged"
    exit 0
fi

# Atomar schreiben (temp + mv), Owner/Mode wie OpenClaw selbst (momo, 600).
TMP="$(mktemp "$STATE_DIR/.openclaw.json.converge.XXXXXX")"
printf '%s\n' "$MERGED" > "$TMP"
chown "$RUN_USER":"$RUN_USER" "$TMP"
chmod 600 "$TMP"
mv "$TMP" "$RT_CONFIG"
log "Config converged (Runtime-Felder erhalten)"
echo "status=changed"
