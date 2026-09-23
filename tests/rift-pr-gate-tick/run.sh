#!/usr/bin/env bash
# tests/rift-pr-gate-tick/run.sh — Offline-Harness für scripts/rift-pr-gate-tick.sh.
#
# Dieser Tick **mergt** PRs — deshalb ist das hier der wichtigste Harness der Runner.
# Kein Netz, kein `gh`/`openclaw`: PATH-Shims lesen Fixtures und protokollieren
# `pr merge` und den Agent-Trigger. Geprüft wird, dass NUR bei
# APPROVE + CLEAN + ausschliesslich grünen Checks gemergt wird — und sonst der
# Agent-Turn (Review/Rebase) angestossen wird oder gar nichts passiert.
#
# Aufruf:
#   bash tests/rift-pr-gate-tick/run.sh
#
# Exit 0 = alle Tests grün.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="${RIFT_PR_GATE_TICK_SCRIPT:-$ROOT/scripts/rift-pr-gate-tick.sh}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FX="$TMP/fx"; mkdir -p "$FX"
ACTIONS="$TMP/actions.log"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else notok "$1 (erwartet: $2 | ist: $3)"; fi; }

# ── Shims ────────────────────────────────────────────────────────────────────
cat > "$TMP/rift-focus-milestone.sh" <<'SHIM'
#!/bin/bash
cat "$FX/focus"
SHIM

cat > "$TMP/gh" <<'SHIM'
#!/bin/bash
case "$1 $2" in
  "issue list") cat "$FX/issues.json" ;;
  "pr list")    cat "$FX/prs.json" ;;
  "pr view")    n="$3"; cat "$FX/pr-$n.json" 2>/dev/null || echo '{}' ;;
  "pr merge")   printf 'MERGE %s\n' "$3" >> "$ACTIONS" ;;
esac
exit 0
SHIM

cat > "$TMP/openclaw" <<'SHIM'
#!/bin/bash
if [ "$1 $2 $3" = "automations list --all" ]; then
  echo '{"jobs":[{"declarationKey":"rift-pr-gate:main","id":"JOB-G"}]}'
elif [ "$1 $2" = "automations run" ]; then
  printf 'trigger %s\n' "$3" >> "$ACTIONS"
fi
exit 0
SHIM

chmod +x "$TMP"/*
export PATH="$TMP:$PATH" FX ACTIONS
export RIFT_GH="$TMP/gh"

# ── Fixtures ─────────────────────────────────────────────────────────────────
focus()  { printf '{"title":"1.0.1","number":12,"open_issues":5}' > "$FX/focus"; }
issues() { printf '%s' "$1" > "$FX/issues.json"; }
prs()    { printf '%s' "$1" > "$FX/prs.json"; }
prview() { printf '%s' "$2" > "$FX/pr-$1.json"; }
reset()  { : > "$ACTIONS"; focus; issues '[{"number":896}]'; prs '[]'; }

# iso_ago <minuten> → ISO-8601-UTC vor N Minuten (portabel GNU/BSD).
iso_ago() {
  local ep
  ep=$(( $(date -u +%s) - $1 * 60 ))
  date -u -d "@$ep" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$ep" +%Y-%m-%dT%H:%M:%SZ
}

run() { out="$("$SCRIPT" 2>&1)"; rc=$?; }

# Fokus-PR #901 mit Variablen State/Checks/Verdict.
# $4 (optional) = Alter des Verdict-Kommentars in Minuten (Default: jetzt).
focuspr() {  # $1 mergeStateStatus  $2 checks(all|pending|failing)  $3 verdict(approve|changes|none)  $4 verdict_age_min
  prs '[{"number":901,"title":"ci(#896): build","body":"Closes #896","headRefName":"ci/896-x","isDraft":false,"mergeStateStatus":"'"$1"'"}]'
  local checks
  case "$2" in
    all)     checks='[{"__typename":"CheckRun","conclusion":"SUCCESS"},{"__typename":"CheckRun","conclusion":"SKIPPED"}]' ;;
    pending) checks='[{"__typename":"CheckRun","conclusion":"SUCCESS"},{"__typename":"CheckRun","conclusion":null}]' ;;
    failing) checks='[{"__typename":"CheckRun","conclusion":"FAILURE"}]' ;;
  esac
  local created
  if [ -n "${4:-}" ]; then created="$(iso_ago "$4")"; else created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; fi
  local comments
  case "$3" in
    approve) comments='[{"body":"[VERDICT: APPROVE]\nok","createdAt":"'"$created"'"}]' ;;
    changes) comments='[{"body":"[VERDICT: REQUEST_CHANGES]\nno","createdAt":"'"$created"'"}]' ;;
    none)    comments='[]' ;;
  esac
  prview 901 '{"mergeStateStatus":"'"$1"'","statusCheckRollup":'"$checks"',"comments":'"$comments"'}'
}

echo "== APPROVE + CLEAN + alles grün -> deterministischer Merge (kein Agent) =="
reset; focuspr CLEAN all approve
run
check "Exit 0" "0" "$rc"
check "Merged" "MERGE 901" "$(grep '^MERGE' "$ACTIONS")"
check "kein Agent-Trigger" "0" "$(grep -c '^trigger' "$ACTIONS")"

echo
echo "== APPROVE, aber ein Check läuft noch -> KEIN Merge, Agent-Turn =="
reset; focuspr CLEAN pending approve
run
check "kein Merge" "0" "$(grep -c '^MERGE' "$ACTIONS")"
check "Agent getriggert" "trigger JOB-G" "$(grep '^trigger' "$ACTIONS")"

echo
echo "== APPROVE, aber Check FAILURE -> KEIN Merge, Agent-Turn =="
reset; focuspr CLEAN failing approve
run
check "kein Merge" "0" "$(grep -c '^MERGE' "$ACTIONS")"
check "Agent getriggert" "trigger JOB-G" "$(grep '^trigger' "$ACTIONS")"

echo
echo "== kein Verdict -> KEIN Merge, Agent-Turn (Review fällig) =="
reset; focuspr CLEAN all none
run
check "kein Merge" "0" "$(grep -c '^MERGE' "$ACTIONS")"
check "Agent getriggert" "trigger JOB-G" "$(grep '^trigger' "$ACTIONS")"

echo
echo "== REQUEST_CHANGES -> KEIN Merge, Agent-Turn =="
reset; focuspr CLEAN all changes
run
check "kein Merge" "0" "$(grep -c '^MERGE' "$ACTIONS")"
check "Agent getriggert" "trigger JOB-G" "$(grep '^trigger' "$ACTIONS")"

echo
echo "== APPROVE, aber BEHIND (Rebase fällig) -> KEIN Merge, Agent-Turn =="
reset; focuspr BEHIND all approve
run
check "kein Merge" "0" "$(grep -c '^MERGE' "$ACTIONS")"
check "Agent getriggert" "trigger JOB-G" "$(grep '^trigger' "$ACTIONS")"

echo
echo "== BLOCKED (roter Required-Check), kein Verdict -> Agent-Turn =="
reset; focuspr BLOCKED failing none
run
check "Exit 0" "0" "$rc"
check "kein Merge" "0" "$(grep -c '^MERGE' "$ACTIONS")"
check "Agent getriggert" "trigger JOB-G" "$(grep '^trigger' "$ACTIONS")"

echo
echo "== BLOCKED, frisches REQUEST_CHANGES -> Cooldown, KEIN Trigger =="
reset; focuspr BLOCKED failing changes 5
run
check "Exit 0" "0" "$rc"
check "kein Merge" "0" "$(grep -c '^MERGE' "$ACTIONS")"
check "kein Trigger" "0" "$(grep -c '^trigger' "$ACTIONS")"
check "Cooldown geloggt" "1" "$(printf '%s' "$out" | grep -c 'SKIP #901 cooldown')"

echo
echo "== BLOCKED, altes Verdict (120min > 60min Cooldown) -> Agent-Turn =="
reset; focuspr BLOCKED failing changes 120
run
check "kein Merge" "0" "$(grep -c '^MERGE' "$ACTIONS")"
check "Agent getriggert" "trigger JOB-G" "$(grep '^trigger' "$ACTIONS")"

echo
echo "== PR ausserhalb des Fokus -> gar nichts =="
reset
prs '[{"number":892,"title":"ci: followup","body":"Refs #777","headRefName":"ci/x","isDraft":false,"mergeStateStatus":"CLEAN"}]'
run
check "Exit 0" "0" "$rc"
check "kein Merge" "0" "$(grep -c '^MERGE' "$ACTIONS")"
check "kein Trigger" "0" "$(grep -c '^trigger' "$ACTIONS")"

echo
echo "== Draft-PR im Fokus -> gar nichts =="
reset
prs '[{"number":901,"title":"ci(#896): wip","body":"Closes #896","headRefName":"ci/896-x","isDraft":true,"mergeStateStatus":"CLEAN"}]'
prview 901 '{"mergeStateStatus":"CLEAN","statusCheckRollup":[],"comments":[]}'
run
check "kein Merge" "0" "$(grep -c '^MERGE' "$ACTIONS")"
check "kein Trigger" "0" "$(grep -c '^trigger' "$ACTIONS")"

echo
echo "== DRY-RUN: kein Merge, aber Entscheidung geloggt =="
reset; focuspr CLEAN all approve
export RIFT_TICK_DRY=1; run; unset RIFT_TICK_DRY
check "kein Merge" "0" "$(grep -c '^MERGE' "$ACTIONS")"
check "DRY-RUN geloggt" "1" "$(printf '%s' "$out" | grep -c 'DRY-RUN: würde PR #901 mergen')"

echo
printf '== %d ok, %d fail ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
