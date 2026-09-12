#!/bin/bash
# pr-metadata.sh — PR-/Issue-Metadaten über die REST-API ändern (ohne `read:org`).
#
# Warum: `gh pr edit` / `gh pr view` lösen im Hintergrund GraphQL ab und fordern
# `read:org` (Feld `login`, `name`, `slug`). Der Agent-Token hat nur
# `repo, workflow, write:packages` → "Your token has not been granted the required
# scopes … 'read:org'". `gh api` spricht REST und funktioniert mit diesen Scopes.
# Dieses Script kapselt die wiederkehrenden Metadaten-Operationen als Standard
# (Issue #40) → kein Ad-hoc-Raten mehr. Details: docs/github-pr-rest-edits.md
#
# Usage:
#   scripts/pr-metadata.sh -n <PR> [-R owner/repo] [OPERATION …]
#
# Operationen (kombinierbar):
#   --body-file FILE     PR-Body aus Datei setzen    (PATCH /pulls/<n>)
#   --body TEXT          PR-Body inline setzen       (PATCH /pulls/<n>)
#   --title TEXT         PR-Titel setzen             (PATCH /pulls/<n>)
#   --base BRANCH        PR-Base-Branch setzen       (PATCH /pulls/<n>)
#   --add-label LBL      Label hinzufügen (mehrfach) (POST /issues/<n>/labels)
#   --remove-label LBL   Label entfernen (mehrfach)  (DELETE /issues/<n>/labels/<lbl>)
#   --comment-file FILE  Kommentar aus Datei         (POST /issues/<n>/comments)
#   --comment TEXT       Kommentar inline
#   --show               Felder lesen (number/title/state/base/body) — Read-back
#
# Global:
#   -n, --number N       PR-/Issue-Nummer (Pflicht, >0)
#   -R, --repo O/R       Repo (Default: $GH_REPO, sonst `git remote origin`)
#   -q, --quiet          nur Fehler auf stderr
#   -h, --help           diese Nutzung
#
# Exit: 0 = OK · 2 = Usage/Argumente · 3 = gh/API-Fehler
#
# Beispiel (PR-Body standard-konform aktualisieren):
#   scripts/pr-metadata.sh -n 87 -R momokli/openclaw-deploy --body-file /tmp/body.md --show

set -euo pipefail

err() { printf 'error: %s\n' "$*" >&2; }
die() { err "$*"; exit 2; }
api_die() { err "$*"; exit 3; }
usage() { sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; }

NUM=""
REPO="${PR_METADATA_REPO:-${GH_REPO:-}}"
QUIET=0
SHOW=0
WANT_PULL=0
WANT_LABELS=0

BODY=""; HAS_BODY=0
TITLE=""; HAS_TITLE=0
BASE=""; HAS_BASE=0
COMMENT=""; HAS_COMMENT=0
ADD_LABELS=()
RM_LABELS=()

# ── Argumente parsen ────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--number)      shift; [ $# -gt 0 ] || die "fehlende Nummer nach $0"; NUM="$1" ;;
    -R|--repo)        shift; [ $# -gt 0 ] || die "fehlendes Repo nach -R"; REPO="$1" ;;
    --body-file)
      shift; [ $# -gt 0 ] || die "fehlender Pfad nach --body-file"
      [ -r "$1" ] || die "Body-Datei nicht lesbar: $1"
      BODY="$(cat "$1")"; HAS_BODY=1; WANT_PULL=1 ;;
    --body)           shift; [ $# -gt 0 ] || die "fehlender Wert nach --body"
                      BODY="$1"; HAS_BODY=1; WANT_PULL=1 ;;
    --title)          shift; [ $# -gt 0 ] || die "fehlender Wert nach --title"
                      TITLE="$1"; HAS_TITLE=1; WANT_PULL=1 ;;
    --base)           shift; [ $# -gt 0 ] || die "fehlender Wert nach --base"
                      BASE="$1"; HAS_BASE=1; WANT_PULL=1 ;;
    --add-label)      shift; [ $# -gt 0 ] || die "fehlendes Label nach --add-label"
                      ADD_LABELS+=("$1"); WANT_LABELS=1 ;;
    --remove-label)   shift; [ $# -gt 0 ] || die "fehlendes Label nach --remove-label"
                      RM_LABELS+=("$1") ;;
    --comment-file)
      shift; [ $# -gt 0 ] || die "fehlender Pfad nach --comment-file"
      [ -r "$1" ] || die "Kommentar-Datei nicht lesbar: $1"
      COMMENT="$(cat "$1")"; HAS_COMMENT=1 ;;
    --comment)        shift; [ $# -gt 0 ] || die "fehlender Wert nach --comment"
                      COMMENT="$1"; HAS_COMMENT=1 ;;
    --show)           SHOW=1 ;;
    -q|--quiet)       QUIET=1 ;;
    -h|--help)        usage; exit 0 ;;
    -*)               die "unbekannte Option: $1" ;;
    *)                die "unerwartetes Argument: $1" ;;
  esac
  shift
done

# ── Validierung ─────────────────────────────────────────────────────────
[ -n "$NUM" ] || die "PR-Nummer fehlt (-n <n>)"
case "$NUM" in ''|*[!0-9]*) die "PR-Nummer muss numerisch sein: $NUM" ;; esac
command -v gh >/dev/null 2>&1 || api_die "gh nicht gefunden (GH_TOKEN/gh-App nötig)"
command -v jq >/dev/null 2>&1 || api_die "jq nicht gefunden"

if [ -z "$REPO" ]; then
  url="$(git config --get remote.origin.url 2>/dev/null || true)"
  REPO="$(printf '%s' "$url" | sed -E 's#\.git$##; s#/+$##; s#^.*[:/]([^/:]+/[^/:]+)$#\1#')"
fi
[ -n "$REPO" ] || die "Repo nicht bestimmbar (-R owner/repo, \$GH_REPO oder git remote origin)"
case "$REPO" in */*) : ;; *) die "Repo muss 'owner/name' sein: $REPO" ;; esac

[ "$WANT_PULL" = 1 ] || [ "$WANT_LABELS" = 1 ] || [ "${#RM_LABELS[@]}" -gt 0 ] \
  || [ "$HAS_COMMENT" = 1 ] || [ "$SHOW" = 1 ] \
  || die "keine Operation angegeben (--body-file/--title/--base/--add-label/--remove-label/--comment/--show)"

note() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }

# ── PATCH /repos/O/R/pulls/<n> (body/title/base) ────────────────────────
if [ "$WANT_PULL" = 1 ]; then
  payload="$(jq -c -n \
    --arg body "$BODY"     --argjson has_body "$HAS_BODY" \
    --arg title "$TITLE"   --argjson has_title "$HAS_TITLE" \
    --arg base "$BASE"     --argjson has_base "$HAS_BASE" \
    '{}
     + (if $has_body  == 1 then {body:  $body}  else {} end)
     + (if $has_title == 1 then {title: $title} else {} end)
     + (if $has_base  == 1 then {base:  $base}  else {} end)')"
  printf '%s' "$payload" | gh api -X PATCH "repos/$REPO/pulls/$NUM" --input - >/dev/null \
    || api_die "REST PATCH /pulls/$NUM fehlgeschlagen"
  fields="$(printf '%s' "$payload" | jq -r 'keys_unsorted | join(",")')"
  note "ok: PR #$NUM gepatcht ($fields) via REST"
fi

# ── POST /repos/O/R/issues/<n>/labels ───────────────────────────────────
if [ "${#ADD_LABELS[@]}" -gt 0 ]; then
  labels_json="$(printf '%s\n' "${ADD_LABELS[@]}" | jq -R . | jq -cs .)"
  printf '%s' "$(jq -c -n --argjson labels "$labels_json" '{labels: $labels}')" \
    | gh api -X POST "repos/$REPO/issues/$NUM/labels" --input - >/dev/null \
    || api_die "REST POST /issues/$NUM/labels fehlgeschlagen"
  note "ok: Label(s) hinzugefügt: ${ADD_LABELS[*]}"
fi

# ── DELETE /repos/O/R/issues/<n>/labels/<lbl> ───────────────────────────
for lbl in "${RM_LABELS[@]:-}"; do
  [ -n "$lbl" ] || continue
  enc="$(jq -rn --arg s "$lbl" '$s|@uri')"
  gh api -X DELETE "repos/$REPO/issues/$NUM/labels/$enc" >/dev/null \
    || api_die "REST DELETE /issues/$NUM/labels/$lbl fehlgeschlagen"
  note "ok: Label entfernt: $lbl"
done

# ── POST /repos/O/R/issues/<n>/comments ─────────────────────────────────
if [ "$HAS_COMMENT" = 1 ]; then
  printf '%s' "$COMMENT" | jq -Rsc '{body: .}' \
    | gh api -X POST "repos/$REPO/issues/$NUM/comments" --input - >/dev/null \
    || api_die "REST POST /issues/$NUM/comments fehlgeschlagen"
  note "ok: Kommentar zu #$NUM gepostet"
fi

# ── GET /repos/O/R/pulls/<n> (Read-back) ────────────────────────────────
if [ "$SHOW" = 1 ]; then
  gh api "repos/$REPO/pulls/$NUM" \
    -q '"number: \(.number)\ntitle: \(.title)\nstate: \(.state)\nbase: \(.base.ref)\nbody: \(.body)"' \
    || api_die "REST GET /pulls/$NUM fehlgeschlagen"
fi
