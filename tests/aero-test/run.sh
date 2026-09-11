#!/usr/bin/env bash
# Offline-Test-Harness für Issue #43 (aero-test RCON-Fix).
# Keine Netz-/Host-Abhängigkeit — arbeitet auf Fixtures.
#
# red-before-green: die Fixture startet mit enable-rcon=false; ohne den Patch
# würde der Harness fehlschlagen.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
TEMPLATE="$REPO_ROOT/scripts/aero-test/compose.template.yaml"
SCRIPT="$REPO_ROOT/scripts/aero-test/apply-rcon-fix.sh"
RUNBOOK="$REPO_ROOT/docs/aero-test-rcon.md"
FIXTURES="$HERE/fixtures"

PASS=0; FAIL=0
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# check: Beschreibung + Kommando (direkt, kein eval) -> PASS bei Exit 0
check(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else no "$d"; fi; }
# check_not: PASS wenn Kommando NICHT erfolgreich ist
check_not(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then no "$d"; else ok "$d"; fi; }
# expect_exit: PASS wenn Kommando genau mit $want endet
expect_exit(){ local want="$1" d="$2"; shift 2; local rc=0; "$@" >/dev/null 2>&1 || rc=$?; if [ "$rc" -eq "$want" ]; then ok "$d"; else no "$d"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- Fixtures kopieren ---
mkdir -p "$WORK/data"
cp "$FIXTURES/default-server.properties" "$WORK/data/default-server.properties"
cp "$FIXTURES/server.properties" "$WORK/data/server.properties"

# --- red: Ausgangszustand ist NICHT gefixt ---
check "red: Fixture default-server.properties hat enable-rcon=false" \
  grep -qxF "enable-rcon=false" "$WORK/data/default-server.properties"
check "red: Fixture server.properties hat enable-rcon=false" \
  grep -qxF "enable-rcon=false" "$WORK/data/server.properties"

# --- Pflicht-Dateien vorhanden & Syntax ---
check "Template existiert" test -f "$TEMPLATE"
check "Patch-Script existiert" test -f "$SCRIPT"
check "Runbook existiert" test -f "$RUNBOOK"
check "apply-rcon-fix.sh: bash -n" bash -n "$SCRIPT"
check "apply-rcon-fix.sh: shellcheck" shellcheck "$SCRIPT"

# --- Patch anwenden (1. Lauf) ---
expect_exit 0 "apply-rcon-fix.sh Lauf 1 exit 0" \
  env RCON_PASSWORD=testpw43 "$SCRIPT" --data-dir "$WORK/data"

check "green: default-server.properties enable-rcon=true" \
  grep -qxF "enable-rcon=true" "$WORK/data/default-server.properties"
check "green: default-server.properties rcon.password=testpw43" \
  grep -qxF "rcon.password=testpw43" "$WORK/data/default-server.properties"
check "green: default-server.properties broadcast-rcon-to-ops=true" \
  grep -qxF "broadcast-rcon-to-ops=true" "$WORK/data/default-server.properties"
check "green: server.properties enable-rcon=true" \
  grep -qxF "enable-rcon=true" "$WORK/data/server.properties"
check "green: server.properties rcon.port=25575" \
  grep -qxF "rcon.port=25575" "$WORK/data/server.properties"
check "green: server.properties enable-query=false" \
  grep -qxF "enable-query=false" "$WORK/data/server.properties"
check "keine doppelten enable-rcon-Keys" \
  test "$(grep -c '^enable-rcon=' "$WORK/data/server.properties")" -eq 1

# --- Idempotenz: 2. Lauf ändert nichts ---
SUM_BEFORE="$(find "$WORK/data" -type f -name '*.properties' -exec sha256sum {} + | sort | sha256sum)"
OUT2="$(env RCON_PASSWORD=testpw43 "$SCRIPT" --data-dir "$WORK/data" 2>&1)"
RC=$?
SUM_AFTER="$(find "$WORK/data" -type f -name '*.properties' -exec sha256sum {} + | sort | sha256sum)"
check "Idempotenz: 2. Lauf exit 0" test "$RC" -eq 0
check "Idempotenz: Dateien unverändert" test "$SUM_BEFORE" = "$SUM_AFTER"
check "Idempotenz: 2. Lauf meldet 'unchanged'" grep -q "unchanged" <<<"$OUT2"

# --- Fehlendes Passwort -> Exit 3 ---
expect_exit 3 "fehlendes Passwort -> Exit 3" \
  env -u RCON_PASSWORD "$SCRIPT" --data-dir "$WORK/data"

# --- Compose-Template: YAML + RCON-Konfiguration ---
check "Template parst als YAML" \
  python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$TEMPLATE"
check "Template: ENABLE_RCON=TRUE" \
  python3 -c 'import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if d["services"]["aero-test"]["environment"]["ENABLE_RCON"]=="TRUE" else 1)' "$TEMPLATE"
check "Template: RCON_PASSWORD verdrahtet" \
  python3 -c 'import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if "RCON_PASSWORD" in d["services"]["aero-test"]["environment"] else 1)' "$TEMPLATE"
check "Template: stop_grace_period gesetzt" \
  python3 -c 'import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if "stop_grace_period" in d["services"]["aero-test"] else 1)' "$TEMPLATE"

# --- Runbook dokumentiert den Fix ---
check "Runbook nennt default-server.properties" grep -q "default-server.properties" "$RUNBOOK"
check "Runbook nennt server.properties" grep -q "server.properties" "$RUNBOOK"
check "Runbook nennt enable-rcon" grep -q "enable-rcon" "$RUNBOOK"
check "Runbook nennt Verify (rcon-cli)" grep -q "rcon-cli" "$RUNBOOK"

# --- Secret-Scan (nur Repo-Artefakte; Tests enthalten das Muster absichtlich) ---
check_not "kein echtes aero-test-RCON-Passwort in Repo-Artefakten" \
  grep -rqF "aero-test-rcon-2026" "$REPO_ROOT/scripts" "$REPO_ROOT/docs"
check_not "keine ghp_/sk-/AKIA-Secrets in den Artefakten" \
  grep -rqE 'ghp_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}' \
  "$REPO_ROOT/scripts/aero-test" "$RUNBOOK" "$HERE"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
