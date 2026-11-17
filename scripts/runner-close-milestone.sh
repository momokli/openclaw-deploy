#!/bin/bash
# runner-close-milestone.sh <milestone-number> — schließt EINEN Milestone, aber nur
# wenn er wirklich code-complete ist. Wird vom Release-Pfad (pr-gate) aufgerufen,
# nachdem der Release gemergt und getaggt wurde.
#
# ── Warum ────────────────────────────────────────────────────────────────────
# Der Prompt sagte bisher „danach den Milestone schließen" — bedingungslos. Real:
# am 2026-11-16 wurde `music-api-0.5.0` (#44) zehn Sekunden nach dem Release
# geschlossen, mit DREI offenen Leaf-Issues (#512/#513/#518). Danach gab es keinen
# freigegebenen Milestone mit Arbeit mehr, also standen beide Runner still.
#
# ── Regel ────────────────────────────────────────────────────────────────────
# Schließen nur, wenn KEIN offenes Leaf-Issue existiert und KEIN offener,
# ungemergter PR auf ein offenes Issue zeigt. Geparkte Reste (HOLD-Labels, Epics,
# `needs:manual-test`, `question`) blockieren NICHT — sie werden beim Schließen
# protokolliert. Sonst bliebe ein Milestone mit einem einzigen geparkten Issue für
# immer offen und würde die Queue verstopfen.
#
# Die Leaf-Definition ist absichtlich identisch zu runner-focus-milestone.sh
# (`has_open_leaves`), damit „code-complete" überall dasselbe heißt.
#
# Ausgabe: CLOSE <n> <title> [geparkt: …] | KEEP <n> <title> (Grund) | SKIP …
# Exit: 0 = OK (auch bei KEEP) · 2 = Usage/Setup · 3 = API-Fehler
set -uo pipefail

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) PATH="$HOME/.local/bin:$PATH" ;;
esac

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/runner-profile.sh"

REPO="$RUNNER_REPO"
GH="${RIFT_GH:-$RUNNER_A_GH}"

log() { printf '%s %s-close-milestone: %s\n' "$(date -Is)" "$RUNNER_STATE_PREFIX" "$*"; }

MN="${1:-}"
case "$MN" in
  ''|*[!0-9]*) log "FEHLER Usage: runner-close-milestone.sh <milestone-number>"; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { log "FEHLER jq nicht im PATH"; exit 2; }
command -v "$GH" >/dev/null 2>&1 || { log "FEHLER $GH nicht im PATH"; exit 2; }

HOLD_JSON="$(printf '%s' "$RUNNER_HOLD_LABELS" | jq -R 'split(" ") | map(select(length > 0))')"

MS="$("$GH" api "repos/$REPO/milestones?state=all&per_page=100" 2>/dev/null)" \
  || { log "FEHLER milestones lesen fehlgeschlagen ($REPO)"; exit 3; }

TITLE="$(printf '%s' "$MS" | jq -r --argjson n "$MN" '.[] | select(.number == $n) | .title')"
STATE="$(printf '%s' "$MS" | jq -r --argjson n "$MN" '.[] | select(.number == $n) | .state')"
[ -n "$TITLE" ] || { log "SKIP $MN (Milestone nicht gefunden)"; exit 0; }
case "$STATE" in
  open) ;;
  *) log "SKIP $MN $TITLE (bereits $STATE)"; exit 0 ;;
esac

ISSUES="$("$GH" issue list --repo "$REPO" --milestone "$MN" --state open --limit 100 \
  --json number,title,labels,body 2>/dev/null)" \
  || { log "FEHLER Issues von $MN lesen fehlgeschlagen"; exit 3; }

# Offene Leaf-Issues — dieselbe Definition wie runner-focus-milestone.sh.
LEAVES="$(printf '%s' "$ISSUES" | jq -r --argjson hold "$HOLD_JSON" '
  [ .[]
    | select((.title | test("^\\[(Epic|Umbrella|Milestone|Release|Design)\\]"; "i")) | not)
    | select(( (.title | test("^\\[Spike\\]"; "i"))
               and (([.labels[].name] | index("triage:research")) == null) ) | not)
    | select(([.labels[].name] | any(. as $l | $hold | index($l))) | not)
    | select(( (([.labels[].name] | index("research")) != null)
               and (([.labels[].name] | index("triage:research")) == null) ) | not)
    | select((.body // "" | [scan("(?m)^[ \t]*- \\[ \\][ \t]*#[0-9]+")] | length) < 2)
    | .number ] | sort | map("#" + tostring) | join(" ")')"

OPEN_ALL="$(printf '%s' "$ISSUES" | jq -r '[.[].number] | sort | map("#" + tostring) | join(" ")')"

if [ -n "$LEAVES" ]; then
  log "KEEP $MN $TITLE — offene Leaf-Issues: $LEAVES (bleibt offen; sonst verliert der Fokus die Arbeit)"
  exit 0
fi

PRS="$("$GH" pr list --repo "$REPO" --state open --limit 200 \
  --json number,title,body,headRefName 2>/dev/null)" \
  || { log "FEHLER PR-Liste lesen fehlgeschlagen"; exit 3; }

# Ein offener, ungemergter PR auf ein offenes Issue heißt: nicht code-complete.
OPEN_PR="$(printf '%s' "$PRS" | jq -r --argjson issues "$ISSUES" '
  def refs: ((.title // "") + " " + (.body // "") + " " + (.headRefName // ""))
            | [scan("#([0-9]+)")] | flatten | map(tonumber);
  [ $issues[].number ] as $focus
  | [ .[] | select(refs | any(. as $n | $focus | index($n))) ] | .[0].number // empty')"

if [ -n "$OPEN_PR" ]; then
  log "KEEP $MN $TITLE — offener, ungemergter PR #$OPEN_PR auf ein offenes Issue (nicht code-complete)"
  exit 0
fi

if "$GH" api -X PATCH "repos/$REPO/milestones/$MN" -f state=closed >/dev/null 2>&1; then
  log "CLOSE $MN $TITLE — geparkte offene Issues bleiben zurück: ${OPEN_ALL:-keine}"
else
  log "FEHLER Schließen von $MN fehlgeschlagen"
  exit 3
fi
