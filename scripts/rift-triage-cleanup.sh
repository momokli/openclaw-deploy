#!/bin/bash
# Schritt-4-Buchhaltung für `rift-triage`, aber in Shell (0 Tokens).
#
# Schließt Issues im Fokus-Milestone, deren Dispatch **nachweislich erledigt** ist:
#   (0) Label `triage:no-action` (Maschinen-Signal des Workers: kein Deliverable nötig), ODER
#   (a) der LETZTE Kommentar beginnt mit `[ALREADY-DONE]` (Altpfad, vor der Label-Einführung).
#
# Bewusst NICHT dabei: "ein gemergter PR erwähnt das Issue". Eine Cross-Reference entsteht
# schon bei einer bloßen Erwähnung im PR-Text (real: PR #660 erwähnte #623 → falsch geschlossen).
# Der saubere Weg ist `Closes #<n>` im PR (schließt GitHub selbst) + Pflicht-Check in
# `pr-quality.yml`; den Restfall (PR gemergt ohne Closing-Keyword) **parkt** der Guard
# (`question`), statt ihn zu raten.
# Je Issue: `issue close --reason completed` + Label `orchestrator:dispatched` weg.
# Das gibt den WIP=1-Slot frei, ohne einen Model-Turn zu kosten.
#
# Usage: rift-triage-cleanup.sh -m <milestone-title> [--dry-run] [--max N]
#
# Exit 0 = OK (auch wenn nichts zu tun war), 2 = Fehler.
set -uo pipefail

REPO="momokli/riftbreaker-battle-mod"
GH="${RIFT_GH:-clanker-gh}"
DISPATCH_LABEL="orchestrator:dispatched"
MAX=2
DRY=0
TITLE=""

while [ $# -gt 0 ]; do
  case "$1" in
    -m|--milestone) TITLE="$2"; shift 2 ;;
    --dry-run)      DRY=1; shift ;;
    --max)          MAX="$2"; shift 2 ;;
    -h|--help)      sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unbekannte Option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$TITLE" ] || { echo "FEHLER: -m <milestone-title> fehlt" >&2; exit 2; }
command -v "$GH" >/dev/null 2>&1 || { echo "FEHLER: $GH nicht im PATH" >&2; exit 2; }

log() { printf '%s rift-triage-cleanup: %s\n' "$(date -Is)" "$*"; }

# Milestone-Nummer zum Titel (nur offene Milestones).
N="$($GH api "repos/$REPO/milestones?state=open&per_page=100" 2>/dev/null \
     | jq -r --arg t "$TITLE" '.[] | select(.title == $t) | .number' | head -1)"
[ -n "$N" ] || { log "Fokus-Milestone '$TITLE' nicht gefunden"; exit 2; }

ISSUES="$($GH issue list --repo "$REPO" --state open --milestone "$N" \
  --label "$DISPATCH_LABEL" --limit 100 --json number,title,labels 2>/dev/null)" \
  || { log "issue list fehlgeschlagen"; exit 2; }

COUNT="$(printf '%s' "$ISSUES" | jq 'length')"
[ "$COUNT" -gt 0 ] || { log "nichts zu tun (kein offener Dispatch im Fokus)"; exit 0; }

acted=0
for n in $(printf '%s' "$ISSUES" | jq -r '.[].number'); do
  [ "$acted" -lt "$MAX" ] || break

  # Einzelne Seite (per_page=100) wie rift-stale-dispatch.sh: `--paginate` liefert
  # mehrere JSON-Arrays, die jq nicht als eine Liste liest.
  tl="$($GH api "repos/$REPO/issues/$n/timeline?per_page=100" 2>/dev/null)" \
    || { log "Timeline von #$n nicht lesbar"; continue; }

  # (0) Maschinen-Signal: der Worker hat selbst "kein Deliverable nötig" gesetzt.
  labels="$(printf '%s' "$ISSUES" | jq -r --argjson n "$n" \
    '.[] | select(.number == $n) | [.labels[].name] | join(",")')"

  # (a) Altpfad: letzter Kommentar beginnt mit [ALREADY-DONE]
  last_comment="$(printf '%s' "$tl" | jq -r '
    [ .[] | select(.event == "commented") | (.body // "") ] | last // ""')"

  reason=""
  if printf '%s' "$labels" | tr ',' '\n' | grep -qx 'triage:no-action'; then
    reason="triage:no-action"
  elif printf '%s' "$last_comment" | head -1 | grep -q '^\[ALREADY-DONE\]'; then
    reason="[ALREADY-DONE] (Altpfad)"
  fi

  [ -n "$reason" ] || { log "SKIP #$n ($(printf '%s' "$ISSUES" | jq -r --argjson n "$n" '.[]|select(.number==$n)|.title' | cut -c1-50))"; continue; }

  if [ "$DRY" = 1 ]; then
    log "DRY-RUN würde #$n schließen ($reason) + Label $DISPATCH_LABEL entfernen"
    acted=$((acted + 1)); continue
  fi

  log "CLOSE #$n ($reason) + Label $DISPATCH_LABEL weg"
  "$GH" issue close "$n" --repo "$REPO" --reason completed \
    --comment "Buchhaltung: Dispatch erledigt ($reason). Label wird entfernt." >/dev/null 2>&1 \
    && "$GH" issue edit "$n" --repo "$REPO" --remove-label "$DISPATCH_LABEL" >/dev/null 2>&1 \
    || { log "WARNUNG: Aktion für #$n unvollständig"; continue; }
  acted=$((acted + 1))
done

log "fertig (Aktionen: $acted)"
exit 0
