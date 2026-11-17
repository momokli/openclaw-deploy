#!/usr/bin/env bash
# tests/runner-close-milestone/run.sh — Offline-Harness für
# scripts/runner-close-milestone.sh (der Release-Pfad schließt damit den Milestone).
#
# Kein Netz, kein echtes `gh`: ein PATH-Shim antwortet aus Fixtures und protokolliert
# den PATCH. Geprüft wird die Regel aus #44:
#   Schließen nur ohne offene Leaf-Issues und ohne offenen, ungemergten PR;
#   geparkte Reste (HOLD-Labels) blockieren nicht, werden aber protokolliert.
#
# Aufruf: bash tests/runner-close-milestone/run.sh
# Exit 0 = alle Tests grün.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="${RIFT_CLOSE_MILESTONE_SCRIPT:-$ROOT/scripts/runner-close-milestone.sh}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FX="$TMP/fx"; mkdir -p "$FX"
ACTIONS="$TMP/actions.log"; : > "$ACTIONS"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else notok "$1 (erwartet: $2 | ist: $3)"; fi; }

cat > "$TMP/gh" <<'SHIM'
#!/bin/bash
case "$*" in
  *"PATCH"*"milestones"*) printf 'PATCH %s\n' "$*" >> "$ACTIONS"; exit 0 ;;
  *"milestones?state=all"*) cat "$FX/milestones.json" 2>/dev/null || echo '[]' ;;
  *"issue list"*)           cat "$FX/issues.json" 2>/dev/null || echo '[]' ;;
  *"pr list"*)              cat "$FX/prs.json" 2>/dev/null || echo '[]' ;;
  *) echo '[]' ;;
esac
SHIM
chmod +x "$TMP/gh"

export PATH="$TMP:$PATH" FX ACTIONS
export RIFT_GH=gh
export RUNNER_PROFILE=mmm

MS_ALL='[{"number":44,"title":"music-api-0.5.0","state":"open","description":"Freigabe: ja"}]'

run() { # run <issues-json> [prs-json] [milestones-json]
  printf '%s' "$1" > "$FX/issues.json"
  printf '%s' "${2:-[]}" > "$FX/prs.json"
  printf '%s' "${3:-$MS_ALL}" > "$FX/milestones.json"
  : > "$ACTIONS"
  out="$("$SCRIPT" 44 2>&1)"; rc=$?
}

echo "== Release gemergt, aber 3 offene Leaf-Issues -> Milestone bleibt offen =="
# Der reale Fall vom 2026-11-16: #44 wurde mit #512/#513/#518 offen geschlossen.
run '[{"number":512,"title":"a","labels":[],"body":""},
      {"number":513,"title":"b","labels":[],"body":""},
      {"number":518,"title":"c","labels":[],"body":""}]'
check "Exit 0" "0" "$rc"
check "kein PATCH" "0" "$(grep -c '^PATCH' "$ACTIONS")"
check "KEEP geloggt" "1" "$(printf '%s' "$out" | grep -c 'KEEP 44')"
check "nennt alle drei" "1" "$(printf '%s' "$out" | grep -c '#512 #513 #518')"

echo
echo "== Release gemergt, nur geparkte Reste -> schliesst und protokolliert =="
# Ein einzelnes `question`-Issue darf den Milestone nicht fuer immer offen halten.
run '[{"number":512,"title":"stale","labels":[{"name":"question"}],"body":""}]'
check "Exit 0" "0" "$rc"
check "schliesst" "1" "$(grep -c '^PATCH' "$ACTIONS")"
check "CLOSE geloggt" "1" "$(printf '%s' "$out" | grep -c 'CLOSE 44')"
check "geparkte Reste genannt" "1" "$(printf '%s' "$out" | grep -c 'geparkte offene Issues.*#512')"

echo
echo "== offener, ungemergter PR auf ein offenes Issue -> nicht code-complete =="
run '[{"number":512,"title":"x","labels":[{"name":"claimed"}],"body":""}]' \
    '[{"number":523,"title":"feat: x","body":"Closes #512","headRefName":"feat/512"}]'
check "Exit 0" "0" "$rc"
check "kein PATCH" "0" "$(grep -c '^PATCH' "$ACTIONS")"
check "KEEP wegen PR" "1" "$(printf '%s' "$out" | grep -c 'offener, ungemergter PR #523')"

echo
echo "== Milestone ohne offene Issues -> schliesst =="
run '[]'
check "Exit 0" "0" "$rc"
check "schliesst" "1" "$(grep -c '^PATCH' "$ACTIONS")"
check "keine geparkten Reste" "1" "$(printf '%s' "$out" | grep -c 'keine')"

echo
echo "== bereits geschlossener Milestone -> SKIP, kein PATCH =="
run '[]' '[]' '[{"number":44,"title":"music-api-0.5.0","state":"closed","description":"Freigabe: ja"}]'
check "Exit 0" "0" "$rc"
check "kein PATCH" "0" "$(grep -c '^PATCH' "$ACTIONS")"
check "SKIP geloggt" "1" "$(printf '%s' "$out" | grep -c 'bereits closed')"

echo
echo "== Usage ohne Nummer -> Exit 2 =="
out="$("$SCRIPT" 2>&1)"; rc=$?
check "Exit 2" "2" "$rc"

echo
if [ "$FAIL" -eq 0 ]; then echo "== $PASS ok, 0 fail =="; exit 0; fi
echo "== $PASS ok, $FAIL fail =="; exit 1
