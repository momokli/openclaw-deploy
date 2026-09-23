#!/usr/bin/env bash
# tests/rift-triage-cleanup/run.sh — Offline-Harness für scripts/rift-triage-cleanup.sh.
#
# Kein Netz, kein echtes `gh`: PATH-Shims antworten aus Fixtures und protokollieren
# schreibende Aufrufe (`issue close`, `issue edit`) in eine Aktions-Datei. Geprüft wird,
# dass genau die richtigen Issues geschlossen werden — und vor allem, dass NICHTS
# geschlossen wird, was noch offen/offen-PR hat.
#
# Aufruf:
#   bash tests/rift-triage-cleanup/run.sh
#
# Exit 0 = alle Tests grün.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="${RIFT_TRIAGE_CLEANUP_SCRIPT:-$ROOT/scripts/rift-triage-cleanup.sh}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FX="$TMP/fx"; mkdir -p "$FX"
ACTIONS="$TMP/actions.log"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else notok "$1 (erwartet: $2 | ist: $3)"; fi; }

# ── gh-Shim: Fixtures + Schreib-Protokoll ────────────────────────────────────
cat > "$TMP/gh" <<'SHIM'
#!/bin/bash
case "$1" in
  api)
    case "$2" in
      *"/milestones"*)          cat "$FX/milestones.json" ;;
      *"/issues/"*"/timeline"*)
        n="$(printf '%s' "$2" | sed -E 's#.*/issues/([0-9]+)/timeline.*#\1#')"
        cat "$FX/timeline-$n.json" 2>/dev/null || echo '[]' ;;
      *) echo '[]' ;;
    esac ;;
  issue)
    case "$2" in
      list)  cat "$FX/issues.json" ;;
      close) printf 'close %s\n' "$3" >> "$ACTIONS" ;;
      edit)  printf 'edit %s %s\n' "$3" "$*" >> "$ACTIONS" ;;
    esac ;;
esac
exit 0
SHIM
chmod +x "$TMP/gh"

export PATH="$TMP:$PATH"
export RIFT_GH="$TMP/gh"
export FX ACTIONS

# ── Fixture-Helfer ───────────────────────────────────────────────────────────
milestone() { printf '[{"title":"1.0.1","number":12}]' > "$FX/milestones.json"; }
notfound()  { printf '[]' > "$FX/milestones.json"; }
issues()    { printf '%s' "$1" > "$FX/issues.json"; }
timeline()  { printf '%s' "$1" > "$FX/timeline-$2.json"; }
reset()     { : > "$ACTIONS"; milestone; }

run() { out="$("$SCRIPT" -m 1.0.1 "$@" 2>&1)"; rc=$?; }

echo "== Pfad (0): Maschinen-Signal triage:no-action =="
reset
issues '[{"number":101,"title":"A","labels":[{"name":"triage:no-action"}]}]'
timeline '[]' 101
run
check "schließt das Issue" "close 101" "$(head -1 "$ACTIONS")"
check "entfernt das Dispatch-Label" "1" "$(grep -c 'orchestrator:dispatched' "$ACTIONS")"

echo
echo "== Pfad (a): [ALREADY-DONE]-Kommentar (Altpfad) =="
reset
issues '[{"number":102,"title":"B","labels":[]}]'
timeline '[{"event":"commented","body":"[ALREADY-DONE]\n\nBeleg: PR #1"}]' 102
run
check "schließt das Issue" "close 102" "$(head -1 "$ACTIONS")"

echo
echo "== Gemergter PR, der das Issue nur ERWAEHNT -> nichts tun (real: PR #660 verursachte #623) =="
reset
issues '[{"number":103,"title":"C","labels":[]}]'
timeline '[{"event":"cross-referenced","source":{"issue":{"number":900,"state":"closed","pull_request":{"merged_at":"2026-09-23T10:00:00Z"}}}}]' 103
run
check "keine Aktion" "" "$(cat "$ACTIONS")"

echo

echo
echo "== Ohne Signal -> nichts tun (kein Blind-Schließen) =="
reset
issues '[{"number":105,"title":"E","labels":[]}]'
timeline '[]' 105
run
check "keine Aktion" "" "$(cat "$ACTIONS")"
check "Exit 0" "0" "$rc"

echo
echo "== --dry-run schreibt nichts =="
reset
issues '[{"number":106,"title":"F","labels":[{"name":"triage:no-action"}]}]'
timeline '[]' 106
run --dry-run
check "keine Aktion" "" "$(cat "$ACTIONS")"
check "DRY-RUN geloggt" "1" "$(printf '%s' "$out" | grep -c 'DRY-RUN')"

echo
echo "== --max 1 begrenzt die Aktionen =="
reset
issues '[{"number":107,"title":"G","labels":[{"name":"triage:no-action"}]},{"number":108,"title":"H","labels":[{"name":"triage:no-action"}]}]'
timeline '[]' 107; timeline '[]' 108
run --max 1
check "genau eine Aktion" "1" "$(grep -c '^close ' "$ACTIONS")"

echo
echo "== Kein offener Dispatch -> nichts zu tun =="
reset
issues '[]'
run
check "meldet nichts zu tun" "1" "$(printf '%s' "$out" | grep -c 'nichts zu tun')"
check "Exit 0" "0" "$rc"

echo
echo "== Milestone unbekannt -> Exit 2 =="
reset; notfound
issues '[]'
run
check "Exit 2" "2" "$rc"

echo
printf '== %d ok, %d fail ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
