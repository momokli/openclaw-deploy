#!/usr/bin/env bash
# tests/runner-profile/run.sh — Offline-Harness für die Runner-Profil-Schicht.
#
# Die Engine (`runner-*.sh`) ist geteilt, das Profil bindet sie an EIN Repo.
# Geprüft wird genau das, was die Trennung trägt:
#   - Auflösung (RUNNER_PROFILE, RUNNER_PROFILE_FILE)
#   - die `:=`-Regel: gesetzte Umgebungsvariablen gewinnen
#   - fail-closed bei unbekanntem Profil
#   - die Engine benutzt wirklich das Repo aus dem Profil (kein Cross-Repo-Leak)
#
# Kein Netz: ein PATH-Shim für `gh` antwortet nur für genau ein Repo.
#
# Aufruf:
#   bash tests/runner-profile/run.sh
#
# Exit 0 = alle Tests grün.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export ROOT

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else notok "$1 (erwartet: $2 | ist: $3)"; fi; }

# Sonde: sourced die Profil-Schicht und gibt eine Variable aus.
cat > "$TMP/probe.sh" <<'EOS'
#!/bin/bash
set -uo pipefail
. "$ROOT/scripts/runner-profile.sh"
eval "printf '%s' \"\${$1}\""
EOS
chmod +x "$TMP/probe.sh"
probe() { RUNNER_PROFILE_DIR="$ROOT/config/runners" RUNNER_PROFILE="$1" bash "$TMP/probe.sh" "$2"; }

echo "== Profile parsen =="
for p in rift mmm; do
  if bash -n "$ROOT/config/runners/$p.conf" 2>/dev/null; then ok "$p.conf parst"; else notok "$p.conf parst"; fi
done

echo "== Auflösung + Profilwerte =="
check "rift -> repo"        "momokli/riftbreaker-battle-mod" "$(probe rift RUNNER_REPO)"
check "mmm -> repo"         "momokli/momos-music-manager"   "$(probe mmm RUNNER_REPO)"
check "mmm -> State-Präfix" "mmm"                           "$(probe mmm RUNNER_STATE_PREFIX)"
check "mmm -> Trigger-Key"  "mmm-triage:main"               "$(probe mmm RUNNER_TRIAGE_KEY)"
check "mmm -> Hold-Labels (needs:manual-test)" \
  "claimed needs:manual-test follow-up hold question triage:no-action" "$(probe mmm RUNNER_HOLD_LABELS)"
check "rift -> Hold-Labels (needs:player-test)" \
  "claimed needs:player-test follow-up hold question triage:no-action" "$(probe rift RUNNER_HOLD_LABELS)"
check "mmm -> kein [Release]-Tracking-Issue" "0" "$(probe mmm RUNNER_RELEASE_TRACKING_ISSUE)"
check "rift -> [Release]-Tracking-Issue"     "1" "$(probe rift RUNNER_RELEASE_TRACKING_ISSUE)"

echo "== Env gewinnt (:= Defaults) =="
check "Env überschreibt Profil" "custom/fake" \
  "$(RUNNER_PROFILE_DIR="$ROOT/config/runners" RUNNER_REPO=custom/fake RUNNER_PROFILE=mmm bash "$TMP/probe.sh" RUNNER_REPO)"

printf '%s\n' ': "${RUNNER_REPO:=via/file}"' ': "${RUNNER_STATE_PREFIX:=fake}"' > "$TMP/fake.env"
check "RUNNER_PROFILE_FILE gewinnt" "via/file" \
  "$(RUNNER_PROFILE_FILE="$TMP/fake.env" RUNNER_PROFILE=irrelevant bash "$TMP/probe.sh" RUNNER_REPO)"

echo "== Fail-closed: unbekanntes Profil =="
out="$(RUNNER_PROFILE=does-not-exist RUNNER_PROFILE_DIR="$ROOT/config/runners" bash "$TMP/probe.sh" RUNNER_REPO 2>&1)"; rc=$?
check "unbekanntes Profil -> Exit 2" "2" "$rc"
case "$out" in
  *'Profil "does-not-exist" nicht gefunden'*) ok "Fehlermeldung nennt das Profil" ;;
  *) notok "Fehlermeldung nennt das Profil (ist: $out)" ;;
esac

echo "== Die Engine benutzt das Profil-Repo (kein Cross-Repo-Leak) =="
mkdir -p "$TMP/bin" "$TMP/fx"
# Der Shim erlaubt NUR das MMM-Repo; jeder andere Repo-Zugriff ist ein Leak und
# lässt den Test laut scheitern.
cat > "$TMP/bin/gh" <<'EOS'
#!/bin/bash
if [ "$1" = "api" ]; then
  case "$2" in
    repos/momokli/momos-music-manager/milestones*) cat "$FX/milestones.json"; exit 0 ;;
    repos/*) echo "gh-shim: unerwarteter Repo-Zugriff: $2" >&2; exit 1 ;;
  esac
  exit 0
fi
if [ "$1 $2" = "pr list" ]; then echo '[]'; exit 0; fi
exit 0
EOS
chmod +x "$TMP/bin/gh"
export FX="$TMP/fx"
cat > "$FX/milestones.json" <<'EOS'
[{"title":"1.14.0","number":1,"open_issues":2,"closed_issues":0,
  "description":"Freigabe: ja\n- [ ] #56\n- [ ] #57"}]
EOS

check "mmm-Profil -> Fokus 1.14.0" "1.14.0" \
  "$(RUNNER_PROFILE=mmm GH_BIN="$TMP/bin/gh" "$ROOT/scripts/runner-focus-milestone.sh" 2>/dev/null)"

out="$(RUNNER_PROFILE=rift GH_BIN="$TMP/bin/gh" "$ROOT/scripts/runner-focus-milestone.sh" 2>&1)"; rc=$?
check "rift-Profil -> kein Zugriff auf das MMM-Repo (Exit 3)" "3" "$rc"
case "$out" in
  *'unerwarteter Repo-Zugriff'*|*'fehlgeschlagen'*) ok "Leak wird sichtbar abgelehnt" ;;
  *) notok "Leak wird sichtbar abgelehnt (ist: $out)" ;;
esac

echo
printf '== %d ok, %d fail ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
