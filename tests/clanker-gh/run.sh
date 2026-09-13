#!/usr/bin/env bash
# tests/clanker-gh/run.sh — Offline-Harness fuer die Bot-Identitaets-Wrapper (Issue #103).
#
# Kein Netz, kein echtes `gh`: `gh`, `git` und `gh-bot-auth.sh` werden durch
# PATH-Shims ersetzt. Geprueft wird, ob die Wrapper beim aktiven App-Config die
# ambient gesetzte Token-Umgebung (GH_TOKEN/GITHUB_TOKEN/GH_ENTERPRISE_TOKEN)
# neutralisieren — und sie im Fallback (App nicht konfiguriert) unangetastet lassen.
#
# Hintergrund: `gh` hat klare Praezedenz — GH_TOKEN/GITHUB_TOKEN aus der Umgebung
# schlagen jede hosts.yml in GH_CONFIG_DIR. Ohne Neutralisierung laufen die
# Bot-Wrapper (und der git-Credential-Helper) als Ambient-User statt als [bot].
#
# Aufruf:
#   bash tests/clanker-gh/run.sh          # gruener Lauf gegen die echten Wrapper
#   bash tests/clanker-gh/run.sh --red    # red-before-green: Fixtures ohne unset fallen durch
#
# Exit 0 = alle Tests gruen.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
MODE="${1:-}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"

# ── PATH-Shim: gh — protokolliert die sichtbare Token-Umgebung ──────────────
cat > "$FAKEBIN/gh" <<'SHIM'
#!/bin/bash
log="${GH_LOG:?GH_LOG not set}"
printf 'gh TOKEN=[%s] GTOKEN=[%s] ETOKEN=[%s] CFG=[%s] ARGS=[%s]\n' \
  "${GH_TOKEN-<unset>}" "${GITHUB_TOKEN-<unset>}" "${GH_ENTERPRISE_TOKEN-<unset>}" \
  "${GH_CONFIG_DIR-<unset>}" "$*" >>"$log"
exit 0
SHIM

# ── PATH-Shim: git — protokolliert zusaetzlich die Commit-Identity ──────────
cat > "$FAKEBIN/git" <<'SHIM'
#!/bin/bash
log="${GH_LOG:?GH_LOG not set}"
printf 'git TOKEN=[%s] GTOKEN=[%s] ETOKEN=[%s] CFG=[%s] AN=[%s] AE=[%s] ARGS=[%s]\n' \
  "${GH_TOKEN-<unset>}" "${GITHUB_TOKEN-<unset>}" "${GH_ENTERPRISE_TOKEN-<unset>}" \
  "${GH_CONFIG_DIR-<unset>}" "${GIT_AUTHOR_NAME-<unset>}" "${GIT_AUTHOR_EMAIL-<unset>}" "$*" >>"$log"
exit 0
SHIM

# ── PATH-Shim: gh-bot-auth.sh — App-Config per FAKE_APP_CONFIGURED steuerbar ─
cat > "$FAKEBIN/gh-bot-auth.sh" <<'SHIM'
#!/bin/bash
app=""; mode="auth"
while [ $# -gt 0 ]; do
  case "$1" in
    --app) app="$2"; shift 2 ;;
    --token) mode="token"; shift ;;
    --bot-id) mode="bot-id"; shift ;;
    *) shift ;;
  esac
done
# --bot-id loest nur die Bot-User-ID auf (kein Mint) → immer OK.
[ "$mode" = "bot-id" ] && { printf '424242\n'; exit 0; }
[ "${FAKE_APP_CONFIGURED:-0}" = "1" ] || { echo "stub gh-bot-auth: $app not configured" >&2; exit 1; }
exit 0
SHIM

chmod +x "$FAKEBIN/gh" "$FAKEBIN/git" "$FAKEBIN/gh-bot-auth.sh"

PASS=0; FAIL=0; N=0
ok()    { N=$((N+1)); PASS=$((PASS+1)); printf 'ok %d - %s\n' "$N" "$1"; }
notok() { N=$((N+1)); FAIL=$((FAIL+1)); printf 'not ok %d - %s\n' "$N" "$1"; }

RC=0; OUT=""; ERR=""; LOG=""
# invoke <logfile> <home> <app-configured 0|1> <wrapper> [args...]
invoke() {
  local lg="$1" home="$2" cfg="$3" wrapper="$4"; shift 4
  mkdir -p "$home"
  : > "$lg"
  set +e
  GH_LOG="$lg" HOME="$home" PATH="$FAKEBIN:$PATH" FAKE_APP_CONFIGURED="$cfg" \
    GH_TOKEN="ambient-pat" GITHUB_TOKEN="ambient-github" GH_ENTERPRISE_TOKEN="ambient-ent" \
    bash "$wrapper" "$@" >"$TMP/out" 2>"$TMP/err"
  RC=$?
  set -e
  OUT="$(cat "$TMP/out")"; ERR="$(cat "$TMP/err")"; LOG="$lg"
}
has() { grep -qF -- "$1" "$LOG"; }

# ── red-before-green: Fixtures OHNE Neutralisierung (erwartet: leckt) ───────
if [ "$MODE" = "--red" ]; then
    echo "== red-before-green: Fixtures ohne unset (erwartet: faellt durch) =="
    red=0
    invoke "$TMP/red-gh.log" "$TMP/redhome" 1 "$HERE/fixtures/naive-clanker-gh.sh" api user
    if has 'TOKEN=[ambient-pat]'; then
        printf '  --   naive clanker-gh: gh sieht ambient GH_TOKEN → red bestaetigt\n'; red=$((red+1))
    else
        printf '  FAIL red:ghtoken — naive Wrapper hat Token unerwartet neutralisiert\n'
    fi
    invoke "$TMP/red-git.log" "$TMP/redhome" 1 "$HERE/fixtures/naive-clanker-git.sh" commit -m x
    if has 'TOKEN=[ambient-pat]'; then
        printf '  --   naive clanker-git: git sieht ambient GH_TOKEN → red bestaetigt\n'; red=$((red+1))
    else
        printf '  FAIL red:gittoken — naive Wrapper hat Token unerwartet neutralisiert\n'
    fi
    printf '== red proof: %d/2 Signaturen lecken im naiven Fixture ==\n' "$red"
    [ "$red" = 2 ] && { echo "RED OK"; exit 0; }
    echo "RED INCOMPLETE"; exit 1
fi

set -e

echo "== tests/clanker-gh/run.sh — root: $ROOT =="

# ── t01 Wrapper vorhanden + ausfuehrbar ─────────────────────────────────────
for w in clanker-gh claw-gh clanker-git claw-git gh-bot-auth.sh; do
    if [ -x "$ROOT/scripts/$w" ]; then ok "scripts/$w vorhanden + ausfuehrbar"; else notok "scripts/$w vorhanden + ausfuehrbar"; fi
done

# ── t02 clanker-gh @ App-Config: ambient GH_TOKEN neutralisiert ─────────────
invoke "$TMP/t02.log" "$TMP/home" 1 "$ROOT/scripts/clanker-gh" api user
if has 'TOKEN=[<unset>] GTOKEN=[<unset>] ETOKEN=[<unset>]' \
   && has "CFG=[$TMP/home/.config/gh-momo-clanker]" && [ "$RC" = 0 ]; then
    ok "clanker-gh: gh sieht kein ambient GH_TOKEN (App-Config aktiv)"
else
    notok "clanker-gh: gh sieht kein ambient GH_TOKEN (rc=$RC, log=$(cat "$LOG"))"
fi

# ── t03 clanker-gh: Argumente werden durchgereicht ──────────────────────────
if has 'ARGS=[api user]'; then ok "clanker-gh: Argumente an gh durchgereicht"; else notok "clanker-gh: Argumente an gh durchgereicht"; fi

# ── t04 claw-gh @ App-Config: dito fuer momo-claw ───────────────────────────
invoke "$TMP/t04.log" "$TMP/home" 1 "$ROOT/scripts/claw-gh" pr view 1
if has 'TOKEN=[<unset>] GTOKEN=[<unset>] ETOKEN=[<unset>]' \
   && has "CFG=[$TMP/home/.config/gh-momo-claw]" && [ "$RC" = 0 ]; then
    ok "claw-gh: gh sieht kein ambient GH_TOKEN (App-Config aktiv)"
else
    notok "claw-gh: gh sieht kein ambient GH_TOKEN (rc=$RC, log=$(cat "$LOG"))"
fi

# ── t05 clanker-gh Fallback: App nicht konfiguriert → Token bleibt ──────────
invoke "$TMP/t05.log" "$TMP/home" 0 "$ROOT/scripts/clanker-gh" api user
if has 'TOKEN=[ambient-pat]' && printf '%s' "$ERR" | grep -q 'falling back'; then
    ok "clanker-gh Fallback: Default-Identity behaelt ambient Token"
else
    notok "clanker-gh Fallback (rc=$RC, err=$ERR)"
fi

# ── t06 claw-gh Fallback: dito ──────────────────────────────────────────────
invoke "$TMP/t06.log" "$TMP/home" 0 "$ROOT/scripts/claw-gh" api user
if has 'TOKEN=[ambient-pat]' && printf '%s' "$ERR" | grep -q 'falling back'; then
    ok "claw-gh Fallback: Default-Identity behaelt ambient Token"
else
    notok "claw-gh Fallback (rc=$RC, err=$ERR)"
fi

# ── t07 clanker-git @ App-Config: Cred-Helper sieht kein ambient Token ──────
invoke "$TMP/t07.log" "$TMP/home" 1 "$ROOT/scripts/clanker-git" commit -m x
if has 'TOKEN=[<unset>] GTOKEN=[<unset>] ETOKEN=[<unset>]' \
   && has 'AN=[momo-clanker[bot]]' && [ "$RC" = 0 ]; then
    ok "clanker-git: git sieht kein ambient GH_TOKEN + Bot-Identity"
else
    notok "clanker-git: git sieht kein ambient GH_TOKEN (rc=$RC, log=$(cat "$LOG"))"
fi

# ── t08 claw-git @ App-Config: dito fuer momo-claw ──────────────────────────
invoke "$TMP/t08.log" "$TMP/home" 1 "$ROOT/scripts/claw-git" commit -m x
if has 'TOKEN=[<unset>] GTOKEN=[<unset>] ETOKEN=[<unset>]' \
   && has 'AN=[momo-claw[bot]]' && [ "$RC" = 0 ]; then
    ok "claw-git: git sieht kein ambient GH_TOKEN + Bot-Identity"
else
    notok "claw-git: git sieht kein ambient GH_TOKEN (rc=$RC, log=$(cat "$LOG"))"
fi

# ── t09 clanker-git Fallback: App nicht konfiguriert → Token bleibt ─────────
invoke "$TMP/t09.log" "$TMP/home" 0 "$ROOT/scripts/clanker-git" commit -m x
if has 'TOKEN=[ambient-pat]' && printf '%s' "$ERR" | grep -q 'falling back'; then
    ok "clanker-git Fallback: Default-Identity behaelt ambient Token"
else
    notok "clanker-git Fallback (rc=$RC, err=$ERR)"
fi

# ── t10 gh-bot-auth.sh: eigenes `gh auth setup-git` ohne ambient Token ──────
# echte Datei (Kopie) + Stub-Token-Mint ausfuehrbar machen.
BOTAUTH="$TMP/botauth"; mkdir -p "$BOTAUTH"
cp "$ROOT/scripts/gh-bot-auth.sh" "$BOTAUTH/gh-bot-auth.sh"
cat > "$BOTAUTH/generate-github-token.sh" <<'STUB'
#!/bin/sh
printf 'fake-installation-token\n'
STUB
chmod +x "$BOTAUTH/gh-bot-auth.sh" "$BOTAUTH/generate-github-token.sh"
HOME_A="$TMP/homeA"; mkdir -p "$HOME_A/.config/gh-bots"
cat > "$HOME_A/.config/gh-bots/momo-clanker.env" <<'ENV'
GH_APP_ID=1
GH_APP_INSTALLATION_ID=2
GH_APP_PRIVATE_KEY_FILE=/nonexistent/fake.pem
ENV
: > "$TMP/t10.log"
set +e
GH_LOG="$TMP/t10.log" HOME="$HOME_A" PATH="$FAKEBIN:$PATH" \
  GH_TOKEN="ambient-pat" GITHUB_TOKEN="ambient-github" GH_ENTERPRISE_TOKEN="ambient-ent" \
  bash "$BOTAUTH/gh-bot-auth.sh" --app momo-clanker >"$TMP/out" 2>"$TMP/err"
RC=$?
set -e
LOG="$TMP/t10.log"
if [ "$RC" = 0 ] && has 'ARGS=[auth setup-git --hostname github.com]' && has 'TOKEN=[<unset>]'; then
    ok "gh-bot-auth.sh: setup-git laeuft ohne ambient GH_TOKEN"
else
    notok "gh-bot-auth.sh: setup-git ohne ambient GH_TOKEN (rc=$RC, log=$(cat "$LOG"), err=$(cat "$TMP/err"))"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
printf '\n# %d/%d Tests gruen\n' "$PASS" "$((PASS+FAIL))"
[ "$FAIL" = 0 ] || exit 1
