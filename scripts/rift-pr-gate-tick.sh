#!/bin/bash
# Leichtgewichtiger Precheck + deterministische Aktionen für `rift-pr-gate` (0 Tokens).
#
# Läuft oft (z. B. alle 5 min) als `--command`-Automation auf dem Gateway.
#
#   1. Fokus-Milestone + offene Fokus-PRs ermitteln (gh).
#   2. Deterministische Aktion: PR mit letztem `[VERDICT: APPROVE]`, mergeStateStatus
#      CLEAN und ausschliesslich grünen Checks ⇒ sofort `gh pr merge --squash
#      --delete-branch`. Das ist reine Buchhaltung, dafür braucht es kein Modell.
#   3. Alles andere (Review fällig, Rebase, Konflikt, offene Checks) ⇒ Agent-Turn
#      anstossen (der reviewt/releast). Nur wenn es so etwas gibt — sonst 0 Tokens.
#   4. Sonderfall Release-PR (`release:human-merge`, Changelog + Abnahme + Testplan):
#      nie aktionabel — der wird nur geloggt („wartet auf den Menschen").
#
# BLOCKED ist ein aktionabler Zustand: ein roter Required-Check friert den PR ein
# (kein Auto-Merge, aber auch kein Fortkommen) — ohne Agent-Turn hängt er stumm.
# Damit ein dauerhaft roter PR nicht jede 5-Min-Runde Tokens verbrennt, greift für
# BLOCKED ein Cooldown: solange das jüngste `[VERDICT:`-Kommentar frisch ist, wird
# kein Agent-Turn angestossen (der Fall ist ja schon bewertet). Nur ein fehlendes
# oder abgelaufenes Verdict lässt den Agenten wieder ran. Die anderen Zustände
# (CLEAN|BEHIND|UNSTABLE) bleiben unverändert (immer Agent-Turn).
#
# Optionen:
#   -h, --help          Diese Hilfe.
#   --cooldown-min N    Cooldown-Frist in Minuten für BLOCKED (Default 60).
#                       Env: RIFT_GATE_COOLDOWN_MIN (Alias GATE_COOLDOWN_MIN).
#
# Exit 0  = OK (Aktion ausgeführt ODER nichts zu tun; welches steht im Log).
#           WICHTIG: auch der Skip muss 0 sein — der Scheduler wertet einen Command-Payload
#           mit Exit ≠ 0 als Job-Fehler (und stdout geht hier in die Logdatei, also leer).
# Exit 2  = Fehler (gh/CLI) → Job-Status wird `error` (gewollt sichtbar).
set -uo pipefail

REPO="momokli/riftbreaker-battle-mod"
GH="${RIFT_GH:-claw-gh}"                # Runner B = momo-claw[bot]
SELF_KEY="rift-pr-gate:main"
# mergeStateStatus-Werte, die eine Aktion brauchen. BLOCKED = roter Required-Check
# (o. ä.) → der Agent-Turn muss reviewen/releast, sonst hängt der PR stumm.
ACTIONABLE_STATES='CLEAN|BEHIND|UNSTABLE|BLOCKED'
# Cooldown-Frist (Minuten) für BLOCKED-PRs (Token-Schutz gegen 5-Min-Runden).
COOLDOWN_MIN="${RIFT_GATE_COOLDOWN_MIN:-${GATE_COOLDOWN_MIN:-60}}"
# Marker des Release-PRs (Changelog + Abnahme + Testplan, siehe rift-triage-tick):
# er wird gebaut/aktualisiert, aber NIE von der Automation gemergt — die Freigabe
# ist der Mensch. Deshalb ist ein so markierter PR hier grundsaetzlich NICHT aktionabel.
RELEASE_LABEL='release:human-merge'

log()  { printf '%s rift-pr-gate-tick: %s\n' "$(date -Is)" "$*"; }
skip() { log "SKIP $*"; exit 0; }
die()  { log "FEHLER $*"; exit 2; }

usage() { awk 'NR >= 2 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; }

# iso_to_epoch <ISO-8601-UTC> → Epoch-Sekunden (GNU date, sonst BSD/macOS-Fallback).
iso_to_epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s
}

# ── Argumente ──────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --cooldown-min) opt="$1"; shift; [ $# -gt 0 ] || die "fehlender Wert nach $opt"; COOLDOWN_MIN="$1" ;;
    -h|--help)      usage; exit 0 ;;
    *)              die "unbekannte Option: $1" ;;
  esac
  shift
done
case "$COOLDOWN_MIN" in ''|*[!0-9]*) die "numerischer Wert erwartet: --cooldown-min $COOLDOWN_MIN" ;; esac

command -v "$GH" >/dev/null 2>&1 || die "$GH nicht im PATH"
command -v jq >/dev/null 2>&1 || die "jq nicht im PATH"

NOW="$(date -u +%s)"

# 1) Fokus-Milestone.
FOCUS="$(rift-focus-milestone.sh --json 2>/dev/null)" || skip "kein Fokus-Milestone"
N="$(printf '%s' "$FOCUS" | jq -r '.number // empty')"
TITLE="$(printf '%s' "$FOCUS" | jq -r '.title // empty')"
[ -n "$N" ] || die "Fokus-Milestone nicht parsebar: $FOCUS"

# 2) Fokus-Issues + offene PRs.
ISSUES="$("$GH" issue list --repo "$REPO" --state open --milestone "$N" --limit 100 \
  --json number 2>/dev/null)" || die "issue list fehlgeschlagen"
PRS="$("$GH" pr list --repo "$REPO" --state open --limit 100 \
  --json number,title,body,headRefName,isDraft,mergeStateStatus,labels 2>/dev/null)" \
  || die "pr list fehlgeschlagen"

FOCUS_NUMS="$(printf '%s' "$ISSUES" | jq -c '[.[].number]')"
hits() { # aktionable Fokus-PRs, aufsteigend (FIFO = unterster Stack-PR zuerst)
  jq -nr --argjson prs "$PRS" --argjson focus "$FOCUS_NUMS" --arg re "$ACTIONABLE_STATES" \
         --arg rel "$RELEASE_LABEL" '
    [ $prs[]
      | select(.isDraft | not)
      | select((([.labels[]?.name] | index($rel)) == null))   # Release-PR = Mensch
      | select(( ((.title // "") + " " + (.body // "") + " " + (.headRefName // ""))
                 | [scan("#([0-9]+)")] | flatten | map(tonumber)
                 | any(. as $n | $focus | index($n)) ))
      | select((.mergeStateStatus // "") | test("^(" + $re + ")$")) ]
    | sort_by(.number) | .[] | "\(.number) \(.mergeStateStatus)"'
}

HIT="$(hits)"
if [ -z "$HIT" ]; then
  # Sichtbarkeit: ein Release-PR wartet bewusst auf den Menschen (kein Automerge).
  REL_OPEN="$(printf '%s' "$PRS" | jq -r --arg rel "$RELEASE_LABEL" \
    '[ .[] | select(any(.labels[]?; .name == $rel)) | .number ] | join(",")')"
  [ -z "$REL_OPEN" ] || log "wartet auf den Menschen: Release-PR #$REL_OPEN ($RELEASE_LABEL)"
  skip "kein aktionabler Fokus-PR (nichts zu mergen/rebasen/reviewen)"
fi

# 3) Deterministischer Merge, wo alles passt; Rest an den Agenten.
actions=0; needs_agent=0
while read -r num state; do
  [ -n "$num" ] || continue

  # Letztes Review-Verdict lesen (der Reviewer postet es als Kommentar-Anfang).
  detail="$("$GH" pr view "$num" --repo "$REPO" \
    --json comments,statusCheckRollup,mergeStateStatus 2>/dev/null)" || { needs_agent=$((needs_agent+1)); continue; }

  verdict="$(printf '%s' "$detail" | jq -r '
    [ .comments[]? | select((.body // "") | startswith("[VERDICT:")) | .body ] | last // ""' \
    | head -1)"
  # Zeitstempel des jüngsten Verdict-Kommentars (für den BLOCKED-Cooldown).
  verdict_at="$(printf '%s' "$detail" | jq -r '
    [ .comments[]? | select((.body // "") | startswith("[VERDICT:")) | (.createdAt // "") ] | last // ""')"
  checks_ok="$(printf '%s' "$detail" | jq -r '
    [ .statusCheckRollup[]? | select(.__typename == "CheckRun")
      | (.conclusion // "PENDING") ]
    | all(. == "SUCCESS" or . == "SKIPPED" or . == "NEUTRAL")')"

  if printf '%s' "$verdict" | grep -q '^\[VERDICT: APPROVE\]' \
     && [ "$state" = "CLEAN" ] && [ "$checks_ok" = "true" ]; then
    if [ "${RIFT_TICK_DRY:-0}" = "1" ]; then
      log "DRY-RUN: würde PR #$num mergen (APPROVE + CLEAN + Checks grün)"
    elif "$GH" pr merge "$num" --repo "$REPO" --squash --delete-branch >/dev/null 2>&1; then
      log "MERGED #$num (APPROVE + CLEAN + Checks grün, squash, branch gelöscht)"
    else
      log "WARNUNG: Merge von #$num fehlgeschlagen — geht an den Agent-Turn"
      needs_agent=$((needs_agent+1)); continue
    fi
    actions=$((actions+1))
  elif [ "$state" = "BLOCKED" ] && [ -n "$verdict_at" ] \
       && vep="$(iso_to_epoch "$verdict_at")" && [ -n "$vep" ] \
       && [ $(( (NOW - vep) / 60 )) -lt "$COOLDOWN_MIN" ]; then
    # Roter Required-Check, aber bereits bewertet → Cooldown, 0 Tokens.
    log "SKIP #$num cooldown (rot, letztes Verdict vor $(( (NOW - vep) / 60 ))min)"
  else
    needs_agent=$((needs_agent+1))
  fi
done <<< "$HIT"

# 4) Nur wenn noch echte Urteilsarbeit offen ist, den Agent-Turn anstossen.
if [ "$needs_agent" -eq 0 ]; then
  log "fertig (deterministische Aktionen: $actions, Agent-Turn nicht nötig)"
  exit 0
fi
if [ "${RIFT_TICK_DRY:-0}" = "1" ]; then
  log "DRY-RUN: $needs_agent PR(s) brauchen Review/Rebase — würde $SELF_KEY triggern"
  exit 0
fi

ID="$(openclaw automations list --all --json 2>/dev/null \
      | jq -r --arg k "$SELF_KEY" '.jobs[] | select(.declarationKey == $k) | .id' | head -1)"
[ -n "$ID" ] && [ "$ID" != "null" ] || die "Agent-Job $SELF_KEY nicht gefunden"

log "AKTION FÄLLIG ($TITLE): $HIT → $needs_agent brauchen den Agent-Turn, triggere $SELF_KEY ($ID)"
openclaw automations run "$ID" 2>&1 | tail -3
exit 0
