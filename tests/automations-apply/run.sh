#!/usr/bin/env bash
# tests/automations-apply/run.sh — Offline-Harness für scripts/automations-apply.sh.
#
# Der Converge-Pfad ist der Deploy-Pfad der Runner. Kein Gateway nötig: ein
# `openclaw`-Shim liest die Job-Liste aus einem Fixture und protokolliert jeden
# create/edit/rm-Aufruf.
#
# Geprüft wird:
#   - je Profil werden A/B (Agent) UND beide Ticks (Shell) angelegt
#   - die Ticks tragen `--command-env RUNNER_PROFILE=<profil>` (Repo-Bindung)
#   - Converge aktiviert NICHTS (kein --enable)
#   - ohne installierte Engine werden die Ticks NICHT umgebogen (fail-safe)
#   - stale Jobs der alten Loop-Generation werden entfernt
#
# Aufruf:
#   bash tests/automations-apply/run.sh
#
# Exit 0 = alle Tests grün.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
APPLY="$ROOT/scripts/automations-apply.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FX="$TMP/fx"; mkdir -p "$FX"
ACTIONS="$TMP/actions.log"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else notok "$1 (erwartet: $2 | ist: $3)"; fi; }
has()   { if grep -q -- "$2" "$ACTIONS"; then ok "$1"; else notok "$1 (nicht gefunden: $2)"; fi; }
hasnot(){ if grep -q -- "$2" "$ACTIONS"; then notok "$1 (unerwartet gefunden: $2)"; else ok "$1"; fi; }

# ── Shims ────────────────────────────────────────────────────────────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/openclaw" <<'SHIM'
#!/bin/bash
case "$1 $2" in
  "automations list") cat "$FX/jobs.json" ;;
  "automations create"|"automations edit"|"automations rm") printf '%s\n' "$*" >> "$ACTIONS" ;;
esac
exit 0
SHIM
chmod +x "$TMP/bin/openclaw"

# Fake-Engine: das Converge biegt die Ticks nur um, wenn sie im PATH liegt.
mkdir -p "$TMP/engine"
printf '#!/bin/bash\nexit 0\n' > "$TMP/engine/runner-triage-tick.sh"
printf '#!/bin/bash\nexit 0\n' > "$TMP/engine/runner-pr-gate-tick.sh"
chmod +x "$TMP/engine"/*.sh

export FX ACTIONS
jobs_empty()  { printf '%s' '{"jobs":[]}' > "$FX/jobs.json"; }
jobs_stale()  { printf '%s' '{"jobs":[{"declarationKey":"mmm-loop:main","id":"OLD-1"},{"declarationKey":"ci-cd-fix-loop:main","id":"OLD-2"}]}' > "$FX/jobs.json"; }

# Mit Engine im PATH (Normalfall) bzw. ohne (Engine noch nicht installiert).
run_apply()  { out="$(PATH="$TMP/bin:$TMP/engine:$PATH" bash "$APPLY" 2>&1)"; rc=$?; }
run_noeng()  { out="$(PATH="$TMP/bin:$PATH" bash "$APPLY" 2>&1)"; rc=$?; }

echo "== Leere Job-Liste: alle Runner werden angelegt =="
: > "$ACTIONS"; jobs_empty
run_apply
check "Exit 0" "0" "$rc"
for key in rift-triage:main rift-pr-gate:main rift-triage-tick:main rift-pr-gate-tick:main \
           mmm-triage:main mmm-pr-gate:main mmm-triage-tick:main mmm-pr-gate-tick:main \
           ocd-triage:main ocd-pr-gate:main; do
  has "create $key" "--declaration-key $key"
done

echo
echo "== Repo-Bindung je Tick-Instanz =="
check "rift-Tick -> --command-env RUNNER_PROFILE=rift (2x)" "2" "$(grep -c -- '--command-env RUNNER_PROFILE=rift' "$ACTIONS")"
check "mmm-Tick -> --command-env RUNNER_PROFILE=mmm (2x)"  "2" "$(grep -c -- '--command-env RUNNER_PROFILE=mmm' "$ACTIONS")"
has "rift-Tick ruft die Engine + rift-Log" "runner-triage-tick.sh >> /srv/openclaw/logs/rift-tick.log"
has "mmm-Tick ruft die Engine + mmm-Log"   "runner-triage-tick.sh >> /srv/openclaw/logs/mmm-tick.log"

echo
echo "== Converge aktiviert nichts =="
hasnot "kein --enable" "--enable"

echo
echo "== Stale Jobs der alten Loop-Generation werden entfernt =="
: > "$ACTIONS"; jobs_stale
run_apply
check "Exit 0" "0" "$rc"
has "rm mmm-loop" "automations rm OLD-1"
has "rm ci-cd-fix-loop" "automations rm OLD-2"

echo
echo "== Ohne installierte Engine: Ticks werden NICHT umgebogen (fail-safe) =="
: > "$ACTIONS"; jobs_empty
run_noeng
check "Exit 0" "0" "$rc"
hasnot "kein Tick-Create (rift)" "--declaration-key rift-triage-tick:main"
hasnot "kein Tick-Create (mmm)"  "--declaration-key mmm-triage-tick:main"
has "Agent-Runner wird trotzdem angelegt" "--declaration-key mmm-triage:main"
case "$out" in
  *'runner-*-tick.sh nicht im PATH'*) ok "Warnung nennt den Grund" ;;
  *) notok "Warnung nennt den Grund (ist: $out)" ;;
esac

echo
printf '== %d ok, %d fail ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
