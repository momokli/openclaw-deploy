#!/usr/bin/env bash
# announce-guard.sh — Announce-Hygiene fuer Subagent-/Orchestrator-Reports (Issue #27).
#
# Problem (beobachtet in der main-Session):
#   1) Lange Reports kommen als "[child result truncated]" an — die Gateway-Runtime kappt
#      Announce-Texte hart (6000 / 512 Zeichen, kein Env-Override). Der Parent muss per
#      sessions_history nachladen (Extra-Turns/Tokens).
#   2) Identische Announce-Events werden mehrfach zugestellt (Kontext-/Token-Kosten).
#
# Dieser Helper macht einen Report announce-sicher, BEVOR er als Abschluss-Report rausgeht:
#   - Cap:    kappt den Report auf --max-chars (Default 1500) und legt den vollen Text als
#             Detail-Datei ab. Die gekappte Ausgabe endet mit einem Pointer auf die Datei.
#   - Dedupe: sha256 des Reports; identischer Report innerhalb --ttl Sekunden wird nicht
#             erneut ausgegeben (Exit 10).
#
# Der volle Text bleibt damit erhalten (Datei/PR-Comment), waehrend die Announce kurz bleibt.
#
# Nutzung:
#   scripts/announce-guard.sh [opts] [REPORT_DATEI]   # sonst stdin
#
# Beispiele:
#   scripts/announce-guard.sh report.md
#   scripts/announce-guard.sh < report.md
#   scripts/announce-guard.sh --max-chars 800 --detail-dir ./out report.md
#   scripts/announce-guard.sh --state-file /tmp/seen --ttl 600 report.md
#
# Optionen:
#   --max-chars N      Cap in Zeichen (Default 1500, Env ANNOUNCE_MAX_CHARS)
#   --detail-dir DIR   Zielverzeichnis der Detail-Datei (Default ${TMPDIR:-/tmp})
#   --detail-file PATH Expliziter Pfad der Detail-Datei (schlaegt --detail-dir)
#   --state-file PATH  Dedupe-State (Default ${XDG_CACHE_HOME:-$HOME/.cache}/openclaw/announce-guard-seen)
#   --ttl SECONDS      Dedupe-Fenster (Default 3600, Env ANNOUNCE_DEDUPE_TTL). 0 = nie ablaufen
#   --no-dedupe        Dedupe abschalten
#   --no-cap           Capping abschalten (nur Dedupe)
#   -h, --help         Hilfe
#
# Exit: 0 = Announce erzeugt, 10 = Duplikat (keine Ausgabe), 2 = Usage-/IO-Fehler.

set -uo pipefail

PROG="announce-guard"
MAX_CHARS="${ANNOUNCE_MAX_CHARS:-1500}"
DETAIL_DIR="${TMPDIR:-/tmp}"
DETAIL_FILE=""
STATE_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/openclaw/announce-guard-seen"
TTL="${ANNOUNCE_DEDUPE_TTL:-3600}"
USE_DEDUPE=1
USE_CAP=1
INPUT=""

usage() {
    sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'
}

die() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --max-chars)  [ $# -ge 2 ] || die "--max-chars braucht einen Wert"; MAX_CHARS="$2"; shift 2 ;;
        --detail-dir) [ $# -ge 2 ] || die "--detail-dir braucht einen Wert"; DETAIL_DIR="$2"; shift 2 ;;
        --detail-file)[ $# -ge 2 ] || die "--detail-file braucht einen Wert"; DETAIL_FILE="$2"; shift 2 ;;
        --state-file) [ $# -ge 2 ] || die "--state-file braucht einen Wert"; STATE_FILE="$2"; shift 2 ;;
        --ttl)        [ $# -ge 2 ] || die "--ttl braucht einen Wert"; TTL="$2"; shift 2 ;;
        --no-dedupe)  USE_DEDUPE=0; shift ;;
        --no-cap)     USE_CAP=0; shift ;;
        -h|--help)    usage; exit 0 ;;
        --)           shift; break ;;
        -*)           die "unbekannte Option: $1" ;;
        *)            [ -z "$INPUT" ] || die "nur eine Report-Datei erlaubt"; INPUT="$1"; shift ;;
    esac
done
[ $# -gt 0 ] && die "unerwartetes Argument: $1"

case "$MAX_CHARS" in ''|*[!0-9]*) die "--max-chars muss eine nicht-negative Zahl sein" ;; esac
case "$TTL" in ''|*[!0-9]*) die "--ttl muss eine nicht-negative Zahl sein" ;; esac

# ── Report einlesen ─────────────────────────────────────────────────────────
if [ -n "$INPUT" ]; then
    [ -r "$INPUT" ] || die "Report nicht lesbar: $INPUT"
    text="$(cat -- "$INPUT")" || die "Report konnte nicht gelesen werden: $INPUT"
else
    text="$(cat)"
fi

# Leerer Report: nichts anzukündigen (kein Dedupe-Record).
if [ -z "${text//[[:space:]]/}" ]; then
    exit 0
fi

# sha256 des VOLLEN Reports: Identität des Events (Dedupe) + stabiler Detail-Dateiname.
hash="$(printf '%s' "$text" | sha256sum | awk '{print $1}')"

# ── Cap + Detail-Datei ──────────────────────────────────────────────────────
len="${#text}"
out="$text"
detail=""
if [ "$USE_CAP" = 1 ] && [ "$len" -gt "$MAX_CHARS" ]; then
    if [ -n "$DETAIL_FILE" ]; then
        detail="$DETAIL_FILE"
    else
        detail="${DETAIL_DIR%/}/announce-${hash:0:12}.md"
    fi
    ddir="$(dirname -- "$detail")"
    [ -d "$ddir" ] || mkdir -p -- "$ddir" 2>/dev/null
    if ! printf '%s\n' "$text" >"$detail"; then
        die "Detail-Datei nicht schreibbar: $detail"
    fi
    marker="
…[announce capped at ${MAX_CHARS} chars — full report: ${detail}]"
    mlen="${#marker}"
    keep=$((MAX_CHARS - mlen))
    if [ "$keep" -lt 1 ]; then
        out="${marker:0:$MAX_CHARS}"
    else
        out="${text:0:$keep}${marker}"
    fi
fi

# ── Dedupe (Message-Hash) ───────────────────────────────────────────────────
if [ "$USE_DEDUPE" = 1 ]; then
    now="$(date +%s)"
    if [ -r "$STATE_FILE" ]; then
        last="$(awk -F'\t' -v h="$hash" '$1==h{print $2}' "$STATE_FILE" | tail -n1)"
        if [ -n "${last:-}" ]; then
            if [ "$TTL" -eq 0 ]; then
                exit 10
            elif [ $((now - last)) -lt "$TTL" ]; then
                exit 10
            fi
        fi
    fi
    sdir="$(dirname -- "$STATE_FILE")"
    [ -d "$sdir" ] || mkdir -p -- "$sdir" 2>/dev/null
    # alte Einträge prunen + aktuellen Hash recorden (bounded growth)
    if [ "$TTL" -gt 0 ]; then
        if [ -r "$STATE_FILE" ]; then
            awk -F'\t' -v now="$now" -v ttl="$TTL" '($2+0) > (now-ttl)' "$STATE_FILE" >"$STATE_FILE.tmp.$$" 2>/dev/null \
                && mv -f -- "$STATE_FILE.tmp.$$" "$STATE_FILE" 2>/dev/null
        fi
    fi
    printf '%s\t%s\n' "$hash" "$now" >>"$STATE_FILE" 2>/dev/null \
        || die "Dedupe-State nicht schreibbar: $STATE_FILE"
fi

printf '%s\n' "$out"
exit 0
