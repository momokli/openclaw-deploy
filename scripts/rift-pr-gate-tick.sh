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
#
# Exit 0  = OK (Aktion ausgeführt ODER nichts zu tun; welches steht im Log).
#           WICHTIG: auch der Skip muss 0 sein — der Scheduler wertet einen Command-Payload
#           mit Exit ≠ 0 als Job-Fehler (und stdout geht hier in die Logdatei, also leer).
# Exit 2  = Fehler (gh/CLI) → Job-Status wird `error` (gewollt sichtbar).
set -uo pipefail

REPO="momokli/riftbreaker-battle-mod"
GH="${RIFT_GH:-claw-gh}"                # Runner B = momo-claw[bot]
SELF_KEY="rift-pr-gate:main"
# mergeStateStatus-Werte, die eine Aktion brauchen.
ACTIONABLE_STATES='CLEAN|BEHIND|UNSTABLE'

log()  { printf '%s rift-pr-gate-tick: %s\n' "$(date -Is)" "$*"; }
skip() { log "SKIP $*"; exit 0; }
die()  { log "FEHLER $*"; exit 2; }

command -v "$GH" >/dev/null 2>&1 || die "$GH nicht im PATH"

# 1) Fokus-Milestone.
FOCUS="$(rift-focus-milestone.sh --json 2>/dev/null)" || skip "kein Fokus-Milestone"
N="$(printf '%s' "$FOCUS" | jq -r '.number // empty')"
TITLE="$(printf '%s' "$FOCUS" | jq -r '.title // empty')"
[ -n "$N" ] || die "Fokus-Milestone nicht parsebar: $FOCUS"

# 2) Fokus-Issues + offene PRs.
ISSUES="$("$GH" issue list --repo "$REPO" --state open --milestone "$N" --limit 100 \
  --json number 2>/dev/null)" || die "issue list fehlgeschlagen"
PRS="$("$GH" pr list --repo "$REPO" --state open --limit 100 \
  --json number,title,body,headRefName,isDraft,mergeStateStatus 2>/dev/null)" \
  || die "pr list fehlgeschlagen"

FOCUS_NUMS="$(printf '%s' "$ISSUES" | jq -c '[.[].number]')"
hits() { # aktionable Fokus-PRs, aufsteigend (FIFO = unterster Stack-PR zuerst)
  jq -nr --argjson prs "$PRS" --argjson focus "$FOCUS_NUMS" --arg re "$ACTIONABLE_STATES" '
    [ $prs[]
      | select(.isDraft | not)
      | select(( ((.title // "") + " " + (.body // "") + " " + (.headRefName // ""))
                 | [scan("#([0-9]+)")] | flatten | map(tonumber)
                 | any(. as $n | $focus | index($n)) ))
      | select((.mergeStateStatus // "") | test("^(" + $re + ")$")) ]
    | sort_by(.number) | .[] | "\(.number) \(.mergeStateStatus)"'
}

HIT="$(hits)"
[ -n "$HIT" ] || skip "kein aktionabler Fokus-PR (nichts zu mergen/rebasen/reviewen)"

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
