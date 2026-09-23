#!/bin/bash
# rift-stale-dispatch.sh — Stale-Dispatch-Reconciliation für `rift-triage` (Runner A).
#
# Problem: Runner A skippt jedes Issue mit Label `orchestrator:dispatched` (Dedup gegen
# Doppel-Dispatch). Stirbt der Worker nach dem Dispatch auf Model-/Turn-Ebene (OpenClaw
# wertet den Lauf z. B. als `non_deliverable_terminal_turn` ab → Session-Status `failed`),
# bleibt das Label kleben: die Triage sieht das Issue nie wieder → kein PR, kein Retry.
# Das Issue ist gelockt.
#
# Dieses Script läuft VOR der Klassifikation und gibt genau solche Issues wieder frei
# (`orchestrator:dispatched` entfernen) → der normale Triage-Pfad (Prio-Reihenfolge,
# max. 3 Dispatches/Lauf, Dedup via `orchestrator:dispatched`) übernimmt sie im selben
# Lauf. Die bestehende Loop-Protection wird NICHT umgangen, nur wieder erreichbar gemacht.
#
# ── Stale-Definition (S1–S5) ─────────────────────────────────────────────────
#   S1  offenes Issue mit Label `orchestrator:dispatched` (default: alle offenen Issues;
#       mit `-m <title>` auf einen Milestone beschränkt)
#   S2  letztes Dispatch-Label ≥ --grace-min alt   (jüngere Dispatches sind „unterwegs")
#   S3  KEIN verlinkter offener PR                 (Branch/Body-Konvention + Timeline-Cross-Ref)
#   S4  KEINE Aktivität auf dem Issue seit dem Dispatch (Kommentar / Cross-Reference /
#       Commit-Referenz; eigene Marker-Kommentare zählen nicht) — Fallback, falls das
#       Worker-Label die Issue-Nummer nicht trägt
#   S5  KEIN gesunder Worker-Run seit dem Dispatch (`openclaw sessions list`, Label mit
#       Issue-Nummer): `done` ⇒ gesund; `running` nur wenn Aktivität < --running-ttl-min
#       (Zombie-Records nach Crash/Restart bleiben sonst ewig auf `running`); `failed`/
#       `killed`/kein Run ⇒ NICHT gesund
#
#   stale ⇔ S1 ∧ S2 ∧ ¬S3 ∧ ¬S4 ∧ ¬S5  → Dispatch-Label wird entfernt (Retry)
#
#   Ausnahme zu ¬S3 („verlinkter offener PR"): ist der verlinkte PR **rot gelaufen**
#   (`mergeStateStatus=BLOCKED` — ein Required-Check ist fehlgeschlagen) und läuft dort kein
#   Worker mehr, dann hat der Dispatch nichts hervorgebracht, das weiterläuft. Der Kandidat
#   geht dann in den normalen Stale-Pfad (Retry mit Marker/Cap statt Parken). Ohne diese
#   Ausnahme bleibt der WIP=1-Slot für immer belegt — real hat PR #905 mit rotem `boot-test`
#   den kompletten 1.0.1-Fokus eingefroren.
#
#   Ein **Release-PR** (`release:human-merge`: Changelog + Abnahme + Testplan) ist dagegen
#   überhaupt kein Worker-PR und wird hier gar nicht betrachtet — er wartet auf den Menschen
#   und darf einen Retry (z. B. nach fehlgeschlagenem Player-Test) nicht blockieren.
#
# ── Loop-Bremse (Hard Cap gegen Retry-Schleifen) ─────────────────────────────
#   G1  je Freigabe ein Marker-Kommentar `rift-triage:redispatch attempt=k` (Audit + Zähler)
#   G2  attempts ≥ --max-attempts ⇒ KEINE Freigabe mehr, nur `NOTE <n> escalate` (Mensch nötig)
#   G3  letzte Freigabe jünger als --cooldown-min ⇒ skip (der letzte Retry läuft evtl. noch)
#   G4  max. --max-per-run Freigaben pro Lauf (Rest im nächsten Lauf, Takt 5 min)
#
# Ausgabe (stdout, eine Zeile pro Kandidat + Summary):
#   REDISPATCH <n> attempts=<k> dispatch_age=<min>min   Label entfernt → neu dispatchbar
#   SKIP <n> <dispatch-fresh|linked-pr-open|activity-since-dispatch|worker-done|
#             worker-running|cooldown|cap-per-run|no-dispatch-event>
#   RED-BLOCKED <n> …                                   PR offen, aber Required-Check rot → Retry-Pfad
#   NOTE <n> escalate attempts=<k>                      Cap erreicht → Mensch
#   summary issues=<n> stale=<n> redispatched=<n> capped=<n> skipped=<n> scope=all|milestone:<m>
# `--dry-run` fällt nur die Entscheidungen, ändert NICHTS am Repo.
#
# Exit: 0 = OK (auch wenn nichts stale ist) · 2 = Usage/Argumente · 3 = API/Session-Fehler
#
# Nutzung (Gateway, Runtime-User; `clanker-gh` = Bot-Identity momo-clanker[bot]):
#   rift-stale-dispatch.sh --dry-run            # default: alle offenen dispatched-Issues
#   rift-stale-dispatch.sh
#   rift-stale-dispatch.sh -m 1.0 --dry-run      # optional: nur dieser Milestone
#
# Deployment: per Code/Setup auf .149 installiert (wie die Bot-Wrapper),
# Bot-Wrapper), damit die Automation es per bloßem Namen aufrufen kann.

set -euo pipefail

REPO="${RIFT_REPO:-momokli/riftbreaker-battle-mod}"
MILESTONE="${RIFT_MILESTONE:-}"
DRY_RUN=0
QUIET=0

# Schwellen (per Flag/Env justierbar, damit Tests/Alarme ohne Code-Edit möglich sind).
GRACE_MIN="${RIFT_REDISPATCH_GRACE_MIN:-20}"          # S2
RUNNING_TTL_MIN="${RIFT_REDISPATCH_RUNNING_TTL_MIN:-60}" # S5 (Zombie-Schutz)
COOLDOWN_MIN="${RIFT_REDISPATCH_COOLDOWN_MIN:-30}"     # G3
MAX_ATTEMPTS="${RIFT_REDISPATCH_MAX_ATTEMPTS:-3}"      # G2
MAX_PER_RUN="${RIFT_REDISPATCH_MAX_PER_RUN:-2}"        # G4

DISPATCH_LABEL="orchestrator:dispatched"
REDISPATCH_LABEL="triage:redispatch"
# Am Hard Cap wird das Issue nicht weiter freigegeben, sondern für den Menschen geparkt:
# Label weg + dieses Label drauf. `question` ist ein Default-Label und gibt den WIP=1-Slot frei.
BLOCKED_LABEL="${RIFT_BLOCKED_LABEL:-question}"
MARKER="rift-triage:redispatch"

GH="${GH_BIN:-clanker-gh}"                       # Bot-Identity Runner A
OPENCLAW_BIN="${OPENCLAW_BIN:-openclaw}"
WORKER_AGENTS="${RIFT_WORKER_AGENTS:-coding-orchestrator planning-orchestrator}"

err() { printf 'error: %s\n' "$*" >&2; }
die() { err "$*"; exit 2; }
api_die() { err "$*"; exit 3; }
note() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
usage() { awk 'NR >= 2 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; }

# iso_to_epoch <ISO-8601-UTC> → Epoch-Sekunden (GNU date, sonst BSD/macOS-Fallback).
iso_to_epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s
}

# ── Argumente ──────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    -R|--repo)        opt="$1"; shift; [ $# -gt 0 ] || die "fehlender Wert nach $opt"; REPO="$1" ;;
    -m|--milestone)   opt="$1"; shift; [ $# -gt 0 ] || die "fehlender Wert nach $opt"; MILESTONE="$1" ;;
    --grace-min)      opt="$1"; shift; [ $# -gt 0 ] || die "fehlender Wert nach $opt"; GRACE_MIN="$1" ;;
    --running-ttl-min) opt="$1"; shift; [ $# -gt 0 ] || die "fehlender Wert nach $opt"; RUNNING_TTL_MIN="$1" ;;
    --cooldown-min)   opt="$1"; shift; [ $# -gt 0 ] || die "fehlender Wert nach $opt"; COOLDOWN_MIN="$1" ;;
    --max-attempts)   opt="$1"; shift; [ $# -gt 0 ] || die "fehlender Wert nach $opt"; MAX_ATTEMPTS="$1" ;;
    --max-per-run)    opt="$1"; shift; [ $# -gt 0 ] || die "fehlender Wert nach $opt"; MAX_PER_RUN="$1" ;;
    --dry-run)        DRY_RUN=1 ;;
    -q|--quiet)       QUIET=1 ;;
    -h|--help)        usage; exit 0 ;;
    *)                die "unbekannte Option: $1" ;;
  esac
  shift
done

case "$REPO" in */*) : ;; *) die "Repo muss 'owner/name' sein: $REPO" ;; esac
for v in "$GRACE_MIN" "$RUNNING_TTL_MIN" "$COOLDOWN_MIN" "$MAX_ATTEMPTS" "$MAX_PER_RUN"; do
  case "$v" in ''|*[!0-9]*) die "numerischer Wert erwartet: $v" ;; esac
done
command -v "$GH" >/dev/null 2>&1 || api_die "$GH nicht gefunden (PATH/gh-App-Auth)"
command -v jq >/dev/null 2>&1 || api_die "jq nicht gefunden"

NOW="$(date -u +%s)"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DRY_TAG=""; [ "$DRY_RUN" = 1 ] && DRY_TAG=" dry-run=1"

# ── Scope + Kandidaten ─────────────────────────────────────────────────────
# Default: ALLE offenen Issues mit Dispatch-Label. `-m <title>` schränkt auf einen
# offenen Milestone ein (Backwards-Kompatibilität/Tests).
if [ -n "$MILESTONE" ]; then
  MS_NUM="$("$GH" api "repos/$REPO/milestones?state=open&per_page=100" \
    | jq -r --arg t "$MILESTONE" '[.[] | select(.title == $t) | .number] | first // empty')" \
    || api_die "Milestones lesen fehlgeschlagen ($REPO)"
  [ -n "$MS_NUM" ] || die "offener Milestone '$MILESTONE' nicht gefunden in $REPO"
  SCOPE="milestone:$MILESTONE"
  ISSUES_JSON="$("$GH" issue list --repo "$REPO" --state open --milestone "$MS_NUM" \
    --limit 200 --json number,title,labels,url)" || api_die "Issue-Liste lesen fehlgeschlagen"
else
  SCOPE="all"
  ISSUES_JSON="$("$GH" issue list --repo "$REPO" --state open \
    --limit 200 --json number,title,labels,url)" || api_die "Issue-Liste lesen fehlgeschlagen"
fi

# Nur Issues mit Dispatch-Label sind Kandidaten — alles andere macht die Triage normal (S1).
CANDIDATES="$(printf '%s' "$ISSUES_JSON" \
  | jq -r --arg l "$DISPATCH_LABEL" '.[] | select(any(.labels[]?; .name == $l)) | .number')"

# ── Verlinkte OFFENE PRs (S3, einmal für alle Kandidaten) ───────────────────
# Konvention wie in den Runner-Prompts: Branch-Name enthält die Issue-Nummer
# (`feature/401-…`) und/oder der Body nennt sie schließend (`Fixes #401`).
# `mergeStateStatus` wird mitgeholt: nur damit lässt sich ein rot gelaufener PR
# (Required-Check `BLOCKED`) von einem „arbeitet noch daran" unterscheiden. `labels`
# brauchen wir, um den Release-PR (`release:human-merge`) auszusortieren.
PRS_JSON="$("$GH" pr list --repo "$REPO" --state open --limit 200 \
  --json number,headRefName,body,mergeStateStatus,labels)" \
  || api_die "PR-Liste lesen fehlgeschlagen"

# Eine Liste {num,state,refs}: `headRefName`/`body` werden zu je einer Liste von
# Issue-Nummern gescannt — Branch-Konvention `feature/401-…` bzw. schließende Keywords
# `Fixes #401`. Der Scan lebt genau EINMAL hier, damit `has_linked_pr` und
# `red_blocked_pr` nicht auseinanderdriften können.
PR_INFO="$(printf '%s' "$PRS_JSON" | jq -c '
  [ .[] | select((([.labels[]?.name] | index("release:human-merge")) == null))
        | { num: .number, state: (.mergeStateStatus // ""),
            refs: ( ((.headRefName // "") | [scan("(?:^|[/_-])([0-9]+)(?=[/_-]|$)")] | map(.[0] | tonumber))
                  + ((.body // "")
                     | [scan("(?i)\\b(?:fix(?:e[sd])?|close[sd]?|resolve[sd]?|relate[sd]?|part of|addresses)\\b[ \\t]*:?[ \\t]*#([0-9]+)")]
                     | map(.[0] | tonumber)) ) } ]')" \
  || api_die "PR-Links parsen fehlgeschlagen"

has_linked_pr() { printf '%s' "$PR_INFO" | jq -e --argjson n "$1" \
  'any(.[]; (.refs | index($n)) != null)' >/dev/null 2>&1; }

# Rot gelaufener Required-Check: der PR ist offen, aber das Ergebnis ist unbrauchbar.
red_blocked_pr() { printf '%s' "$PR_INFO" | jq -e --argjson n "$1" \
  'any(.[]; ((.refs | index($n)) != null) and (.state == "BLOCKED"))' >/dev/null 2>&1; }

# ── Worker-Runs (Sessions beider Orchestratoren) ────────────────────────────
# `status` ist OpenClaws Lauf-Bewertung: `done` = deliverable, `failed` = u. a.
# `non_deliverable_terminal_turn` (die Lock-Ursache), `killed` = abgebrochen,
# `running` = (in dieser Installation praktisch nur noch) Zombie-Record.
SESSIONS_JSONL=""
for agent in $WORKER_AGENTS; do
  raw="$("$OPENCLAW_BIN" sessions list --agent "$agent" --json --limit all 2>/dev/null)" \
    || api_die "openclaw sessions list --agent $agent fehlgeschlagen"
  printf '%s' "$raw" | jq -e 'has("sessions")' >/dev/null 2>&1 \
    || api_die "unerwartete sessions-Ausgabe für Agent $agent"
  SESSIONS_JSONL="$SESSIONS_JSONL$(
    printf '%s' "$raw" | jq -c --arg a "$agent" \
      '.sessions[] | {agent: $a, label: (.label // ""), status: (.status // ""), updatedAt: (.updatedAt // 0)}'
  )
"
done

# worker_state <issue> <dispatch_epoch> → running|success|stale
# Der jüngste Session-Run, dessen Label die Issue-Nummer als Token trägt, entscheidet.
# Ein `done` vor dem Dispatch zählt NICHT (gehört zu einem älteren Versuch).
worker_state() {
  local n="$1" dispatch_ep="$2" newest status age
  newest="$(printf '%s' "$SESSIONS_JSONL" | jq -cs --argjson n "$n" '
    [ .[] | select(.label | test("(^|[^0-9])" + ($n | tostring) + "([^0-9]|$)")) ]
    | sort_by(.updatedAt) | last // empty')"
  if [ -z "$newest" ] || [ "$newest" = "null" ]; then echo "stale"; return 0; fi
  status="$(printf '%s' "$newest" | jq -r '.status')"
  age=$(( $(printf '%s' "$newest" | jq -r '.updatedAt') / 1000 ))
  if [ "$status" = "done" ] && [ "$age" -ge "$dispatch_ep" ]; then echo "success"; return 0; fi
  if [ "$status" = "running" ] && [ $(( (NOW - age) / 60 )) -lt "$RUNNING_TTL_MIN" ]; then
    echo "running"; return 0
  fi
  echo "stale"
}

# ── Marker-Kommentar (Zähler + Audit) ──────────────────────────────────────
# Der Zähler lebt bewusst in den Kommentaren, nicht im Label: ein erneutes
# `--add-label` desselben Labels ist ein API-No-op und erzeugt KEIN neues Event —
# ein Label-basierter Zähler bliebe also dauerhaft bei 1 stehen.
marker_body() {  # $1 issue, $2 attempt, $3 dispatch_iso, $4 age_min
  cat <<EOF
<!-- $MARKER attempt=$2 dispatch=$3 at=$NOW_ISO -->
**Stale Dispatch erkannt — für Retry freigegeben (Versuch $2/$MAX_ATTEMPTS).**

Der Dispatch vom \`$3\` (\`$DISPATCH_LABEL\`, Alter $4 min) hat nichts hervorgebracht:
kein verlinkter offener PR, kein Outcome (\`triage:no-action\`/gemergter PR), keine
menschliche Aktivität auf dem Issue und kein laufender Worker seit dem Dispatch.
Deshalb wurde \`$DISPATCH_LABEL\` entfernt und \`$REDISPATCH_LABEL\`
gesetzt, damit die Triage das Issue normal neu klassifiziert und erneut dispatcht.

Bei $MAX_ATTEMPTS Fehlversuchen wird nicht mehr automatisch freigegeben (dann ist ein Mensch nötig).
EOF
}

ensure_redispatch_label() {
  local labels
  labels="$("$GH" label list --repo "$REPO" --limit 200 --json name | jq -c '[.[].name]')" \
    || api_die "Label-Liste lesen fehlgeschlagen"
  printf '%s' "$labels" | jq -e --arg n "$REDISPATCH_LABEL" 'index($n) != null' >/dev/null 2>&1 && return 0
  if [ "$DRY_RUN" = 1 ]; then note "label create $REDISPATCH_LABEL (dry-run)"; return 0; fi
  jq -cn --arg n "$REDISPATCH_LABEL" \
    '{name: $n, color: "fbca04", description: "Stale Dispatch automatisch freigegeben (Triage-Retry, Audit)"}' \
    | "$GH" api -X POST "repos/$REPO/labels" --input - >/dev/null \
    || api_die "Label '$REDISPATCH_LABEL' anlegen fehlgeschlagen"
}

# park_issue <n> <grund> — Issue für den Menschen parken: Dispatch-Label weg + $BLOCKED_LABEL
# drauf. Gibt den WIP=1-Slot frei, ohne einen Retry-Loop zu starten (die Arbeit ist bereits
# gelaufen bzw. der Cap ist erreicht). Genau das fehlte in der #895-Klasse: das Label blieb
# stehen und blockierte den ganzen Fokus-Milestone.
park_issue() {
  local n="$1" reason="$2" enc
  enc="$(jq -rn --arg s "$DISPATCH_LABEL" '$s | @uri')"
  if "$GH" api -X DELETE "repos/$REPO/issues/$n/labels/$enc" >/dev/null 2>&1; then
    jq -cn --arg l "$BLOCKED_LABEL" '{labels: [$l]}' \
      | "$GH" api -X POST "repos/$REPO/issues/$n/labels" --input - >/dev/null 2>&1 \
      || err "Label $BLOCKED_LABEL auf #$n setzen fehlgeschlagen"
    note "BLOCKED $n $reason (Label weg + $BLOCKED_LABEL — Mensch entscheidet)"
  else
    err "Label $DISPATCH_LABEL von #$n entfernen fehlgeschlagen"
    note "NOTE $n $reason (Parken fehlgeschlagen)"
  fi
}

# ── Reconciliation ─────────────────────────────────────────────────────────
issues=0 stale=0 redispatched=0 capped=0 skipped=0

for n in $CANDIDATES; do
  issues=$((issues + 1))
  tl="$("$GH" api "repos/$REPO/issues/$n/timeline?per_page=100")" \
    || api_die "Timeline von #$n lesen fehlgeschlagen"

  # S2: Zeitpunkt des letzten Dispatch-Labels. Die Timeline ist die einzige verlässliche
  # Quelle — `updatedAt` des Issues ändert sich bei jedem Kommentar.
  dispatch_iso="$(printf '%s' "$tl" | jq -r --arg l "$DISPATCH_LABEL" \
    '[.[] | select(.event == "labeled") | select(.label.name == $l) | .created_at] | last // ""')"
  if [ -z "$dispatch_iso" ]; then
    note "SKIP $n no-dispatch-event"; skipped=$((skipped + 1)); continue
  fi
  dispatch_ep="$(iso_to_epoch "$dispatch_iso")" || api_die "Datum '$dispatch_iso' nicht parsebar"
  age_min=$(( (NOW - dispatch_ep) / 60 ))
  if [ "$age_min" -lt "$GRACE_MIN" ]; then
    note "SKIP $n dispatch-fresh"; skipped=$((skipped + 1)); continue
  fi

  # S3: offener PR verlinkt (Konvention ODER Timeline-Cross-Reference)?
  xref_open="$(printf '%s' "$tl" | jq -r '
    [ .[] | select(.event == "cross-referenced")
          | select(.source.issue.pull_request != null)
          | select(.source.issue.state == "open")
          | .source.issue.number ] | length')"
  if has_linked_pr "$n" || [ "$xref_open" -gt 0 ]; then
    # Ausnahme (siehe Header): rot gelaufener PR ohne laufenden Worker ⇒ Retry-Pfad.
    if red_blocked_pr "$n" && [ "$(worker_state "$n" "$dispatch_ep")" != "running" ]; then
      note "RED-BLOCKED $n (PR offen, Required-Check rot) → Retry-Pfad"
    else
      note "SKIP $n linked-pr-open"; skipped=$((skipped + 1)); continue
    fi
  fi

  # S3b: Outcome vorhanden → nicht mehr unsere Baustelle (das Cleanup schließt).
  #   - `triage:no-action`: der Worker hat belegt, dass es nichts zu bauen gibt.
  #   - gemergter PR verlinkt: erledigt.
  # Ohne diesen Schk würde ein fertiger-nichts-bauender Worker ewig als „stale"
  # gelten und der Slot bliebe belegt (real: #895).
  if printf '%s' "$ISSUES_JSON" | jq -e --argjson n "$n" \
       '.[] | select(.number == $n) | any(.labels[]?; .name == "triage:no-action")' >/dev/null 2>&1; then
    note "SKIP $n no-action-label (Cleanup schließt)"; skipped=$((skipped + 1)); continue
  fi
  merged_ref="$(printf '%s' "$tl" | jq -r '
    [ .[] | select(.event == "cross-referenced")
          | select(.source.issue.pull_request != null)
          | select(.source.issue.pull_request.merged_at != null) ] | length')"
  if [ "${merged_ref:-0}" -gt 0 ]; then
    note "SKIP $n merged-pr (Cleanup schließt)"; skipped=$((skipped + 1)); continue
  fi

  # S4: Aktivität seit dem Dispatch (Commit-/PR-Referenz oder MENSCHLICHER Kommentar).
  # Bot-Kommentare zählen ausdrücklich NICHT: ein Worker, der einen Befund oder eine
  # Zwischenmeldung schreibt, hat nichts geliefert — sonst hält er sich selbst den Slot
  # offen (#895). Eigene Marker-Kommentare zählen ebenfalls nicht (sonst würde sich der
  # Guard selbst ruhigstellen); die Retry-Kadenz regeln Cooldown + Hard Cap.
  activity="$(printf '%s' "$tl" | jq -r --argjson t "$dispatch_ep" --arg m "$MARKER" '
    [ .[] | select(.event == "referenced" or .event == "cross-referenced"
                   or (.event == "commented"
                       and ((.user.type // "") != "Bot")
                       and (((.body // "") | test($m)) | not)))
          | select((.created_at | fromdateiso8601) > $t) ] | length')"
  if [ "$activity" -gt 0 ]; then
    note "SKIP $n activity-since-dispatch"; skipped=$((skipped + 1)); continue
  fi

  # S5: Worker-Run seit dem Dispatch.
  # `running` = Worker arbeitet → Finger weg.
  # `success` (Session `done`) ist nur mit Outcome gesund (Outcome-Fälle hat S3b oben
  # entfernt) oder bei einem Research-/Spike-Dispatch (Bericht statt PR). Alles andere ist
  # „fertig, aber nichts hervorgebracht" — das wird **geparkt** (Label weg + `question`),
  # nicht erneut dispatcht (die Arbeit ist gelaufen) und nicht liegen gelassen (#895).
  case "$(worker_state "$n" "$dispatch_ep")" in
    running) note "SKIP $n worker-running"; skipped=$((skipped + 1)); continue ;;
    success)
      # Rot gelaufener PR: die Session ist zwar fertig, aber das Ergebnis ist unbrauchbar —
      # das ist ein Retry-Fall (der Worker kann den PR reparieren), kein Park-Fall.
      # Kein Sonderweg fuer Research/Spikes: auch dort ist "fertig ohne Outcome" ein
      # Zustand ohne Ausgang (die Spike-Issue bleibt offen, das Plan-Issue ist woanders).
      # Der Worker signalisiert den Abschluss per `triage:no-action` (dann greift S3b).
      if red_blocked_pr "$n"; then
        note "RED-BLOCKED $n (Session done, PR rot) → Retry statt parken"
      else
        if [ "$DRY_RUN" = 1 ]; then
          note "BLOCKED $n worker-done-ohne-outcome (dry-run: Label weg + $BLOCKED_LABEL)"
        else
          park_issue "$n" "worker-done-ohne-outcome"
        fi
        capped=$((capped + 1)); continue
      fi ;;
  esac

  stale=$((stale + 1))

  # G1/G2: Versuchszähler + Hard Cap.
  stats="$(printf '%s' "$tl" | jq -c '
    [ .[] | select(.event == "commented")
          | select((.body // "") | test("rift-triage:redispatch attempt="))
          | { a: ((.body | capture("rift-triage:redispatch attempt=(?<k>[0-9]+)").k) | tonumber),
              at: .created_at } ]
    | { attempts: ([.[].a] | max // 0), last_at: ([.[].at] | sort | last // "") }')"
  attempts="$(printf '%s' "$stats" | jq -r '.attempts')"
  last_at="$(printf '%s' "$stats" | jq -r '.last_at')"

  if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
    # Hard Cap: nicht weiter freigeben (kein Retry-Loop) — aber auch NICHT stehen lassen.
    # Label weg + `question` setzen: der Slot ist frei und ein Mensch entscheidet.
    # (Das frühere `NOTE escalate` bei stehenbleibendem Label war selbst ein Deadlock — #895.)
    if [ "$DRY_RUN" = 1 ]; then
      note "NOTE $n escalate attempts=$attempts (dry-run: Label weg + $BLOCKED_LABEL)"
      capped=$((capped + 1)); continue
    fi
    park_issue "$n" "cap-erreicht attempts=$attempts"
    capped=$((capped + 1)); continue
  fi

  # G3: Cooldown seit der letzten Freigabe.
  if [ -n "$last_at" ]; then
    last_ep="$(iso_to_epoch "$last_at")" || api_die "Datum '$last_at' nicht parsebar"
    if [ $(( (NOW - last_ep) / 60 )) -lt "$COOLDOWN_MIN" ]; then
      note "SKIP $n cooldown"; skipped=$((skipped + 1)); continue
    fi
  fi

  # G4: Lauf-Budget (die Triage dispatcht danach max. 3 Items — hier nicht mehr freigeben).
  if [ "$redispatched" -ge "$MAX_PER_RUN" ]; then
    note "SKIP $n cap-per-run"; skipped=$((skipped + 1)); continue
  fi

  attempt=$((attempts + 1))
  if [ "$DRY_RUN" = 1 ]; then
    note "REDISPATCH $n attempts=$attempt dispatch_age=${age_min}min (dry-run)"
    redispatched=$((redispatched + 1)); continue
  fi

  # Reihenfolge = fail-closed: erst der Marker (Zähler), dann die Freigabe. Scheitert der
  # Marker, bleibt das Label stehen → kein Retry (lieber gelockt als Retry-Schleife).
  marker_body "$n" "$attempt" "$dispatch_iso" "$age_min" | jq -Rsc '{body: .}' \
    | "$GH" api -X POST "repos/$REPO/issues/$n/comments" --input - >/dev/null \
    || { err "Marker-Kommentar #$n fehlgeschlagen — Issue bleibt dispatched"; continue; }

  ensure_redispatch_label
  enc="$(jq -rn --arg s "$DISPATCH_LABEL" '$s | @uri')"
  "$GH" api -X DELETE "repos/$REPO/issues/$n/labels/$enc" >/dev/null \
    || { err "Label $DISPATCH_LABEL von #$n entfernen fehlgeschlagen"; continue; }
  jq -cn --arg l "$REDISPATCH_LABEL" '{labels: [$l]}' \
    | "$GH" api -X POST "repos/$REPO/issues/$n/labels" --input - >/dev/null \
    || err "Label $REDISPATCH_LABEL auf #$n setzen fehlgeschlagen (Freigabe bleibt gültig)"

  note "REDISPATCH $n attempts=$attempt dispatch_age=${age_min}min"
  redispatched=$((redispatched + 1))
done

note "summary issues=$issues stale=$stale redispatched=$redispatched capped=$capped skipped=$skipped scope=$SCOPE$DRY_TAG"
