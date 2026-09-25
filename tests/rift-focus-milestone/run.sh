#!/usr/bin/env bash
# tests/rift-focus-milestone/run.sh — Offline-Harness für scripts/rift-focus-milestone.sh.
#
# Kein Netz, kein echtes `gh`: PATH-Shims antworten aus Fixtures. Geprüft wird die
# Fokus-Regel:
#   Fokus = kleinster offener Versions-Milestone, der FREIGEGEBEN ist
#           (`Freigabe: ja` im Text) UND noch keinen Release-PR hat.
# Dazu: Version-Sortierung, Run-ahead (offener/gemergter Release-PR wird
# übersprungen), Nicht-Freigabe (Sammelbecken wie 1.1), geschlossener
# (nicht gemergter) Release-PR blockiert NICHT, Usage/Fehler-Exit-Codes.
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
FX="$TMP/fx"; mkdir -p "$FX"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }
check() { # check <beschreibung> <erwartet> <ist>
  if [ "$2" = "$3" ]; then ok "$1"; else notok "$1 (erwartet: $2 | ist: $3)"; fi
}

# gh-Shim: `milestones`-API und `pr list` aus getrennten Fixtures.
cat > "$TMP/gh" <<'SHIM'
#!/bin/bash
case "$*" in
  *"milestones"*) cat "$FX/milestones.json" 2>/dev/null || echo '[]' ;;
  *"pr list"*)    cat "$FX/prs.json" 2>/dev/null || echo '[]' ;;
  *"pr view"*)    cat "$FX/prview.json" 2>/dev/null || echo '{}' ;;
  *"issue list"*)
    case "$*" in
      *"--state closed"*) cat "$FX/issues-closed.json" 2>/dev/null || echo '[]' ;;
      *)                  cat "$FX/issues-open.json" 2>/dev/null || echo '[]' ;;
    esac ;;
  *) echo '[]' ;;
esac
SHIM
chmod +x "$TMP/gh"

export PATH="$TMP:$PATH"
export GH_BIN="$TMP/gh"
export FX

out=""; rc=0
# Fake-Defaults (Tests überschreiben sie gezielt). NICHT als ${VAR:-{...}}-Default —
# bash beendet die Expansion am ersten `}`.
PRS='[]'; LEAVES='[]'; CLOSED='[]'; PRVIEW='{"commits":[]}'
run() { # run <milestones-json> [args...] ; Fakes via $PRS/$LEAVES/$CLOSED/$PRVIEW
  printf '%s' "$1" > "$FX/milestones.json"; shift
  printf '%s' "$PRS" > "$FX/prs.json"
  printf '%s' "$LEAVES" > "$FX/issues-open.json"
  printf '%s' "$CLOSED" > "$FX/issues-closed.json"
  printf '%s' "$PRVIEW" > "$FX/prview.json"
  out="$("$SCRIPT" "$@" 2>/dev/null)"; rc=$?
}

ms() { printf '[%s]' "$1"; }
FREE='Freigabe: ja'
# Gibt einen Milestone-Eintrag mit Freigabe-Zeile im Text aus (jq → sauberes JSON).
m() { # m <title> <number> <open> [extra-description]
  local d="$FREE"
  if [ -n "${4:-}" ]; then d="$FREE
$4"; fi
  jq -cn --arg t "$1" --argjson n "$2" --argjson o "$3" --arg d "$d" \
    '{title:$t,number:$n,open_issues:$o,description:$d}'
}
# ohne Freigabe
mf() { printf '{"title":"%s","number":%s,"open_issues":%s}' "$1" "$2" "$3"; }
# Release-PR-Fixture
rel() { # rel <title> <STATE>
  printf '{"headRefName":"release/%s","state":"%s","labels":[{"name":"release:human-merge"}]}' "$1" "$2"
}

echo "== Fokus-Regel =="

PRS="[]"
run "$(ms "$(m 1.0.1 12 11),$(mf 1.1 11 19),$(mf soon 9 0)")"
check "kleinster freigegebener Versions-Titel gewinnt" "1.0.1" "$out"
check "Exit 0 bei Treffer" "0" "$rc"

run "$(ms "$(mf soon 9 0)")"
check "Parkplatz ohne Version liefert nichts" "" "$out"
check "kein Kandidat -> Exit 4" "4" "$rc"

run "$(ms "$(mf 1.0.1 12 11),$(mf 1.1 11 19)")"
check "ohne Freigabe kein Kandidat" "" "$out"
check "nicht freigegeben -> Exit 4" "4" "$rc"

echo
echo "== Freigabe grep: Sammelbecken 1.1 ohne Marker bleibt gesperrt =="

PRS="[]"
run "$(ms "$(m 1.0.4 15 3),$(mf 1.1 11 19)")"
check "1.0.4 freigegeben, 1.1 nicht -> 1.0.4" "1.0.4" "$out"

echo
echo "== Versions-Sortierung =="

PRS="[]"
run "$(ms "$(mf 1.1 11 19),$(m 1.0.10 15 1),$(m 1.0.2 14 3)")"
check "numerisch statt lexikalisch (1.0.2 vor 1.0.10)" "1.0.2" "$out"

run "$(ms "$(m 1.0 8 0),$(m 1.0.1 12 11)")"
check "1.0 sortiert vor 1.0.1" "1.0" "$out"

echo
echo "== Run-ahead: Release-PR wird übersprungen =="

# Offener Release-PR (wartet auf Review) -> Fokus rückt auf den nächsten.
PRS="[$(rel 1.0.3 OPEN)]"
run "$(ms "$(m 1.0.3 14 0),$(m 1.0.4 15 3)")"
check "offener Release-PR -> nächster freigegebener Milestone" "1.0.4" "$out"

# Gemergter Release-PR (Milestone noch offen) -> ebenfalls überspringen.
PRS="[$(rel 1.0.3 MERGED)]"
run "$(ms "$(m 1.0.3 14 0),$(m 1.0.4 15 3)")"
check "gemergter Release-PR -> nicht mehr Fokus" "1.0.4" "$out"

# Geschlossener (nicht gemergter) Release-PR blockiert NICHT -> Release neu bauen.
PRS="[$(rel 1.0.3 CLOSED)]"
run "$(ms "$(m 1.0.3 14 0),$(m 1.0.4 15 3)")"
check "geschlossener Release-PR -> Milestone bleibt Fokus (Rebuild)" "1.0.3" "$out"

# Alle freigegebenen sind released/awaiting -> kein Kandidat.
PRS="[$(rel 1.0.3 OPEN)]"
run "$(ms "$(m 1.0.3 14 0)")"
check "alle awaiting -> kein Kandidat" "" "$out"
check "alle awaiting -> Exit 4" "4" "$rc"

echo
echo "== Run-ahead-Ausnahmen: Arbeit / veralteter PR halten den Fokus =="

# Offener Release-PR, aber offene Leaf-Issues -> Fokus bleibt (Work).
PRS="[$(rel 1.0.3 OPEN)]"
LEAVES='[{"number":900,"title":"fix","labels":[],"body":""}]'
CLOSED='[]'; PRVIEW='{"commits":[]}'
run "$(ms "$(m 1.0.3 14 1),$(m 1.0.4 15 3)")"
check "offener PR + offene Leaves -> Milestone bleibt Fokus" "1.0.3" "$out"

# Offener Release-PR, keine Leaves, aber PR veraltet (Issue nach Release-Commit geschlossen).
LEAVES='[]'
CLOSED='[{"closedAt":"2026-09-24T12:00:00Z"}]'
PRVIEW='{"commits":[{"committedDate":"2026-09-24T10:00:00Z"}]}'
run "$(ms "$(m 1.0.3 14 0),$(m 1.0.4 15 3)")"
check "offener PR veraltet -> Milestone bleibt Fokus (Rebuild)" "1.0.3" "$out"

# Offener Release-PR, keine Leaves, PR aktuell -> überspringen.
CLOSED='[{"closedAt":"2026-09-24T09:00:00Z"}]'
run "$(ms "$(m 1.0.3 14 0),$(m 1.0.4 15 3)")"
check "offener PR aktuell -> nächster Fokus" "1.0.4" "$out"

# Fakes zurücksetzen, damit die Folgetests Defaults sehen.
LEAVES='[]'; CLOSED='[]'; PRVIEW='{"commits":[]}'
PRS='[]'

echo
echo "== Fokus erschöpft (open_issues=0, kein Release-PR) =="

PRS="[]"
run "$(ms "$(m 1.0.1 12 0),$(mf 1.1 11 19)")"
check "leerer freigegebener Milestone bleibt der Fokus" "1.0.1" "$out"

PRS="[]"
run "$(ms "$(m 1.0.1 12 0)")" --json
check "json meldet open_issues=0" "{\"title\":\"1.0.1\",\"number\":12,\"open_issues\":0,\"closed_issues\":0,\"description\":\"$FREE\"}" "$out"

echo
echo "== --json / --list =="

PRS="[]"
run "$(ms "$(m 1.0.1 12 11)")" --json
check "json-Ausgabe" "{\"title\":\"1.0.1\",\"number\":12,\"open_issues\":11,\"closed_issues\":0,\"description\":\"$FREE\"}" "$out"

run "$(ms "$(m 1.0.1 12 0)")" --json
check "json defaultet fehlendes closed_issues auf 0" "{\"title\":\"1.0.1\",\"number\":12,\"open_issues\":0,\"closed_issues\":0,\"description\":\"$FREE\"}" "$out"

# Die Milestone-Beschreibung (inkl. Checkliste) wird mitgeliefert.
run "$(ms "$(m 1.0.1 12 2 '- [ ] #900
- [ ] #901')")" --json
check "json liefert die Beschreibung mit (inkl. Checkliste)" "- [ ] #900
- [ ] #901" "$(printf '%s' "$out" | jq -r 'select(.title=="1.0.1") | .description' 2>/dev/null | sed '1d')"

PRS="[$(rel 1.0.3 OPEN)]"
run "$(ms "$(mf 1.1 11 19),$(m 1.0.3 14 0),$(m 1.0.1 12 11),$(mf soon 9 0)")" --list
check "--list: aufsteigend, mit Freigabe- und Release-Status" "1.0.1 number=12 open_issues=11 approved=1 release_pr=none
1.0.3 number=14 open_issues=0 approved=1 release_pr=open
1.1 number=11 open_issues=19 approved=0 release_pr=none" "$out"

echo
echo "== Usage und Fehler =="

PRS="[]"
run "$(ms "$(m 1.0.1 12 11)")" --quatsch
check "unbekanntes Argument -> Exit 2" "2" "$rc"

run "$(ms "$(m 1.0.1 12 11)")" --help
check "--help -> Exit 0" "0" "$rc"
case "$out" in *rift-focus-milestone*) ok "--help nennt das Script" ;; *) notok "--help nennt das Script" ;; esac

run 'das ist kein json'
check "kaputte API-Antwort -> Exit 3" "3" "$rc"

echo
printf 'tests: %d ok, %d fail\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
