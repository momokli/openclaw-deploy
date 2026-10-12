#!/bin/bash
# runner-profile.sh — Repo-Profil für die `runner-*.sh`-Engine. Wird GESOURCT,
# nicht ausgeführt:
#
#   RUNNER_PROFILE=mmm . "$(dirname "${BASH_SOURCE[0]}")/runner-profile.sh"
#
# Ein Runner = eine Automation-Instanz (Job, Prompt, State-Files, enable/disable)
# für genau ein Repo. Die Engine ist geteilt, das Profil bindet sie.
#
# Auflösungsreihenfolge (erste Fundstelle gewinnt):
#   1. $RUNNER_PROFILE_FILE                      (expliziter Pfad)
#   2. $RUNNER_PROFILE_DIR/<name>.conf           (explizites Verzeichnis)
#   3. $HOME/.local/bin/runner-profiles/<name>.conf  (installiert)
#   4. ${OPENCLAW_STATE_DIR}/runner-profiles/<name>.conf
#   5. <dir-der-Engine>/runner-profiles/<name>.conf
#   6. <dir-der-Engine>/../config/runners/<name>.conf  (Repo-Layout)
#
# Das Profil setzt nur Defaults (`: "${X:=…}"`), gesetzte Umgebungsvariablen
# gewinnen — Tests und operative Overrides bleiben unverändert möglich.

RUNNER_PROFILE="${RUNNER_PROFILE:-rift}"

_runner_dir="$(cd "$(dirname "${BASH_SOURCE[1]:-$0}")" 2>/dev/null && pwd)"

_runner_profile_file=""
for _runner_cand in \
  "${RUNNER_PROFILE_FILE:-}" \
  "${RUNNER_PROFILE_DIR:+$RUNNER_PROFILE_DIR/$RUNNER_PROFILE.conf}" \
  "$HOME/.local/bin/runner-profiles/$RUNNER_PROFILE.conf" \
  "${OPENCLAW_STATE_DIR:-}/runner-profiles/$RUNNER_PROFILE.conf" \
  "$_runner_dir/runner-profiles/$RUNNER_PROFILE.conf" \
  "$_runner_dir/../config/runners/$RUNNER_PROFILE.conf"
do
  if [ -n "$_runner_cand" ] && [ -f "$_runner_cand" ]; then
    _runner_profile_file="$_runner_cand"
    break
  fi
done

if [ -z "$_runner_profile_file" ]; then
  printf 'runner-profile: Profil "%s" nicht gefunden (RUNNER_PROFILE_FILE setzen?)\n' \
    "$RUNNER_PROFILE" >&2
  exit 2
fi

# shellcheck source=/dev/null
. "$_runner_profile_file"

: "${RUNNER_REPO:?runner-profile: RUNNER_REPO fehlt im Profil $RUNNER_PROFILE}"
: "${RUNNER_STATE_PREFIX:?runner-profile: RUNNER_STATE_PREFIX fehlt im Profil $RUNNER_PROFILE}"
