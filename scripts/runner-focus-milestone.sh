#!/bin/bash
# runner-focus-milestone.sh — Fokus-Milestone für die Runner (A/B) bestimmen.
# Repo-Bindung kommt aus dem Runner-Profil (`RUNNER_PROFILE`, Default: rift).
#
# ── Regel (Run-ahead) ────────────────────────────────────────────────────────
#   Fokus = der FREIGEGEBENE offene Milestone (bei mehreren: kleinste Nummer), der
#     1. FREIGEGEBEN ist — der Milestone-Text enthält eine Zeile `Freigabe: ja`
#        (Default, per RIFT_FOCUS_APPROVE_RE übersteuerbar), und
#     2. noch ARBEIT hat bzw. ein (Re-)Release braucht.
#
#   Nur Milestones mit Freigabe sind vorarbeitbar; die Roadmap wird inkrementell
#   geplant (Zeile in den Milestone-Text = Freigabe). Ein optionaler Include-Filter
#   `RUNNER_FOCUS_PATTERN` (Regex auf den Titel) schränkt die Kandidaten ein.
#
#   Run-ahead: Ein Milestone, dessen Release-PR offen/gemergt ist, wird ÜBERSPRUNGEN
#   — der Fokus rückt auf den nächsten freigegebenen Milestone, statt auf den
#   Menschen zu warten. Ausnahmen (dann bleibt/kommt er als Fokus):
#     • er hat noch OFFENE LEAF-Issues (z. B. ein Player-Test-Fix kam zurück) → Arbeit,
#     • ein offenes Issue hat einen OFFENEN, UNGEMERGTEN PR (auch `claimed`/`hold`/
#       `question`) → der Milestone ist NICHT code-complete; kein Run-ahead. Grund:
#       `claimed` heißt „nicht dispatchbar", NICHT „fertig" — ohne diese Regel lief der
#       Fokus vor ungemergten Leaf-PRs weg (real: 1.0.4 mit offenen #944/#945 → 1.0.6),
#     • sein offener Release-PR ist VERALTET (seit dem letzten Release-Commit wurde
#       ein Issue im Milestone geschlossen) → der Tick zieht den Release-PR nach.
#   Ein nur GESCHLOSSENER (nicht gemergter) Release-PR blockiert NICHT (Rebuild).
#
#   Sortierung nach Milestone-Nummer (Erstellungsreihenfolge).
#
# ── Ausgabe ─────────────────────────────────────────────────────────────────
#   (default)  <title>                                    z. B. 1.0.4
#   --json     {"title":"1.0.4","number":15,"open_issues":3,"closed_issues":0,"description":"…"}
#              (description = Milestone-Text; der Runner liest daraus die
#               Dispatch-Reihenfolge als Checkliste `- [ ] #NNN`)
#   --list     alle offenen Versions-Milestones aufsteigend, je Zeile:
#              <title> number=<n> open_issues=<n> approved=<0|1> release_pr=<none|open|merged|closed>
#   --dry-run  wie default (das Script mutiert nie — es liest nur)
#
# Exit: 0 = Fokus gefunden · 2 = Usage · 3 = API-/JSON-Fehler · 4 = kein Kandidat
#
# Nutzung (Gateway, Runtime-User; `clanker-gh` = Bot-Identity momo-clanker[bot]):
#   runner-focus-milestone.sh
#   runner-focus-milestone.sh --json
#   runner-focus-milestone.sh --list
#   RUNNER_PROFILE=mmm runner-focus-milestone.sh --json
#
# Deployment: per Setup auf .149 installiert (wie runner-stale-dispatch.sh), damit
# die Automation es per bloßem Namen aufrufen kann.

set -euo pipefail

# Die Bot-Wrapper (clanker-gh) liegen in ~/.local/bin. In nicht-interaktiven
# Shells (cron/exec/ssh) fehlt das dort oft im PATH — selbst heilen, damit der
# Bare-Name-Aufruf aus dem Prompt zuverlaessig funktioniert.
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) PATH="$HOME/.local/bin:$PATH" ;;
esac

# Repo-Bindung + Labels aus dem Runner-Profil.
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/runner-profile.sh"

REPO="${RIFT_REPO:-$RUNNER_REPO}"
GH="${GH_BIN:-${RIFT_GH:-$RUNNER_A_GH}}"
PATTERN="${RIFT_FOCUS_PATTERN:-${RUNNER_FOCUS_PATTERN:-}}"
RELEASE_LABEL="$RUNNER_RELEASE_LABEL"
# Freigabe-Marker im Milestone-Text (eine eigene Zeile, case-insensitiv).
# Bewusst inline-Flags `(?im)` — jq's `m`-Flag macht `$` nicht zum Zeilenende.
APPROVE_RE="${RIFT_FOCUS_APPROVE_RE:-$RUNNER_APPROVE_RE}"
# Hold-Labels als jq-Array: „nicht dispatchbar" (Leaf-Gate).
HOLD_JSON="$(printf '%s' "$RUNNER_HOLD_LABELS" | jq -R 'split(" ") | map(select(length > 0))')"
MODE="title"
LIST=0

usage() {
  sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --json) MODE="json" ;;
    --list) LIST=1 ;;
    --dry-run) : ;;                       # das Script mutiert nie
    -h|--help) usage; exit 0 ;;
    *) echo "runner-focus-milestone: unbekanntes Argument: $1" >&2; exit 2 ;;
  esac
  shift
done

raw="$("$GH" api "repos/$REPO/milestones?state=open&per_page=100" 2>/dev/null)" || {
  echo "runner-focus-milestone: gh api repos/$REPO/milestones fehlgeschlagen" >&2
  exit 3
}

json="$(printf '%s' "$raw" | jq -c '[.[] | {title, number, open_issues, closed_issues, description}]' 2>/dev/null)" || {
  echo "runner-focus-milestone: unerwartete API-Antwort (kein JSON-Array)" >&2
  exit 3
}

# Release-PRs (alle Zustände): `release/<titel>` sagt, ob ein Milestone schon
# einen Release-PR hat.
prs="$("$GH" pr list --repo "$REPO" --state all --limit 300 --json number,headRefName,state,labels,title,body 2>/dev/null)" \
  || prs='[]'
relmap="$(printf '%s' "$prs" | jq -c --arg rel "$RELEASE_LABEL" '
  [ .[] | select(any(.labels[]?; .name == $rel))
        | select((.headRefName // "") | startswith("release/"))
        | { branch: .headRefName, state: (.state // "") } ]
  | group_by(.branch)
  | map({ key: .[0].branch,
          value: ( if (map(select(.state == "OPEN")) | length) > 0 then "open"
                   elif (map(select(.state == "MERGED")) | length) > 0 then "merged"
                   else "closed" end ) })
  | from_entries' 2>/dev/null)" || relmap='{}'
[ -n "$relmap" ] || relmap='{}'
prsonly="$(printf '%s' "$prs" | jq -c --arg rel "$RELEASE_LABEL" '
  [ .[] | select(.state == "OPEN") | select(any(.labels[]?; .name == $rel))
        | { number, headRefName } ]' 2>/dev/null)" || prsonly='[]'
[ -n "$prsonly" ] || prsonly='[]'
# Offene Arbeits-PRs (KEIN Release-Marker) — Grundlage der Run-ahead-Sperre unten.
openprs="$(printf '%s' "$prs" | jq -c --arg rel "$RELEASE_LABEL" '
  [ .[] | select(.state == "OPEN")
        | select((([.labels[]?.name] | index($rel)) == null))
        | { number, title, headRefName, body } ]' 2>/dev/null)" || openprs='[]'
[ -n "$openprs" ] || openprs='[]'

# Kandidaten: alle offenen Milestones (optional per Include-Filter eingeschränkt),
# aufsteigend nach Milestone-Nummer sortiert.
ordered="$(printf '%s' "$json" \
  | jq -r --arg pat "$PATTERN" '
      .[] | select(($pat == "") or (.title | test($pat)))
      | "\(.number)\t\(.title)"' \
  | sort -n | cut -f2-)"

if [ -z "$ordered" ]; then
  echo "runner-focus-milestone: kein offener Milestone (pattern=${PATTERN:-<alle>})" >&2
  exit 4
fi

approved_of() {  # $1 title → "1" wenn freigegeben
  printf '%s' "$json" | jq -r --arg t "$1" --arg re "$APPROVE_RE" \
    '.[] | select(.title == $t) | ((.description // "") | test($re; "i")) | if . then "1" else "0" end'
}
release_state_of() {  # $1 title → none|open|merged|closed
  printf '%s' "$relmap" | jq -r --arg b "release/$1" '.[$b] // "none"'
}
milestone_num() {  # $1 title → number
  printf '%s' "$json" | jq -r --arg t "$1" '.[] | select(.title == $t) | .number'
}
# hab_open_leaves <milestone-number> — gleiche Leaf-Definition wie im Tick.
has_open_leaves() {
  local out
  out="$("$GH" issue list --repo "$REPO" --milestone "$1" --state open --limit 100 \
        --json number,title,labels,body 2>/dev/null)" || out='[]'
  printf '%s' "$out" | jq -e --argjson hold "$HOLD_JSON" '
    [ .[]
      | select((.title | test("^\\[(Epic|Umbrella|Milestone|Release|Design)\\]"; "i")) | not)
      | select(( (.title | test("^\\[Spike\\]"; "i"))
                 and (([.labels[].name] | index("triage:research")) == null) ) | not)
      | select(([.labels[].name] | any(. as $l | $hold | index($l))) | not)
      | select(( (([.labels[].name] | index("research")) != null)
                 and (([.labels[].name] | index("triage:research")) == null) ) | not)
      | select((.body // "" | [scan("(?m)^[ \t]*- \\[ \\][ \t]*#[0-9]+")] | length) < 2)
      | .number ] | length > 0' >/dev/null 2>&1
}
# has_open_unmerged_pr <milestone-number> — hat ein OFFENES Issue im Milestone einen
# OFFENEN, ungemergten PR? Anders als `has_open_leaves` zählt das AUCH für `claimed`/
# `hold`/`question`-Issues: der Anspruch heißt „nicht dispatchbar", NICHT „fertig". Solange
# so ein PR offen ist, ist der Milestone nicht code-complete → kein Run-ahead.
has_open_unmerged_pr() {
  local out
  out="$("$GH" issue list --repo "$REPO" --milestone "$1" --state open --limit 100 \
        --json number 2>/dev/null)" || out='[]'
  printf '%s' "$openprs" | jq -e --argjson issues "$out" '
    def refs: ((.title // "") + " " + (.body // "") + " " + (.headRefName // ""))
              | [scan("#([0-9]+)")] | flatten | map(tonumber);
    [ $issues[].number ] as $focus
    | any(.[]; (refs | any(. as $n | $focus | index($n))))' >/dev/null 2>&1
}
# release_pr_is_current <title> — offener Release-PR schon auf dem aktuellen Stand?
# (letzter Release-Commit >= neuestes `closedAt` im Milestone). Fehlt eine Zahl,
# wird NICHT gesprungen (fail-open → Tick baut/aktualisiert).
release_pr_is_current() {
  local num mn pr_commit newest
  mn="$(milestone_num "$1")"; [ -n "$mn" ] || return 0
  num="$(printf '%s' "$prsonly" | jq -r --arg b "release/$1" '.[] | select(.headRefName == $b) | .number' | head -1)"
  [ -n "$num" ] || return 0
  pr_commit="$("$GH" pr view "$num" --repo "$REPO" --json commits 2>/dev/null \
              | jq -r '[.commits[].committedDate] | max // ""' 2>/dev/null)" || pr_commit=""
  newest="$("$GH" issue list --repo "$REPO" --milestone "$mn" --state closed --limit 200 \
            --json closedAt 2>/dev/null | jq -r '[.[].closedAt // empty] | max // ""' 2>/dev/null)" || newest=""
  if [ -n "$pr_commit" ] && [ -n "$newest" ] && [ "$newest" \> "$pr_commit" ]; then
    return 1
  fi
  return 0
}

if [ "$LIST" = 1 ]; then
  while IFS= read -r t; do
    printf '%s' "$json" | jq -r --arg t "$t" --argjson a "$(approved_of "$t")" --arg r "$(release_state_of "$t")" \
      '.[] | select(.title == $t) | "\(.title) number=\(.number) open_issues=\(.open_issues) approved=\($a) release_pr=\($r)"'
  done <<< "$ordered"
  exit 0
fi

focus=""
while IFS= read -r t; do
  [ -n "$t" ] || continue
  [ "$(approved_of "$t")" = "1" ] || continue
  mn="$(milestone_num "$t")"
  case "$(release_state_of "$t")" in
    merged)
      # Ausgeliefert — es sei denn, es kam neue Arbeit zurück.
      if has_open_leaves "$mn"; then focus="$t"; break; fi
      continue ;;
    open)
      if has_open_leaves "$mn"; then focus="$t"; break; fi        # neue Arbeit → dranbleiben
      if has_open_unmerged_pr "$mn"; then focus="$t"; break; fi   # ungemergter Leaf-PR → kein Run-ahead
      if ! release_pr_is_current "$t"; then focus="$t"; break; fi # PR veraltet → nachziehen
      continue ;;                                                  # wartet auf den Menschen
    *)
      focus="$t"; break ;;
  esac
done <<< "$ordered"

if [ -z "$focus" ]; then
  echo "runner-focus-milestone: kein freigegebener Milestone mit Arbeit (alle released/awaiting review)" >&2
  exit 4
fi

case "$MODE" in
  json) printf '%s' "$json" | jq -c --arg t "$focus" \
          '.[] | select(.title == $t) | {title, number, open_issues, closed_issues: (.closed_issues // 0), description: (.description // "")}' ;;
  *)    printf '%s\n' "$focus" ;;
esac
