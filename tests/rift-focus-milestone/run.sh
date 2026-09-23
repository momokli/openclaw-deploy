#!/usr/bin/env bash
# tests/rift-focus-milestone/run.sh — Offline-Harness für scripts/rift-focus-milestone.sh.
#
# Kein Netz, kein echtes `gh`: ein PATH-Shim antwortet aus einer Fixture-Datei.
# Geprüft wird die Fokus-Regel (kleinster offener Versions-Titel), die
# Version-Sortierung (1.0.1 < 1.1 < 1.0.10 korrekt numerisch), das Ignorieren von
# Nicht-Versions-Titeln (Parkplatz `soon`), der „Fokus erschöpft"-Fall
# (open_issues=0 wird NICHT übersprungen) sowie Usage- und Fehler-Exit-Codes.
#
# Aufruf:
#   bash tests/rift-focus-milestone/run.sh
#
# Exit 0 = alle Tests grün.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="${RIFT_FOCUS_MILESTONE_SCRIPT:-$ROOT/scripts/rift-focus-milestone.sh}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }
check() { # check <beschreibung> <erwartet> <ist>
  if [ "$2" = "$3" ]; then ok "$1"; else notok "$1 (erwartet: $2 | ist: $3)"; fi
}

# gh-Shim: liefert für jeden `api`-Aufruf die aktuelle Fixture.
cat > "$TMP/gh" <<'SHIM'
#!/bin/bash
cat "$FIXTURE"
SHIM
chmod +x "$TMP/gh"

export PATH="$TMP:$PATH"
export GH_BIN="$TMP/gh"
export FIXTURE="$TMP/milestones.json"

out=""; rc=0
run() { # run <fixture-json> [args...]
  printf '%s' "$1" > "$FIXTURE"; shift
  out="$("$SCRIPT" "$@" 2>/dev/null)"; rc=$?
}

ms() { printf '[%s]' "$1"; }

echo "== Fokus-Regel =="

run "$(ms '{"title":"1.1","number":11,"open_issues":19},{"title":"1.0.1","number":12,"open_issues":11},{"title":"soon","number":9,"open_issues":0}')"
check "kleinster Versions-Titel gewinnt (1.0.1 vor 1.1)" "1.0.1" "$out"
check "Exit 0 bei Treffer" "0" "$rc"

run "$(ms '{"title":"soon","number":9,"open_issues":0}')"
check "Parkplatz ohne Version liefert nichts" "" "$out"
check "kein Kandidat -> Exit 4" "4" "$rc"

echo
echo "== Versions-Sortierung =="

run "$(ms '{"title":"1.1","number":11,"open_issues":19},{"title":"1.0.10","number":15,"open_issues":1},{"title":"1.0.2","number":14,"open_issues":3}')"
check "numerisch statt lexikalisch (1.0.2 vor 1.0.10 vor 1.1)" "1.0.2" "$out"

run "$(ms '{"title":"1.0","number":8,"open_issues":0},{"title":"1.0.1","number":12,"open_issues":11}')"
check "1.0 sortiert vor 1.0.1" "1.0" "$out"

echo
echo "== Fokus erschöpft (wird NICHT übersprungen) =="

run "$(ms '{"title":"1.1","number":11,"open_issues":19},{"title":"1.0.1","number":12,"open_issues":0}')"
check "leerer Fokus-Milestone bleibt der Fokus" "1.0.1" "$out"

run "$(ms '{"title":"1.1","number":11,"open_issues":19},{"title":"1.0.1","number":12,"open_issues":0}')" --json
check "json meldet open_issues=0" '{"title":"1.0.1","number":12,"open_issues":0}' "$out"

echo
echo "== --json / --list =="

run "$(ms '{"title":"1.1","number":11,"open_issues":19},{"title":"1.0.1","number":12,"open_issues":11}')" --json
check "json-Ausgabe" '{"title":"1.0.1","number":12,"open_issues":11}' "$out"

run "$(ms '{"title":"1.1","number":11,"open_issues":19},{"title":"1.0.1","number":12,"open_issues":11},{"title":"soon","number":9,"open_issues":0}')" --list
check "--list: aufsteigend, ohne Parkplatz" "1.0.1 number=12 open_issues=11
1.1 number=11 open_issues=19" "$out"

echo
echo "== Usage und Fehler =="

run "$(ms '{"title":"1.0.1","number":12,"open_issues":11}')" --quatsch
check "unbekanntes Argument -> Exit 2" "2" "$rc"

run "$(ms '{"title":"1.0.1","number":12,"open_issues":11}')" --help
check "--help -> Exit 0" "0" "$rc"
case "$out" in *rift-focus-milestone*) ok "--help nennt das Script" ;; *) notok "--help nennt das Script" ;; esac

run 'das ist kein json'
check "kaputte API-Antwort -> Exit 3" "3" "$rc"

echo
printf 'tests: %d ok, %d fail\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
