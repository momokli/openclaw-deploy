#!/bin/bash
# rift-focus-milestone.sh — Fokus-Milestone für die rift-*-Runner (A/B) bestimmen.
#
# ── Regel ───────────────────────────────────────────────────────────────────
#   Fokus = kleinster OFFENER Milestone, dessen Titel eine Versionsform ist
#           (Default-Pattern: <major>.<minor>[.<patch>]).
#     • version-sortiert, NICHT nach Milestone-Nummer  →  1.0.1 < 1.1 < 1.2
#     • Parkplätze wie `soon` fallen raus (Titel ist keine Version)
#     • Ein Fokus-Milestone mit 0 offenen Issues wird NICHT übersprungen: er
#       meldet open_issues=0, damit der Runner wartet („Fokus erschöpft") statt
#       in die nächste Iteration vorzujubeln. Den Fokus wechselt der Mensch —
#       durch SCHLIESSEN des Milestones.
#
# Damit steht kein Milestone-Name mehr im Triage-/Gate-Prompt; der Prompt ruft
# nur noch dieses Script auf und arbeitet mit dem Ergebnis.
#
# ── Ausgabe ─────────────────────────────────────────────────────────────────
#   (default)  <title>                                    z. B. 1.0.1
#   --json     {"title":"1.0.1","number":12,"open_issues":11,"description":"…"}
#              (description = Milestone-Text; der Runner liest daraus die
#               Dispatch-Reihenfolge als Checkliste `- [ ] #NNN`)
#   --list     alle Kandidaten aufsteigend, je Zeile:
#              <title> number=<n> open_issues=<n>
#   --dry-run  wie default (das Script mutiert nie — es liest nur)
#
# Exit: 0 = Fokus gefunden · 2 = Usage · 3 = API-/JSON-Fehler · 4 = kein Kandidat
#
# Nutzung (Gateway, Runtime-User; `clanker-gh` = Bot-Identity momo-clanker[bot]):
#   rift-focus-milestone.sh
#   rift-focus-milestone.sh --json
#   rift-focus-milestone.sh --list
#
# Deployment: per Setup auf .149 installiert (wie rift-stale-dispatch.sh), damit
# die Automation es per bloßem Namen aufrufen kann.

set -euo pipefail

# Die Bot-Wrapper (clanker-gh) liegen in ~/.local/bin. In nicht-interaktiven
# Shells (cron/exec/ssh) fehlt das dort oft im PATH — selbst heilen, damit der
# Bare-Name-Aufruf aus dem Prompt zuverlaessig funktioniert.
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) PATH="$HOME/.local/bin:$PATH" ;;
esac

REPO="${RIFT_REPO:-momokli/riftbreaker-battle-mod}"
GH="${GH_BIN:-clanker-gh}"
PATTERN="${RIFT_FOCUS_PATTERN:-^[0-9]+\.[0-9]+(\.[0-9]+)?$}"
MODE="title"
LIST=0

usage() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --json) MODE="json" ;;
    --list) LIST=1 ;;
    --dry-run) : ;;                       # das Script mutiert nie
    -h|--help) usage; exit 0 ;;
    *) echo "rift-focus-milestone: unbekanntes Argument: $1" >&2; exit 2 ;;
  esac
  shift
done

raw="$("$GH" api "repos/$REPO/milestones?state=open&per_page=100" 2>/dev/null)" || {
  echo "rift-focus-milestone: gh api repos/$REPO/milestones fehlgeschlagen" >&2
  exit 3
}

json="$(printf '%s' "$raw" | jq -c '[.[] | {title, number, open_issues, description}]' 2>/dev/null)" || {
  echo "rift-focus-milestone: unerwartete API-Antwort (kein JSON-Array)" >&2
  exit 3
}

# Kandidaten: Versions-Titel, aufsteigend version-sortiert.
ordered="$(printf '%s' "$json" \
  | jq -r --arg pat "$PATTERN" '.[] | select(.title | test($pat)) | .title' \
  | sort -V)"

if [ -z "$ordered" ]; then
  echo "rift-focus-milestone: kein offener Milestone mit Versions-Titel (pattern=$PATTERN)" >&2
  exit 4
fi

if [ "$LIST" = 1 ]; then
  while IFS= read -r t; do
    printf '%s' "$json" | jq -r --arg t "$t" '.[] | select(.title == $t) | "\(.title) number=\(.number) open_issues=\(.open_issues)"'
  done <<< "$ordered"
  exit 0
fi

focus="$(printf '%s' "$ordered" | head -1)"

case "$MODE" in
  json) printf '%s' "$json" | jq -c --arg t "$focus" \
          '.[] | select(.title == $t) | {title, number, open_issues, description: (.description // "")}' ;;
  *)    printf '%s\n' "$focus" ;;
esac
