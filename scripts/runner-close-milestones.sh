#!/bin/bash
# runner-close-milestones.sh — schließt offene Milestones, die fertig UND ausgeliefert sind.
# Repo-Bindung kommt aus dem Runner-Profil (`RUNNER_PROFILE`, Default: rift).
#
# Ein Milestone mit 0 offenen Issues ist code-complete. Der Release-Pfad (pr-gate)
# schließt ihn beim Release. Bleibt er trotzdem offen (Legacy, oder der Release-Pfad
# hat ihn nie erreicht), ist das reine Buchhaltung — hier deterministisch, 0 Tokens.
#
# SICHERHEIT: NICHT schließen, wenn ein OFFENER Release-PR (`release/<titel>`,
# Label `release:auto`/`release:human-merge`) existiert — dann wartet der Milestone
# auf seinen Release (Mensch/Stack); Schließen würde ihn überspringen. Nur wirklich
# ausgelieferte/verwaiste Milestones werden geschlossen.
#
# Ausgabe: CLOSE <n> <title> | SKIP <n> <title> (offener Release-PR) | summary …
# Exit: 0 = OK · 2 = Fehler (gh/jq) · 3 = API-Fehler
set -uo pipefail

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) PATH="$HOME/.local/bin:$PATH" ;;
esac

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/runner-profile.sh"

REPO="$RUNNER_REPO"
GH="${RIFT_GH:-$RUNNER_A_GH}"
RELEASE_LABEL="$RUNNER_RELEASE_LABEL"

log() { printf '%s %s-close-milestones: %s\n' "$(date -Is)" "$RUNNER_STATE_PREFIX" "$*"; }

command -v "$GH" >/dev/null 2>&1 || { log "FEHLER $GH nicht im PATH"; exit 2; }
command -v jq >/dev/null 2>&1 || { log "FEHLER jq nicht im PATH"; exit 2; }

MS="$("$GH" api "repos/$REPO/milestones?state=open&per_page=100" 2>/dev/null)" \
  || { log "FEHLER milestones lesen fehlgeschlagen ($REPO)"; exit 3; }

# Offene Release-PRs → Milestone wartet auf seinen Release (nicht schließen).
OPEN_REL="$("$GH" pr list --repo "$REPO" --state open --limit 200 \
  --json headRefName,labels 2>/dev/null \
  | jq -r --arg rel "$RELEASE_LABEL" '
      .[] | select(any(.labels[]?; .name == $rel))
          | select((.headRefName // "") | startswith("release/"))
          | (.headRefName | sub("^release/"; ""))' 2>/dev/null)" || OPEN_REL=""

CLOSED=0
SKIPPED=0
for n in $(printf '%s' "$MS" | jq -r '.[] | select(.open_issues == 0) | .number'); do
  t="$(printf '%s' "$MS" | jq -r --argjson n "$n" '.[] | select(.number == $n) | .title')"
  if [ -n "$OPEN_REL" ] && printf '%s\n' "$OPEN_REL" | grep -qxF "$t"; then
    log "SKIP $n $t (offener Release-PR — wartet auf Release)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  if "$GH" api -X PATCH "repos/$REPO/milestones/$n" -f state=closed >/dev/null 2>&1; then
    log "CLOSE $n $t"
    CLOSED=$((CLOSED + 1))
  else
    log "WARNUNG: Milestone $n nicht schließbar"
  fi
done

log "summary closed=$CLOSED skipped=$SKIPPED"
