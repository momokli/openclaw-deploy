#!/bin/bash
# tests/pr-metadata/run.sh — Offline-Harness für scripts/pr-metadata.sh (Issue #40).
#
# Kein Netz, keine echten GitHub-Calls: `gh` wird durch einen PATH-Shim ersetzt,
# der argv + stdin in ein Logfile schreibt und für GETs canned JSON liefert.
# Damit prüfen wir Endpunkte, HTTP-Methode und den PATCH-/POST-Payload.
#
# red-before-green: ohne `scripts/pr-metadata.sh` schlagen alle Tests fehl.
# Aufruf: bash tests/pr-metadata/run.sh   (Exit 0 = alle grün)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/pr-metadata.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/gh" <<'SHIM'
#!/bin/bash
log="${GH_LOG:?GH_LOG not set}"
{ printf 'CALL:'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >>"$log"
case " $* " in
  *" --input "*)
    data="$(cat)"; printf 'STDIN:%s\n' "$data" >>"$log" ;;
esac
case " $* " in
  *" -X "*|*" --method "*) : ;;   # Mutation: keine Ausgabe
  *) printf '{"number":5,"title":"T","state":"open","base":{"ref":"main"},"body":"B"}\n' ;;
esac
exit 0
SHIM
chmod +x "$FAKEBIN/gh"

PASS=0; FAIL=0; N=0
ok()    { N=$((N+1)); PASS=$((PASS+1)); printf 'ok %d - %s\n' "$N" "$1"; }
notok() { N=$((N+1)); FAIL=$((FAIL+1)); printf 'not ok %d - %s\n' "$N" "$1"; }

RC=0; OUT=""; ERR=""; LOG=""
run() { # run <logname> <cwd> <args...>
  local lg="$TMP/$1.log"; shift
  local cwd="$1"; shift
  : > "$lg"
  ( cd "$cwd" && GH_LOG="$lg" PATH="$FAKEBIN:$PATH" bash "$SCRIPT" "$@" >"$TMP/out" 2>"$TMP/err" )
  RC=$?
  OUT="$(cat "$TMP/out")"; ERR="$(cat "$TMP/err")"; LOG="$lg"
}

stdin_json() { sed -n 's/^STDIN://p' "$LOG" | tr -d '\n'; }
has() { grep -q -- "$1" "$LOG"; }          # Log enthält (extended grep)
hasx() { grep -qE -- "$1" "$LOG"; }

# ── t01 Script vorhanden & ausführbar ───────────────────────────────────
if [ -f "$SCRIPT" ] && [ -x "$SCRIPT" ]; then ok "scripts/pr-metadata.sh vorhanden + ausführbar"; else notok "scripts/pr-metadata.sh vorhanden + ausführbar"; fi

# ── t02 --help ──────────────────────────────────────────────────────────
run help "$TMP" --help
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'Usage:'; then ok "--help → Exit 0 + Usage"; else notok "--help → Exit 0 + Usage (rc=$RC)"; fi

# ── t03 keine Operation → Usage-Fehler ──────────────────────────────────
run noop "$TMP" -n 5 -R o/r
if [ "$RC" = 2 ] && printf '%s' "$ERR" | grep -q 'keine Operation'; then ok "keine Operation → Exit 2"; else notok "keine Operation → Exit 2 (rc=$RC)"; fi

# ── t04 Nummer fehlt ────────────────────────────────────────────────────
run nonum "$TMP" -R o/r --body x
if [ "$RC" = 2 ]; then ok "Nummer fehlt → Exit 2"; else notok "Nummer fehlt → Exit 2 (rc=$RC)"; fi

# ── t05 --body-file → PATCH /pulls/<n> mit Body ────────────────────────
cat > "$TMP/body.md" <<'EOF'
## Was
Zeile mit "Quotes" und $Sonderzeichen\$ .
EOF
run bodyfile "$TMP" -n 5 -R o/r --body-file "$TMP/body.md"
if [ "$RC" = 0 ] && has 'CALL: api -X PATCH repos/o/r/pulls/5 --input -' \
   && [ "$(stdin_json | jq -r '.body' | grep -c 'Sonderzeichen')" = 1 ]; then
  ok "--body-file → PATCH /pulls/5 + Body im Payload"
else notok "--body-file → PATCH /pulls/5 + Body im Payload (rc=$RC)"; fi

# ── t06 --title + --base kombiniert ─────────────────────────────────────
run titlebase "$TMP" -n 7 -R o/r --title "Neuer Titel" --base develop
if [ "$RC" = 0 ] && [ "$(stdin_json | jq -r '.title')" = "Neuer Titel" ] \
   && [ "$(stdin_json | jq -r '.base')" = "develop" ]; then
  ok "--title/--base → beide Felder im PATCH"
else notok "--title/--base → beide Felder im PATCH (rc=$RC)"; fi

# ── t07 --add-label (mehrfach) → POST /issues/<n>/labels ────────────────
run addlabels "$TMP" -n 5 -R o/r --add-label triage:merge --add-label "orchestrator:dispatched"
if [ "$RC" = 0 ] && has 'CALL: api -X POST repos/o/r/issues/5/labels --input -' \
   && [ "$(stdin_json | jq -r '.labels|length')" = 2 ] \
   && [ "$(stdin_json | jq -r '.labels|index("orchestrator:dispatched")')" != null ]; then
  ok "--add-label → POST /issues/5/labels (2 Labels)"
else notok "--add-label → POST /issues/5/labels (2 Labels) (rc=$RC)"; fi

# ── t08 --remove-label → DELETE, URL-encoded ────────────────────────────
run rmlabel "$TMP" -n 5 -R o/r --remove-label "orchestrator:dispatched"
if [ "$RC" = 0 ] && hasx 'CALL: api -X DELETE repos/o/r/issues/5/labels/orchestrator%3Adispatched'; then
  ok "--remove-label → DELETE mit URL-Encoding"
else notok "--remove-label → DELETE mit URL-Encoding (rc=$RC)"; fi

# ── t09 --comment-file → POST /issues/<n>/comments ──────────────────────
printf 'Bericht: Tests gruen.\n' > "$TMP/comment.md"
run comment "$TMP" -n 5 -R o/r --comment-file "$TMP/comment.md"
if [ "$RC" = 0 ] && has 'CALL: api -X POST repos/o/r/issues/5/comments --input -' \
   && [ "$(stdin_json | jq -r '.body' | grep -c 'Bericht')" = 1 ]; then
  ok "--comment-file → POST /issues/5/comments"
else notok "--comment-file → POST /issues/5/comments (rc=$RC)"; fi

# ── t10 --show → GET (keine Mutation) ───────────────────────────────────
run show "$TMP" -n 5 -R o/r --show
if [ "$RC" = 0 ] && hasx 'CALL: api repos/o/r/pulls/5 ' && ! has '-X '; then
  ok "--show → GET /pulls/5 ohne Mutation"
else notok "--show → GET /pulls/5 ohne Mutation (rc=$RC)"; fi

# ── t11 fehlende Body-Datei → Exit 2 ────────────────────────────────────
run missing "$TMP" -n 5 -R o/r --body-file /nonexistent/body.md
if [ "$RC" = 2 ] && printf '%s' "$ERR" | grep -q 'nicht lesbar'; then ok "fehlende Body-Datei → Exit 2"; else notok "fehlende Body-Datei → Exit 2 (rc=$RC)"; fi

# ── t12 Repo-Inferenz aus git remote ────────────────────────────────────
REPODIR="$TMP/widgets"; mkdir -p "$REPODIR"
( cd "$REPODIR" && git init -q && git remote add origin https://github.com/acme/widgets.git )
run infer "$REPODIR" -n 7 --title x
if [ "$RC" = 0 ] && has 'repos/acme/widgets/pulls/7'; then ok "Repo-Inferenz aus git remote origin"; else notok "Repo-Inferenz aus git remote origin (rc=$RC)"; fi

# ── t13 nicht-numerische Nummer → Exit 2 ────────────────────────────────
run nonnumeric "$TMP" -n abc -R o/r --body x
if [ "$RC" = 2 ]; then ok "nicht-numerische Nummer → Exit 2"; else notok "nicht-numerische Nummer → Exit 2 (rc=$RC)"; fi

# ── t14 Patch + Read-back kombinierbar ──────────────────────────────────
run patchshow "$TMP" -n 5 -R o/r --body-file "$TMP/body.md" --show
if [ "$RC" = 0 ] && has '-X PATCH' && hasx 'CALL: api repos/o/r/pulls/5 '; then
  ok "--body-file + --show → PATCH dann GET"
else notok "--body-file + --show → PATCH dann GET (rc=$RC)"; fi

# ── Summary ─────────────────────────────────────────────────────────────
printf '\n# %d/%d Tests grün\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" = 0 ] || exit 1
