#!/usr/bin/env bash
# apply-rcon-fix.sh — macht den aero-test RCON-Fix reproduzierbar (Issue #43).
#
# Der Pack-Mod "default-server-properties" setzt beim ersten Boot `enable-rcon`
# in server.properties zurück, wodurch itzg nicht graceful stoppen kann. Dieses
# Script patcht BEIDE Quellen idempotent:
#   * default-server.properties  (Mod-Quelle, überlebt Reboots)
#   * server.properties          (aktuelle Laufzeit)
#
# Usage:
#   RCON_PASSWORD=<pw> ./apply-rcon-fix.sh [--data-dir DIR] [--password PW]
#
#   --data-dir  Verzeichnis mit den Properties (Default: ./data)
#   --password  RCON-Passwort (alternativ Env RCON_PASSWORD; erforderlich)
#
# Exit: 0 ok · 2 Usage/fehlendes data-dir · 3 Passwort fehlt
set -euo pipefail

DATA_DIR="./data"
PASSWORD="${RCON_PASSWORD:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --data-dir) DATA_DIR="${2:?--data-dir braucht einen Wert}"; shift 2 ;;
    --password) PASSWORD="${2:?--password braucht einen Wert}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$PASSWORD" ]; then
  echo "FEHLER: RCON-Passwort fehlt (--password oder RCON_PASSWORD)." >&2
  exit 3
fi

if [ ! -d "$DATA_DIR" ]; then
  echo "FEHLER: data-dir '$DATA_DIR' existiert nicht." >&2
  exit 2
fi

# set_prop FILE KEY VALUE — deterministisch: alle aktiven KEY=-Zeilen entfernen,
# dann genau einmal anhängen. Zweiter Lauf = identische Datei (idempotent).
set_prop() {
  local file="$1" key="$2" val="$3" tmp
  tmp="$(mktemp)"
  awk -v k="${key}=" 'index($0, k) == 1 { next } { print }' "$file" > "$tmp"
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  mv "$tmp" "$file"
}

# Symmetrisch für beide Dateien: der Runbook-Verify greppt default-server.properties UND
# server.properties mit demselben Muster (enable-rcon, rcon.password, rcon.port, enable-query).
patch_file() {
  local file="$1"
  [ -e "$file" ] || : > "$file"
  local before after
  before="$(sha256sum "$file" | awk '{print $1}')"
  set_prop "$file" "enable-rcon" "true"
  set_prop "$file" "broadcast-rcon-to-ops" "true"
  set_prop "$file" "rcon.password" "$PASSWORD"
  set_prop "$file" "rcon.port" "25575"
  set_prop "$file" "enable-query" "false"
  after="$(sha256sum "$file" | awk '{print $1}')"
  if [ "$before" = "$after" ]; then
    echo "OK  (unchanged): $file"
  else
    echo "OK  (patched):   $file"
  fi
}

patch_file "$DATA_DIR/default-server.properties"
patch_file "$DATA_DIR/server.properties"

echo "RCON-Fix angewendet in $DATA_DIR (enable-rcon=true, rcon.password=***, rcon.port=25575)."
