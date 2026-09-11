#!/usr/bin/env bash
# Offline-Test-Harness für Issue #42 (aero-test Klon-Setup + Preflight).
# Keine Netz-/Host-Abhängigkeit: Fixtures + gestubbte docker/ss/openssl.
#
# red-before-green: die Fixture-PROD-Welt + Backup-Verzeichnis existieren,
# der Preflight muss die fehlende Instanz aber zuerst als drift/missing melden.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/clone-prod.sh"
RUNBOOK="$REPO_ROOT/docs/test-instance.md"
FIXTURES="$HERE/fixtures"

PASS=0; FAIL=0
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }
check(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else no "$d"; fi; }
check_not(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then no "$d"; else ok "$d"; fi; }
expect_exit(){ local want="$1" d="$2"; shift 2; local rc=0; "$@" >/dev/null 2>&1 || rc=$?; if [ "$rc" -eq "$want" ]; then ok "$d"; else no "$d (rc=$rc, want=$want)"; fi; }
contains(){ local d="$1" pat="$2" file="$3"; if grep -qF -- "$pat" "$file" 2>/dev/null; then ok "$d"; else no "$d"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- Stubs ------------------------------------------------------------------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
if [ "${1:-}" = "ps" ]; then
  if printf '%s' "$*" | grep -q -- ' -a'; then
    [ -f "${STUB_DOCKER_PSA:-}" ] && cat "$STUB_DOCKER_PSA" || true
  else
    [ -f "${STUB_DOCKER_PORTS:-}" ] && cat "$STUB_DOCKER_PORTS" || true
  fi
  exit 0
fi
if [ "${1:-}" = "compose" ]; then
  envf=""; prev=""
  for a in "$@"; do [ "$prev" = "--env-file" ] && envf="$a"; prev="$a"; done
  name="aero-test"
  [ -n "$envf" ] && [ -f "$envf" ] && name="$(sed -n 's/^CONTAINER_NAME=//p' "$envf" | tail -1)"
  [ -n "$name" ] || name="aero-test"
  echo "$name"
  [ -n "${STUB_DOCKER_PSA:-}" ] && printf '%s\n' "$name" > "$STUB_DOCKER_PSA"
  exit 0
fi
exit 0
STUB
cat > "$WORK/bin/ss" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_SS:-}" ] && [ -f "$STUB_SS" ] && cat "$STUB_SS" || true
exit 0
STUB
cat > "$WORK/bin/openssl" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "rand" ]; then echo "stub-generated-pass"; exit 0; fi
exit 0
STUB
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"

: > "$WORK/docker_psa"       # leer = kein Container
: > "$WORK/docker_ports"     # leer = keine docker-Ports
: > "$WORK/ss"               # leer = kein Listening-Socket
export STUB_DOCKER_PSA="$WORK/docker_psa" STUB_DOCKER_PORTS="$WORK/docker_ports" STUB_SS="$WORK/ss"

# rcon-fix-Stub (delegierter Properties-Patch aus #43), protokolliert Aufrufe
cat > "$WORK/apply-rcon-fix.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_RCON_LOG:?}"
exit 0
STUB
chmod +x "$WORK/apply-rcon-fix.sh"
export STUB_RCON_LOG="$WORK/rcon.log"

# --- Fixture-Umgebung -------------------------------------------------------
PROD="$WORK/srv/aero"
TESTD="$WORK/srv/aero-test"
mkdir -p "$PROD/data" "$WORK/template"
cp -a "$FIXTURES/prod/data/." "$PROD/data/"
cp "$FIXTURES/template/compose.template.yaml" "$WORK/template/compose.template.yaml"

run_clone(){
  "$SCRIPT" --prod-dir "$PROD" --test-dir "$TESTD" --test-name aero-test \
    --compose-template "$WORK/template/compose.template.yaml" \
    --rcon-fix "$WORK/apply-rcon-fix.sh" --password testpw42 "$@"
}

# --- red: Preflight meldet fehlende Instanz ---------------------------------
expect_exit 3 "red: --check meldet missing (Exit 3)" "$SCRIPT" --check --test-dir "$TESTD" --test-name aero-test
check_not "red: noch kein compose.yaml" test -f "$TESTD/compose.yaml"

# --- Setup (ohne Start) -----------------------------------------------------
expect_exit 0 "ensure Lauf 1 exit 0" run_clone
check "compose.yaml aus Vorlage erzeugt" test -f "$TESTD/compose.yaml"
check "compose.yaml = Vorlage" cmp -s "$WORK/template/compose.template.yaml" "$TESTD/compose.yaml"
check ".env erzeugt" test -f "$TESTD/.env"
check "data geklont (mods/x.jar)" test -f "$TESTD/data/mods/x.jar"
check "world NICHT geklont" test ! -e "$TESTD/data/world"
check "world.broken NICHT geklont" test ! -e "$TESTD/data/world.broken-20260823"
check "ftbbackups3 NICHT geklont" test ! -e "$TESTD/data/ftbbackups3"
check "logs NICHT geklont" test ! -e "$TESTD/data/logs"
check "config geklont" test -f "$TESTD/data/config/foo.toml"
contains ".env MC_PORT=25582" "MC_PORT=25582" "$TESTD/.env"
contains ".env CONTAINER_NAME=aero-test" "CONTAINER_NAME=aero-test" "$TESTD/.env"
contains ".env RCON_PASSWORD=testpw42" "RCON_PASSWORD=testpw42" "$TESTD/.env"
check ".env chmod 600" test "$(stat -c '%a' "$TESTD/.env")" = "600"
contains "rcon-fix-Stub mit data-dir aufgerufen" "--data-dir $TESTD/data" "$WORK/rcon.log"
contains "rcon-fix-Stub mit Passwort aufgerufen" "--password testpw42" "$WORK/rcon.log"

# --- Idempotenz: vorhandener Container => No-op -----------------------------
hash_c="$(sha256sum "$TESTD/compose.yaml" | awk '{print $1}')"
hash_e="$(sha256sum "$TESTD/.env" | awk '{print $1}')"
expect_exit 0 "ensure --start exit 0" run_clone --start
check "Container im docker ps -a registriert" grep -qx "aero-test" "$WORK/docker_psa"
out="$("$SCRIPT" --prod-dir "$PROD" --test-dir "$TESTD" --test-name aero-test \
  --compose-template "$WORK/template/compose.template.yaml" \
  --rcon-fix "$WORK/apply-rcon-fix.sh" --password testpw42 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then ok "ensure Lauf 3 (present) exit 0"; else no "ensure Lauf 3 exit $rc"; fi
if printf '%s' "$out" | grep -q "bereits vorhanden"; then ok "ensure Lauf 3 meldet No-op"; else no "ensure Lauf 3 meldet No-op"; fi
check "compose.yaml unverändert (Hash)" test "$hash_c" = "$(sha256sum "$TESTD/compose.yaml" | awk '{print $1}')"
check ".env unverändert (Hash)" test "$hash_e" = "$(sha256sum "$TESTD/.env" | awk '{print $1}')"

# --- Freie Portvergabe ------------------------------------------------------
printf 'LISTEN 0 4096 0.0.0.0:25582 0.0.0.0:*\nLISTEN 0 4096 0.0.0.0:25583 0.0.0.0:*\n' > "$WORK/ss"
TESTD2="$WORK/srv/aero-test2"
expect_exit 0 "ensure (Port-Auto) exit 0" "$SCRIPT" --no-data \
  --prod-dir "$PROD" --test-dir "$TESTD2" --test-name aero-test2 \
  --compose-template "$WORK/template/compose.template.yaml" \
  --rcon-fix "$WORK/apply-rcon-fix.sh" --password testpw42
contains "freier Port 25584 (25582+25583 belegt)" "MC_PORT=25584" "$TESTD2/.env"

printf '0.0.0.0:25584->25565/tcp\n' > "$WORK/docker_ports"
TESTD3="$WORK/srv/aero-test3"
expect_exit 0 "ensure (Port-Auto+docker) exit 0" "$SCRIPT" --no-data \
  --prod-dir "$PROD" --test-dir "$TESTD3" --test-name aero-test3 \
  --compose-template "$WORK/template/compose.template.yaml" \
  --rcon-fix "$WORK/apply-rcon-fix.sh" --password testpw42
contains "freier Port 25585 (docker-Port 25584 belegt)" "MC_PORT=25585" "$TESTD3/.env"
: > "$WORK/docker_ports"; : > "$WORK/ss"

# --- Fehlerpfade ------------------------------------------------------------
expect_exit 4 "fehlende Vorlage -> Exit 4" "$SCRIPT" --no-data \
  --prod-dir "$PROD" --test-dir "$WORK/srv/x" --test-name x \
  --compose-template "$WORK/nope.yaml"

out2="$("$SCRIPT" --prod-dir "$PROD" --test-dir "$WORK/srv/y" --test-name y \
  --compose-template "$WORK/template/compose.template.yaml" \
  --rcon-fix "$WORK/does-not-exist.sh" --password pw 2>&1)"
if printf '%s' "$out2" | grep -q "Properties-Patch-Script fehlt"; then ok "fehlender RCON-Patch -> Warnung"; else no "fehlender RCON-Patch -> Warnung"; fi

# --- Dry-run schreibt nichts ------------------------------------------------
TESTD4="$WORK/srv/aero-test4"
expect_exit 0 "dry-run exit 0" "$SCRIPT" --dry-run --no-data \
  --prod-dir "$PROD" --test-dir "$TESTD4" --test-name aero-test4 \
  --compose-template "$WORK/template/compose.template.yaml" \
  --rcon-fix "$WORK/apply-rcon-fix.sh" --password pw
check_not "dry-run: keine compose.yaml" test -f "$TESTD4/compose.yaml"
check_not "dry-run: keine .env" test -f "$TESTD4/.env"
check_not "dry-run: TEST_DIR gar nicht angelegt" test -d "$TESTD4"

# --- Statische Checks / Runbook / Secrets -----------------------------------
check "clone-prod.sh: bash -n" bash -n "$SCRIPT"
check "clone-prod.sh: shellcheck" shellcheck "$SCRIPT"
check "clone-prod.sh: ausführbar" test -x "$SCRIPT"
check "Runbook existiert" test -f "$RUNBOOK"
contains "Runbook: Schritt 0 Preflight" "Schritt 0" "$RUNBOOK"
contains "Runbook: clone-prod.sh --check" "clone-prod.sh --check" "$RUNBOOK"
contains "Runbook: Preflight vorhanden? sonst klonen" "Instanz vorhanden? sonst klonen" "$RUNBOOK"
check_not "kein hartkodiertes RCON-Passwort im Script" grep -qE 'RCON_PASSWORD=[A-Za-z0-9]{8,}' "$SCRIPT"
check_not "kein hartkodiertes RCON-Passwort im Runbook" grep -qE 'RCON_PASSWORD=[A-Za-z0-9]{8,}' "$RUNBOOK"

echo "-----------------------------------------"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
