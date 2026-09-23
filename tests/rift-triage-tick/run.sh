#!/usr/bin/env bash
# tests/rift-triage-tick/run.sh — Offline-Harness für scripts/rift-triage-tick.sh.
#
# Kein Netz, kein `gh`/`openclaw`: PATH-Shims antworten aus Fixtures und protokollieren,
# was der Tick tut. Geprüft wird die Trigger-Entscheidung (Agent-Turn ja/nein) UND die
# Kern-Zusicherung aus Schritt 1 der Runner-Architektur:
#
#   Guard und Cleanup laufen IMMER — auch wenn der Slot belegt ist.
#
# (Vorher gated der Tick aufs Label und verhinderte damit den Aufräum-Turn; real wurde
# daraus der Deadlock bei #393/#895.)
#
# Aufruf:
#   bash tests/rift-triage-tick/run.sh
#
# Exit 0 = alle Tests grün.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="${RIFT_TRIAGE_TICK_SCRIPT:-$ROOT/scripts/rift-triage-tick.sh}"

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
[ -f "$FX/focus" ] || exit 3
cat "$FX/focus"
SHIM

cat > "$TMP/rift-stale-dispatch.sh" <<'SHIM'
#!/bin/bash
printf 'guard\n' >> "$ACTIONS"
echo "summary issues=0 stale=0 redispatched=0 capped=0 skipped=0"
SHIM

cat > "$TMP/rift-triage-cleanup.sh" <<'SHIM'
#!/bin/bash
printf 'cleanup\n' >> "$ACTIONS"
echo "nichts zu tun"
SHIM

cat > "$TMP/gh" <<'SHIM'
#!/bin/bash
case "$1 $2" in
  "issue list")
    case "$*" in
      *orchestrator:dispatched*) cat "$FX/dispatched.json" ;;
      *)                         cat "$FX/issues.json" ;;
    esac ;;
  "pr list") cat "$FX/prs.json" ;;
esac
exit 0
SHIM

cat > "$TMP/openclaw" <<'SHIM'
#!/bin/bash
if [ "$1 $2 $3" = "automations list --all" ]; then
  echo '{"jobs":[{"declarationKey":"rift-triage:main","id":"JOB-1"}]}'
elif [ "$1 $2" = "automations run" ]; then
  printf 'trigger %s\n' "$3" >> "$ACTIONS"
fi
exit 0
SHIM

chmod +x "$TMP"/*
export PATH="$TMP:$PATH" FX ACTIONS RIFT_GH="$TMP/gh"
# Decision-File landet unter $OPENCLAW_STATE_DIR/workspace → im Test in den TMP-Baum lenken.
export OPENCLAW_STATE_DIR="$TMP/state"; mkdir -p "$OPENCLAW_STATE_DIR/workspace"
DECISION="$OPENCLAW_STATE_DIR/workspace/rift-triage-decision.md"

# ── Fixtures ─────────────────────────────────────────────────────────────────
focus()     { printf '%s' "$1" > "$FX/focus"; }
focus_ok()  { focus '{"title":"1.0.1","number":12,"open_issues":7}'; }
nofocus()   { rm -f "$FX/focus"; }
dispatched(){ printf '%s' "$1" > "$FX/dispatched.json"; }
issues()    { printf '%s' "$1" > "$FX/issues.json"; }
prs()       { printf '%s' "$1" > "$FX/prs.json"; }
reset()     { : > "$ACTIONS"; focus_ok; dispatched '[]'; issues '[{"number":896,"title":"ci: build parallel","labels":[],"body":""}]'; prs '[]'; }

run() { out="$("$SCRIPT" 2>&1)"; rc=$?; }

echo "== Dispatchbar: Trigger =="
reset
run
check "Exit 0" "0" "$rc"
check "Guard lief" "1" "$(grep -c '^guard$' "$ACTIONS")"
check "Cleanup lief" "1" "$(grep -c '^cleanup$' "$ACTIONS")"
check "Agent-Turn getriggert" "trigger JOB-1" "$(grep '^trigger' "$ACTIONS")"
check "Decision-File nennt #896" "1" "$(grep -c 'Issue: #896' "$DECISION" 2>/dev/null || echo 0)"
check "Decision-File schliesst per Closes" "1" "$(grep -c 'Closes #896' "$DECISION" 2>/dev/null || echo 0)"

echo
echo "== Slot belegt: KEIN Trigger — aber Guard+Cleanup MUESSEN laufen (Schritt-1-Fix) =="
reset
dispatched '[{"number":777}]'
run
check "Exit 0 (Skip)" "0" "$rc"
check "kein Trigger" "0" "$(grep -c '^trigger' "$ACTIONS")"
check "Guard lief trotzdem" "1" "$(grep -c '^guard$' "$ACTIONS")"
check "Cleanup lief trotzdem" "1" "$(grep -c '^cleanup$' "$ACTIONS")"

echo
echo "== Offener Fokus-PR: kein Trigger =="
reset
dispatched '[{"number":900,"title":"fix","body":"Refs #896","headRefName":"fix/x"}]'
run
check "Exit 0 (Skip)" "0" "$rc"
check "kein Trigger" "0" "$(grep -c '^trigger' "$ACTIONS")"

echo
echo "== Nur Epics/Spikes im Fokus: kein Trigger =="
reset
issues '[{"number":724,"title":"[Epic] 1.0.1","labels":[],"body":""},{"number":486,"title":"[Spike] X","labels":[{"name":"research"}],"body":""}]'
run
check "Exit 0 (Skip)" "0" "$rc"
check "kein Trigger" "0" "$(grep -c '^trigger' "$ACTIONS")"

echo
echo "== triage:no-action zaehlt als kein Leaf-Kandidat =="
reset
issues '[{"number":896,"title":"ci: build parallel","labels":[{"name":"triage:no-action"}],"body":""}]'
run
check "Exit 0 (Skip)" "0" "$rc"

echo
echo "== Fokus erschoepft: kein Trigger =="
reset
focus '{"title":"1.0.1","number":12,"open_issues":0}'
run
check "Exit 0 (Skip)" "0" "$rc"
check "kein Trigger" "0" "$(grep -c '^trigger' "$ACTIONS")"

echo
echo "== Kein Fokus-Milestone: kein Trigger =="
reset; nofocus
run
check "Exit 0 (Skip)" "0" "$rc"
check "kein Trigger" "0" "$(grep -c '^trigger' "$ACTIONS")"

echo
printf '== %d ok, %d fail ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
