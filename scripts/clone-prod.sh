#!/usr/bin/env bash
# clone-prod.sh — idempotentes Setup der aero-Test-Instanz als Klon von PROD (Issue #42).
#
# Preflight + Setup in einem: „Instanz vorhanden? sonst klonen." Erkennt Drift
# (Verzeichnis/Container fehlt) statt sie zu verschweigen und baut die Instanz bei
# Bedarf reproduzierbar auf. Zweiter Lauf ist ein No-op.
#
# Was das Script tut:
#   1. Preflight: existiert der Container (und die erwartete Basis)? -> nichts tun.
#   2. Compose: versionierte Vorlage scripts/aero-test/compose.template.yaml (#43)
#      nach <TEST_DIR>/compose.yaml kopieren.
#   3. Freien Port ab PORT_BASE (Default 25582) vergeben (ss/netstat + docker-Ports).
#   4. data per rsync aus PROD klonen — OHNE world*, ftbbackups3, logs, crash-reports
#      (frische Welt, kein 25-G-Blindkopie).
#   5. RCON-Test-Passwort in <TEST_DIR>/.env (chmod 600) setzen/schreiben.
#   6. RCON-Properties patchen via scripts/aero-test/apply-rcon-fix.sh (#43).
#
# Usage:
#   scripts/clone-prod.sh                 # Preflight + sicherstellen (kein Start)
#   scripts/clone-prod.sh --check         # nur Preflight: 0 = vorhanden, 3 = fehlt/Drift
#   scripts/clone-prod.sh --start         # danach `docker compose up -d`
#   scripts/clone-prod.sh --dry-run       # nur zeigen, nichts schreiben/starten
#
# Optionen:
#   --check                Preflight-Modus (keine Änderung); Exit 0 vorhanden / 3 fehlt
#   --start                Container nach dem Setup starten
#   --dry-run              keine Schreib-/Docker-Aktionen, nur Ausgabe
#   --force                vorhandene Dateien/Container neu aufbauen
#   --no-data              data-Klon überspringen
#   --refresh-data         data erneut spiegeln (auch wenn data/ gefüllt ist)
#   --port N               festen Port verwenden (Default: automatisch ab PORT_BASE)
#   --password PW          RCON-Passwort (alternativ Env RCON_PASSWORD; sonst generiert)
#   --prod-dir DIR         PROD-Verzeichnis (Default /srv/aero)
#   --test-dir DIR         TEST-Verzeichnis (Default /srv/aero-test)
#   --test-name NAME       Container-/Service-Name (Default aero-test)
#   --compose-template F   Compose-Vorlage (Default scripts/aero-test/compose.template.yaml)
#   --rcon-fix F           Properties-Patch-Script (Default scripts/aero-test/apply-rcon-fix.sh)
#   -h, --help             Hilfe
#
# Exit-Codes: 0 ok · 2 Usage · 3 --check: Instanz fehlt/Drift · 4 Vorlage/Preflight fehlt
set -euo pipefail

# --- Defaults / Env ---------------------------------------------------------
PROD_DIR="${PROD_DIR:-/srv/aero}"
TEST_DIR="${TEST_DIR:-/srv/aero-test}"
TEST_NAME="${TEST_NAME:-aero-test}"
PORT_BASE="${PORT_BASE:-25582}"
PORT_MAX="${PORT_MAX:-25620}"
FORCED_PORT=""
RCON_PASSWORD="${RCON_PASSWORD:-}"
SUDO="${SUDO:-}"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"
COMPOSE_TEMPLATE="${COMPOSE_TEMPLATE:-$REPO_ROOT/scripts/aero-test/compose.template.yaml}"
RCON_FIX_SCRIPT="${RCON_FIX_SCRIPT:-$REPO_ROOT/scripts/aero-test/apply-rcon-fix.sh}"

MODE="ensure"           # ensure | check
DO_START=0
DRY_RUN=0
FORCE=0
DO_DATA=1
REFRESH_DATA=0

log()  { printf '[clone-prod] %s\n' "$*"; }
warn() { printf '[clone-prod] WARN: %s\n' "$*" >&2; }
die()  { printf '[clone-prod] FEHLER: %s\n' "$*" >&2; exit "${2:-2}"; }

# run: fuehrt ein Kommando aus, respektiert --dry-run.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

# run_masked: wie run(), aber maskiert ein Secret im dry-run-Log.
# $1 = zu maskierender Klartext (nicht in die Ausgabe uebernehmen), Rest = Kommando.
run_masked() {
  local secret="$1"; shift
  if [ "$DRY_RUN" -eq 1 ]; then
    local out="" a
    for a in "$@"; do
      [ -n "$secret" ] && a="${a//"$secret"/***}"
      out="$out $a"
    done
    printf '[dry-run]%s\n' "$out"
    return 0
  fi
  "$@"
}

# as_root: fuehrt Kommando mit $SUDO aus (falls gesetzt/erforderlich).
as_root() {
  if [ -n "$SUDO" ]; then "$SUDO" "$@"; else "$@"; fi
}

# usage: druckt den Header-Kommentar (Zeile 2 bis vor `set -euo pipefail`).
# Der letzte Treffer der Range wird verworfen, sonst leakt die `set`-Zeile in --help.
usage() { sed -n '2,/^set /{/^set /d;p;}' "$0"; }

# --- Argumente --------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --check)           MODE="check"; shift ;;
    --start)           DO_START=1; shift ;;
    --dry-run)         DRY_RUN=1; shift ;;
    --force)           FORCE=1; shift ;;
    --no-data)         DO_DATA=0; shift ;;
    --refresh-data)    REFRESH_DATA=1; shift ;;
    --port)            FORCED_PORT="${2:?--port braucht einen Wert}"; shift 2 ;;
    --password)        RCON_PASSWORD="${2:?--password braucht einen Wert}"; shift 2 ;;
    --prod-dir)        PROD_DIR="${2:?--prod-dir braucht einen Wert}"; shift 2 ;;
    --test-dir)        TEST_DIR="${2:?--test-dir braucht einen Wert}"; shift 2 ;;
    --test-name)       TEST_NAME="${2:?--test-name braucht einen Wert}"; shift 2 ;;
    --compose-template) COMPOSE_TEMPLATE="${2:?--compose-template braucht einen Wert}"; shift 2 ;;
    --rcon-fix)        RCON_FIX_SCRIPT="${2:?--rcon-fix braucht einen Wert}"; shift 2 ;;
    --sudo)            SUDO="sudo"; shift ;;
    --no-sudo)         SUDO=""; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) die "Unbekannte Option: $1 (siehe --help)" ;;
  esac
done

DATA_DIR="$TEST_DIR/data"
COMPOSE_FILE="$TEST_DIR/compose.yaml"
ENV_FILE="$TEST_DIR/.env"
LOCK_FILE="${TMPDIR:-/tmp}/clone-prod.$(printf '%s' "$TEST_DIR" | tr -c 'A-Za-z0-9' '_').lock"

# --- Preflight-Helfer -------------------------------------------------------

# container_exists: Container $TEST_NAME existiert (egal ob running/exited).
container_exists() {
  command -v docker >/dev/null 2>&1 || return 1
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$TEST_NAME"
}

# dir_present: TEST_DIR hat eine Compose-Datei (Hinweis auf ein frueheres Setup).
# data/ wird separat geprueft (siehe instance_status): verwaistes data/ allein = drift.
dir_present() {
  [ -f "$COMPOSE_FILE" ]
}

# status: vorhanden | drift | missing
instance_status() {
  if container_exists; then
    echo "present"
  elif dir_present || [ -d "$DATA_DIR" ]; then
    echo "drift"
  else
    echo "missing"
  fi
}

# port_in_use PORT -> 0 wenn belegt (Listening oder docker-published)
port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    if ss -Htnl 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$"; then return 0; fi
  elif command -v netstat >/dev/null 2>&1; then
    if netstat -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$"; then return 0; fi
  fi
  if command -v docker >/dev/null 2>&1; then
    if docker ps --format '{{.Ports}}' 2>/dev/null | grep -qE "(^|[^0-9])${p}->"; then return 0; fi
  fi
  return 1
}

pick_free_port() {
  local p="$PORT_BASE"
  while [ "$p" -le "$PORT_MAX" ]; do
    if ! port_in_use "$p"; then echo "$p"; return 0; fi
    p=$((p + 1))
  done
  return 1
}

gen_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  elif [ -r /dev/urandom ] && command -v od >/dev/null 2>&1; then
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
  else
    # letzter Fallback: zeitbasierter Wert (nur Test-Instanz)
    printf 'aero-test-%s-%s' "$(date +%s)" "$$"
  fi
}

env_get() {  # env_get KEY -> Wert aus $ENV_FILE (leer wenn nicht vorhanden)
  [ -f "$ENV_FILE" ] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n1
}

# --- Preflight --------------------------------------------------------------

status="$(instance_status)"
if [ "$MODE" = "check" ]; then
  case "$status" in
    present)
      log "OK: Instanz '$TEST_NAME' vorhanden."
      log "  compose: $COMPOSE_FILE"
      log "  data:    $DATA_DIR"
      exit 0
      ;;
    drift)
      warn "DRIFT: $TEST_DIR vorhanden, aber Container '$TEST_NAME' fehlt (kein laufender/existierender Container)."
      warn "  -> Setup nachziehen: $0"
      exit 3
      ;;
    *)
      warn "MISSING: weder Container '$TEST_NAME' noch $TEST_DIR/compose.yaml vorhanden."
      warn "  -> Instanz klonen: $0"
      exit 3
      ;;
  esac
fi

if [ "$status" = "present" ] && [ "$FORCE" -ne 1 ]; then
  log "Instanz '$TEST_NAME' bereits vorhanden — nichts zu tun (idempotent)."
  if [ "$DO_START" -eq 1 ]; then
    log "Start angefordert: docker compose --env-file $ENV_FILE -f $COMPOSE_FILE up -d"
    run docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d
  fi
  exit 0
fi

# --- Voraussetzungen --------------------------------------------------------
[ -f "$COMPOSE_TEMPLATE" ] || die "Compose-Vorlage fehlt: $COMPOSE_TEMPLATE
  Sie wird von Issue #43 geliefert (scripts/aero-test/compose.template.yaml).
  Alternativ mit --compose-template <datei> eine eigene Vorlage angeben." 4

if [ "$DO_DATA" -eq 1 ] && [ ! -d "$PROD_DIR/data" ]; then
  die "PROD-Datenverzeichnis fehlt: $PROD_DIR/data (--prod-dir prüfen oder --no-data)." 4
fi

# sudo automatisch, wenn Zielverzeichnis nicht schreibbar
parent="$(dirname "$TEST_DIR")"
if [ -z "$SUDO" ] && [ "$(id -u)" -ne 0 ] && [ -d "$parent" ] && [ ! -w "$parent" ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
    log "Zielverzeichnis $parent nicht schreibbar -> verwende sudo."
  fi
fi

# --- 1) Verzeichnis + Lock --------------------------------------------------
if [ "$DRY_RUN" -ne 1 ]; then
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Ein anderer clone-prod.sh-Lauf hält gerade $LOCK_FILE." 2
fi

run as_root mkdir -p "$TEST_DIR"

# --- 2) Compose aus der Vorlage --------------------------------------------
if [ -f "$COMPOSE_FILE" ] && [ "$FORCE" -ne 1 ]; then
  log "Compose vorhanden, bleibt: $COMPOSE_FILE"
else
  log "Compose aus Vorlage: $COMPOSE_TEMPLATE -> $COMPOSE_FILE"
  run as_root cp "$COMPOSE_TEMPLATE" "$COMPOSE_FILE"
fi

# --- 3) Freien Port vergeben -----------------------------------------------
existing_port="$(env_get MC_PORT)"
if [ -n "$existing_port" ] && [ -z "$FORCED_PORT" ] && ! port_in_use "$existing_port"; then
  port="$existing_port"
  log "Port aus .env übernommen: $port"
elif [ -n "$FORCED_PORT" ]; then
  port="$FORCED_PORT"
  if port_in_use "$port"; then
    die "Port $port ist belegt (--port erzwingt ihn trotzdem nicht)." 2
  fi
  log "Port erzwungen: $port"
else
  port="$(pick_free_port)" || die "Kein freier Port in [$PORT_BASE..$PORT_MAX] gefunden." 2
  log "Freier Port vergeben: $port"
fi

# --- 4) RCON-Test-Passwort ---------------------------------------------------
if [ -z "$RCON_PASSWORD" ]; then
  RCON_PASSWORD="$(env_get RCON_PASSWORD)"
  [ -n "$RCON_PASSWORD" ] || RCON_PASSWORD="$(gen_password)"
fi

emit_env() {
  printf 'CONTAINER_NAME=%s\n' "$TEST_NAME"
  printf 'MC_PORT=%s\n' "$port"
  printf 'DATA_DIR=./data\n'
  printf 'MEMORY=%s\n' "${MEMORY:-6G}"
  printf 'RCON_PASSWORD=%s\n' "$RCON_PASSWORD"
}

if [ "$DRY_RUN" -ne 1 ]; then
  # tee (ggf. via sudo) — schreibt auch in root-owned TEST_DIR korrekt.
  emit_env | as_root tee "$ENV_FILE" >/dev/null
  as_root chmod 600 "$ENV_FILE"
  log "Env geschrieben: $ENV_FILE (chmod 600, RCON-Passwort gesetzt)"
else
  log "[dry-run] würde $ENV_FILE schreiben (MC_PORT=$port, RCON_PASSWORD=***)"
fi

# --- 5) data klonen ---------------------------------------------------------
if [ "$DO_DATA" -eq 0 ]; then
  log "data-Klon übersprungen (--no-data)."
elif [ -d "$DATA_DIR" ] && [ -n "$(ls -A "$DATA_DIR" 2>/dev/null || true)" ] && [ "$REFRESH_DATA" -eq 0 ] && [ "$FORCE" -ne 1 ]; then
  log "data vorhanden, bleibt: $DATA_DIR (--refresh-data erzwingt Spiegelung)"
else
  log "data spiegeln: $PROD_DIR/data/ -> $DATA_DIR/ (ohne world*, ftbbackups3, logs, crash-reports)"
  run as_root mkdir -p "$DATA_DIR"
  run as_root rsync -a --delete \
    --exclude 'world' --exclude 'world.*' \
    --exclude 'ftbbackups3' \
    --exclude 'logs' --exclude 'crash-reports' \
    "$PROD_DIR/data/" "$DATA_DIR/"
fi

# --- 6) RCON-Properties patchen --------------------------------------------
if [ "$DO_DATA" -eq 0 ]; then
  log "Properties-Patch übersprungen (--no-data)."
elif [ -f "$RCON_FIX_SCRIPT" ]; then
  log "RCON-Properties patchen: $RCON_FIX_SCRIPT"
  run_masked "$RCON_PASSWORD" as_root env RCON_PASSWORD="$RCON_PASSWORD" "$RCON_FIX_SCRIPT" --data-dir "$DATA_DIR" --password "$RCON_PASSWORD"
else
  warn "Properties-Patch-Script fehlt: $RCON_FIX_SCRIPT"
  warn "  Es kommt aus Issue #43 (scripts/aero-test/apply-rcon-fix.sh)."
  warn "  Bis dahin: RCON-Fix manuell anwenden (docs/aero-test-rcon.md, Schritt 3)."
fi

# --- 7) Optionaler Start ----------------------------------------------------
if [ "$DO_START" -eq 1 ]; then
  log "Start: docker compose --env-file $ENV_FILE -f $COMPOSE_FILE up -d"
  run docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d
else
  log "Setup fertig. Start mit: cd $TEST_DIR && docker compose up -d"
fi

log "OK: aero-test-Instanz bereit (Container=$TEST_NAME, Port=$port, data=$DATA_DIR)."
