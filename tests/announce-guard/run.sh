#!/usr/bin/env bash
# tests/announce-guard/run.sh — Offline-Harness fuer scripts/announce-guard.sh (Issue #27).
#
# Reines bash, kein Netz: prueft Cap (Zeichengrenze + Detail-Datei + UTF-8-Sicherheit)
# und Dedupe (Message-Hash inkl. TTL + --no-dedupe). Jeder Fall laeuft in einem eigenen
# TMP-Verzeichnis mit explizitem --state-file/--detail-dir, beruehrt also nie $HOME.
#
# Aufruf:
#   bash tests/announce-guard/run.sh          # gruener Lauf gegen das echte Script
#   bash tests/announce-guard/run.sh --red    # red-before-green: naives `cat` faellt durch
#
# Exit 0 = alle Tests gruen.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="${ANNOUNCE_GUARD_SCRIPT:-$ROOT/scripts/announce-guard.sh}"
MODE="${1:-}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
info()  { printf '  --   %s\n' "$1"; }

# run_script <dir> <args...>  (stdin = "$STDIN_DATA")
RC=0; OUT=""; ERR=""
run_script() {
    local dir="$1"; shift
    mkdir -p "$dir"
    printf '%s' "${STDIN_DATA:-}" >"$dir/stdin"
    RC=0
    OUT="$(ANNOUNCE_GUARD_SCRIPT="$SCRIPT" bash "$SCRIPT" "$@" <"$dir/stdin" 2>"$dir/err")" || RC=$?
    ERR="$(cat "$dir/err")"
}

# long_report <chars> -> report of exactly <chars> ASCII chars, no trailing newline
long_report() { local n="$1" s; s="$(printf '%*s' "$n" '' | tr ' ' 'x')"; printf '%s' "$s"; }

# ── red-before-green: naives `cat` (kein Cap, keine Dedupe) ─────────────────
if [ "$MODE" = "--red" ]; then
    echo "== red-before-green: naives fixtures/naive.sh (erwartet: faellt durch) =="
    NAIVE="$HERE/fixtures/naive.sh"
    [ -x "$NAIVE" ] || { echo "  FAIL Fixture fehlt/nicht ausfuehrbar: $NAIVE"; exit 1; }
    red=0
    rd="$TMP/red"; mkdir -p "$rd"
    rep="$(long_report 4000)"; printf '%s' "$rep" >"$rd/in"
    nout="$(bash "$NAIVE" "$rd/in")"
    if [ "${#nout}" -gt 1500 ]; then info "cap: naiv gibt ${#nout} Zeichen aus (>1500) → red bestaetigt"; red=$((red+1));
    else bad "red:cap — naiv unerwartet kurz (${#nout})"; fi
    n1="$(bash "$NAIVE" "$rd/in")"; n2="$(bash "$NAIVE" "$rd/in")"
    if [ -n "$n1" ] && [ -n "$n2" ]; then info "dedupe: naiv liefert identischen Report zweimal → red bestaetigt"; red=$((red+1));
    else bad "red:dedupe — naiv lieferte nicht zweimal Ausgabe"; fi
    echo "== red proof: $red/2 Signaturen scheitern am naiven Script =="
    [ "$red" = 2 ] && { echo "RED OK"; exit 0; }
    echo "RED INCOMPLETE"; exit 1
fi

echo "== tests/announce-guard/run.sh — script: $SCRIPT =="
if [ -f "$SCRIPT" ] && [ -x "$SCRIPT" ]; then ok "scripts/announce-guard.sh vorhanden + ausfuehrbar"; else bad "scripts/announce-guard.sh vorhanden + ausfuehrbar"; fi

# ── t01 --help ──────────────────────────────────────────────────────────────
run_script "$TMP/t01" --help
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'Nutzung:'; then ok "--help → Exit 0 + Nutzung"; else bad "--help → Exit 0 + Nutzung (rc=$RC)"; fi

# ── t02 unbekannte Option → Exit 2 ──────────────────────────────────────────
run_script "$TMP/t02" --bogus
if [ "$RC" = 2 ] && printf '%s' "$ERR" | grep -q 'unbekannte Option'; then ok "unbekannte Option → Exit 2"; else bad "unbekannte Option → Exit 2 (rc=$RC)"; fi

# ── t03 fehlende Report-Datei → Exit 2 ──────────────────────────────────────
run_script "$TMP/t03" --state-file "$TMP/t03/seen" "$TMP/t03/nope.md"
if [ "$RC" = 2 ] && printf '%s' "$ERR" | grep -q 'nicht lesbar'; then ok "fehlende Report-Datei → Exit 2"; else bad "fehlende Report-Datei → Exit 2 (rc=$RC)"; fi

# ── t04 kurzer Report bleibt unveraendert, keine Detail-Datei ───────────────
short="Kurzer Report: alles gruen."
mkdir -p "$TMP/t04"; printf '%s' "$short" >"$TMP/t04/in.md"
run_script "$TMP/t04" --state-file "$TMP/t04/seen" --detail-dir "$TMP/t04/detail" "$TMP/t04/in.md"
if [ "$RC" = 0 ] && [ "$OUT" = "$short" ]; then ok "kurzer Report unveraendert (kein Marker)"; else bad "kurzer Report unveraendert (rc=$RC, len=${#OUT})"; fi
if [ -z "$(ls -A "$TMP/t04/detail" 2>/dev/null)" ]; then ok "keine Detail-Datei bei ungekapptem Report"; else bad "Detail-Datei trotz ungekapptem Report angelegt"; fi

# ── t05 langer Report: Cap + Marker + Detail-Datei vollstaendig ─────────────
rep="$(long_report 5000)"; mkdir -p "$TMP/t05"; printf '%s' "$rep" >"$TMP/t05/in.md"
run_script "$TMP/t05" --state-file "$TMP/t05/seen" --detail-dir "$TMP/t05/detail" "$TMP/t05/in.md"
detail="$(ls "$TMP/t05/detail"/announce-*.md 2>/dev/null | head -n1)"
if [ "$RC" = 0 ] && [ "${#OUT}" -le 1500 ]; then ok "langer Report auf ≤1500 Zeichen gekappt (${#OUT})"; else bad "Cap: ${#OUT} Zeichen, rc=$RC"; fi
if printf '%s' "$OUT" | grep -q 'announce capped at 1500 chars'; then ok "Marker nennt Cap"; else bad "Marker fehlt"; fi
if [ -n "$detail" ] && printf '%s' "$OUT" | grep -qF "$detail"; then ok "Marker verweist auf Detail-Datei"; else bad "Marker ohne Detail-Pfad (detail='$detail')"; fi
if [ -n "$detail" ] && [ "$(cat -- "$detail")" = "$rep" ]; then ok "Detail-Datei enthaelt den vollen Report"; else bad "Detail-Datei unvollstaendig"; fi

# ── t06 eigenes --max-chars ─────────────────────────────────────────────────
mkdir -p "$TMP/t06"; printf '%s' "$(long_report 3000)" >"$TMP/t06/in.md"
run_script "$TMP/t06" --max-chars 40 --state-file "$TMP/t06/seen" --detail-dir "$TMP/t06/detail" "$TMP/t06/in.md"
if [ "$RC" = 0 ] && [ "${#OUT}" -le 40 ] && printf '%s' "$OUT" | grep -q 'capped at 40 chars'; then ok "--max-chars 40 → ≤40 Zeichen"; else bad "--max-chars 40 → ${#OUT} Zeichen, rc=$RC"; fi

# ── t07 --no-cap laesst langen Report durch ─────────────────────────────────
mkdir -p "$TMP/t07"; printf '%s' "$(long_report 3000)" >"$TMP/t07/in.md"
run_script "$TMP/t07" --no-cap --state-file "$TMP/t07/seen" --detail-dir "$TMP/t07/detail" "$TMP/t07/in.md"
if [ "$RC" = 0 ] && [ "${#OUT}" = 3000 ]; then ok "--no-cap → unveraendert (3000)"; else bad "--no-cap → ${#OUT} Zeichen, rc=$RC"; fi

# ── t08 UTF-8-Sicherheit an der Cap-Grenze ──────────────────────────────────
utf="$(printf 'ä漢 %0.s' $(seq 1 1500))"; mkdir -p "$TMP/t08"; printf '%s' "$utf" >"$TMP/t08/in.md"
run_script "$TMP/t08" --max-chars 1000 --state-file "$TMP/t08/seen" --detail-dir "$TMP/t08/detail" "$TMP/t08/in.md"
detail8="$(ls "$TMP/t08/detail"/announce-*.md 2>/dev/null | head -n1)"
if [ "$RC" = 0 ] && [ "${#OUT}" -le 1000 ]; then ok "UTF-8: Ausgabe ≤1000 Zeichen (${#OUT})"; else bad "UTF-8: ${#OUT} Zeichen, rc=$RC"; fi
# UTF-8-Validierung ueber Python statt `iconv`: das macOS-iconv scheitert hier auch an
# gueltigem UTF-8 (ENOTTY) und war intermittierend.
if printf '%s' "$OUT" | python3 -c 'import sys; sys.stdin.buffer.read().decode("utf-8")' 2>/dev/null; then ok "UTF-8: Ausgabe ist gueltiges UTF-8 (kein halbes Zeichen)"; else bad "UTF-8: Ausgabe enthaelt kaputte Sequenz"; fi
if [ -n "$detail8" ] && python3 -c 'import sys; open(sys.argv[1],"rb").read().decode("utf-8")' "$detail8" 2>/dev/null; then ok "UTF-8: Detail-Datei gueltig"; else bad "UTF-8: Detail-Datei ungueltig"; fi

# ── t09 Dedupe: identischer Report → zweiter Lauf Exit 10, keine Ausgabe ────
r="Report A: identisch."; mkdir -p "$TMP/t09"; printf '%s' "$r" >"$TMP/t09/in.md"
run_script "$TMP/t09/a" --state-file "$TMP/t09/seen" --detail-dir "$TMP/t09/detail" "$TMP/t09/in.md"
rc1="$RC"; out1="$OUT"
run_script "$TMP/t09/b" --state-file "$TMP/t09/seen" --detail-dir "$TMP/t09/detail" "$TMP/t09/in.md"
if [ "$rc1" = 0 ] && [ -n "$out1" ] && [ "$RC" = 10 ] && [ -z "$OUT" ]; then ok "Dedupe: erster Exit 0, zweiter Exit 10 ohne Ausgabe"; else bad "Dedupe: rc1=$rc1 rc2=$RC out2='${OUT:0:20}'"; fi

# ── t10 Dedupe: unterschiedlicher Report → kein Duplikat ────────────────────
mkdir -p "$TMP/t10"; printf 'Report B: anders.' >"$TMP/t10/in.md"
run_script "$TMP/t10" --state-file "$TMP/t09/seen" --detail-dir "$TMP/t10/detail" "$TMP/t10/in.md"
if [ "$RC" = 0 ] && [ -n "$OUT" ]; then ok "anderer Report → Exit 0 (nicht dedupliziert)"; else bad "anderer Report → rc=$RC"; fi

# ── t11 TTL: abgelaufener Eintrag blockt nicht, frischer schon ──────────────
r="Report C: ttl."; mkdir -p "$TMP/t11"; printf '%s' "$r" >"$TMP/t11/in.md"
h="$(printf '%s' "$r" | sha256sum | awk '{print $1}')"
old=$(( $(date +%s) - 7200 ))
printf '%s\t%s\n' "$h" "$old" >"$TMP/t11/seen"
run_script "$TMP/t11/expired" --ttl 3600 --state-file "$TMP/t11/seen" --detail-dir "$TMP/t11/detail" "$TMP/t11/in.md"
if [ "$RC" = 0 ] && [ -n "$OUT" ]; then ok "TTL: abgelaufener Hash blockt nicht"; else bad "TTL: abgelaufener Hash → rc=$RC"; fi
printf '%s\t%s\n' "$h" "$(date +%s)" >"$TMP/t11/seen"
run_script "$TMP/t11/fresh" --ttl 3600 --state-file "$TMP/t11/seen" --detail-dir "$TMP/t11/detail" "$TMP/t11/in.md"
if [ "$RC" = 10 ]; then ok "TTL: frischer Hash → Exit 10"; else bad "TTL: frischer Hash → rc=$RC"; fi

# ── t12 --no-dedupe: identisch zweimal → beide Exit 0 ───────────────────────
r="Report D: no-dedupe."; mkdir -p "$TMP/t12"; printf '%s' "$r" >"$TMP/t12/in.md"
run_script "$TMP/t12/a" --no-dedupe --state-file "$TMP/t12/seen" --detail-dir "$TMP/t12/detail" "$TMP/t12/in.md"; rc1="$RC"
run_script "$TMP/t12/b" --no-dedupe --state-file "$TMP/t12/seen" --detail-dir "$TMP/t12/detail" "$TMP/t12/in.md"; rc2="$RC"
if [ "$rc1" = 0 ] && [ "$rc2" = 0 ]; then ok "--no-dedupe → beide Exit 0"; else bad "--no-dedupe → rc1=$rc1 rc2=$rc2"; fi

# ── t13 leerer Input → Exit 0, keine Ausgabe ────────────────────────────────
STDIN_DATA="" run_script "$TMP/t13" --state-file "$TMP/t13/seen" --detail-dir "$TMP/t13/detail"
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "leerer Input → Exit 0 ohne Ausgabe"; else bad "leerer Input → rc=$RC out='${OUT:0:10}'"; fi

# ── t14 stdin statt Datei ───────────────────────────────────────────────────
STDIN_DATA="Report E via stdin." run_script "$TMP/t14" --state-file "$TMP/t14/seen" --detail-dir "$TMP/t14/detail"
if [ "$RC" = 0 ] && [ "$OUT" = "Report E via stdin." ]; then ok "stdin-Report verarbeitet"; else bad "stdin-Report → rc=$RC"; fi

# ── t15 Dedupe ueber zwei unterschiedliche Cap-Darstellungen hinweg ────────
# Volltext-Hash: derselbe Report mit anderem --max-chars ist trotzdem dasselbe Event.
r="$(long_report 4000)"; mkdir -p "$TMP/t15"; printf '%s' "$r" >"$TMP/t15/in.md"
run_script "$TMP/t15/a" --max-chars 500 --state-file "$TMP/t15/seen" --detail-dir "$TMP/t15/detail" "$TMP/t15/in.md"; rc1="$RC"
run_script "$TMP/t15/b" --max-chars 900 --state-file "$TMP/t15/seen" --detail-dir "$TMP/t15/detail" "$TMP/t15/in.md"; rc2="$RC"
if [ "$rc1" = 0 ] && [ "$rc2" = 10 ]; then ok "Dedupe nutzt Volltext-Hash (cap-unabhaengig)"; else bad "Volltext-Hash-Dedupe → rc1=$rc1 rc2=$rc2"; fi

# ── Summary ─────────────────────────────────────────────────────────────────
printf '\n# %d/%d Tests gruen\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" = 0 ] || exit 1
