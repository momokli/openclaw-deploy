#!/bin/bash
# Leichtgewichtiger Precheck für `rift-triage` (0 Tokens).
#
# Läuft oft (z. B. alle 5 min) als `--command`-Automation auf dem Gateway und
# entscheidet nur per `gh`, ob es JETZT überhaupt etwas zu dispatchen gäbe. Nur
# dann wird der teure Agent-Turn (`rift-triage:main`) angestoßen — sonst Exit 10.
#
# Grund: die Slot-Prüfung im Prompt kostet sonst bei jedem Tick einen vollen
# Model-Turn (~50k Input-Tokens), auch wenn nichts zu tun ist. Der Durchsatz ist
# ohnehin durch WIP=1 gedeckelt, nicht durch den Takt.
#
# Exit 0  = OK (entweder Agent-Turn angestoßen ODER nichts zu tun; welches steht im Log).
#           WICHTIG: auch der Skip muss 0 sein — der Scheduler wertet einen Command-Payload
#           mit Exit ≠ 0 als Job-Fehler (und stdout geht hier in die Logdatei, ist also leer).
# Exit 2  = Fehler (gh/CLI) → Job-Status wird `error` (gewollt sichtbar).
#
# Genau dieselben Kriterien wie im Prompt (Slot frei + ≥1 Leaf-Kandidat), nur
# billig vorgezogen. Der Agent-Turn prüft danach noch einmal verbindlich.
set -uo pipefail

REPO="momokli/riftbreaker-battle-mod"
GH="${RIFT_GH:-clanker-gh}"
SELF_KEY="rift-triage:main"

log()  { printf '%s rift-triage-tick: %s\n' "$(date -Is)" "$*"; }
skip() { log "SKIP $*"; exit 0; }
die()  { log "FEHLER $*"; exit 2; }

command -v "$GH" >/dev/null 2>&1 || die "$GH nicht im PATH"

# 1) Fokus-Milestone (kleinster offener Versions-Titel).
FOCUS="$(rift-focus-milestone.sh --json 2>/dev/null)" || skip "kein Fokus-Milestone"
N="$(printf '%s' "$FOCUS" | jq -r '.number // empty')"
TITLE="$(printf '%s' "$FOCUS" | jq -r '.title // empty')"
OPEN="$(printf '%s' "$FOCUS" | jq -r '.open_issues // 0')"
# Dispatch-Reihenfolge: Checkliste `- [ ] #NNN` aus der Milestone-Beschreibung.
DESC="$(printf '%s' "$FOCUS" | jq -r '.description // ""')"
[ -n "$N" ] || die "Fokus-Milestone nicht parsebar: $FOCUS"
# 0 offene Issues heisst CODE-COMPLETE, nicht "nichts zu tun": NICHT hier skippen — sonst ist
# der Release-/Changelog-Pfad weiter unten unerreichbar (real: 1.0.2 hing genau so fest, weil
# der Mensch alle Issues geschlossen hatte). Nur ein wirklich leerer Milestone (0 offen UND
# 0 geschlossen) hat nichts auszuliefern.
CLOSED="$(printf '%s' "$FOCUS" | jq -r '.closed_issues // 0')"
[ "$(( ${OPEN:-0} + ${CLOSED:-0} ))" -gt 0 ] || skip "Fokus $TITLE leer (keine Issues)"

# 2) Buchhaltung (0 Tokens): Stale-Dispatch-Guard + Schritt-4-Cleanup.
#    Beides MUSS laufen, AUCH wenn der Slot belegt ist — sonst klemmt ein
#    hängender Dispatch für immer (real passiert: #393, #895). Genau das war der
#    Bug der ersten Tick-Version: sie gated auf das Label und verhinderte damit
#    den Aufräum-Turn.
if command -v rift-stale-dispatch.sh >/dev/null 2>&1; then
  GUARD="$(rift-stale-dispatch.sh -m "$TITLE" 2>&1 | grep -E '^(REDISPATCH|BLOCKED|NOTE|summary)' | tr '\n' ' ')"
  log "Guard: ${GUARD:-nichts freizugeben}"
else
  log "WARNUNG: rift-stale-dispatch.sh fehlt — Guard übersprungen"
fi
if command -v rift-triage-cleanup.sh >/dev/null 2>&1; then
  rift-triage-cleanup.sh -m "$TITLE" 2>&1 | sed 's/^/    /'
else
  log "WARNUNG: rift-triage-cleanup.sh fehlt — Cleanup übersprungen"
fi

# 2b) Handoff-Buchhaltung: der Gate gibt nach `REQUEST_CHANGES` an Runner A zurueck, indem er
#     `triage:implement` setzt und `orchestrator:dispatched` entfernt. Vergisst der Agent das
#     Abnehmen, klebt der WIP=1-Slot und A kommt nie ran — real 3,5 h Stillstand (#909/#917).
#     Das ist reine Buchhaltung, also deterministisch hier (0 Tokens).
HANDOFF="$("$GH" issue list --repo "$REPO" --state open --milestone "$N" \
  --label "triage:implement" --limit 100 --json number,labels 2>/dev/null \
  | jq -r '.[] | select(([.labels[].name] | index("orchestrator:dispatched")) != null) | .number')"
for hn in $HANDOFF; do
  if "$GH" issue edit "$hn" --repo "$REPO" --remove-label "orchestrator:dispatched" >/dev/null 2>&1; then
    log "Handoff #$hn: Dispatch-Label entfernt (Gate hat Korrektur angefordert) → Slot frei"
  else
    log "WARNUNG: Dispatch-Label von #$hn nicht entfernbar (Handoff)"
  fi
done

# 3) Slot frei? Kein `orchestrator:dispatched` im Fokus (nach dem Aufräumen).
DISPATCHED="$("$GH" issue list --repo "$REPO" --state open --milestone "$N" \
  --label orchestrator:dispatched --limit 100 --json number 2>/dev/null)" \
  || die "issue list (dispatched) fehlgeschlagen"
if [ "$(printf '%s' "$DISPATCHED" | jq 'length' 2>/dev/null)" != "0" ]; then
  skip "Slot belegt (orchestrator:dispatched: $(printf '%s' "$DISPATCHED" | jq -r '[.[].number]|join(",")'))"
fi

# 4) Issues + offene PRs des Fokus holen.
ISSUES="$("$GH" issue list --repo "$REPO" --state open --milestone "$N" --limit 100 \
  --json number,title,labels,body 2>/dev/null)" || die "issue list fehlgeschlagen"
PRS="$("$GH" pr list --repo "$REPO" --state open --limit 100 \
  --json number,title,body,headRefName,labels,comments 2>/dev/null)" || die "pr list fehlgeschlagen"

# 4b) Gate-Handback deterministisch nachziehen (0 Tokens).
#     Ein offener Fokus-PR mit letztem `[VERDICT: REQUEST_CHANGES]` heisst: **A muss
#     nachbessern**. Setzt der Gate das Handoff-Label `triage:implement` nicht, haengt der
#     Slot in Schritt 5 (offener Fokus-PR ohne Handoff-Ausnahme) — real: #929/#938.
#     Nur wenn KEIN Dispatch laeuft (kein `orchestrator:dispatched`): sonst Finger weg,
#     dann greift der Guard (rift-stale-dispatch.sh) bzw. die 2b-Buchhaltung.
HANDBACK="$(jq -nr --argjson issues "$ISSUES" --argjson prs "$PRS" '
  [ $prs[]
    | select((([.labels[]?.name] | index("release:human-merge")) == null))
    | { verdict: ( [ .comments[]? | (.body // "")
                    | capture("\\[VERDICT:[ \\t]*(?<v>[A-Za-z_]+)")? ]
                  | last // {} | (.v // "") ),
        refs: ( ((.headRefName // "") | [scan("(?:^|[/_-])([0-9]+)(?=[/_-]|$)")] | map(.[0] | tonumber))
              + ((.body // "")
                 | [scan("(?i)\\b(?:fix(?:e[sd])?|close[sd]?|resolve[sd]?|relate[sd]?|part of|addresses)\\b[ \\t]*:?[ \\t]*#([0-9]+)")]
                 | map(.[0] | tonumber)) ) }
    | select(.verdict == "REQUEST_CHANGES")
    | .refs[]
  ] as $refs
  | $issues[]
  | select((.labels | map(.name) | index("triage:implement")) == null)
  | select((.labels | map(.name) | index("orchestrator:dispatched")) == null)
  | select(.number as $x | ($refs | index($x)) != null)
  | .number  | tostring')" || die "Handback-Auswahl fehlgeschlagen"
for hn in $HANDBACK; do
  if "$GH" issue edit "$hn" --repo "$REPO" --add-label "triage:implement" >/dev/null 2>&1; then
    log "Handback #$hn: Gate-Reject ohne Handoff-Label → triage:implement gesetzt (Fixer dispatchbar)"
  else
    log "WARNUNG: triage:implement auf #$hn nicht setzbar (Handback)"
  fi
done
if [ -n "$HANDBACK" ]; then
  # Liste neu holen, damit Schritt 5 die Handoff-Ausnahme sieht (gleicher Lauf).
  ISSUES="$("$GH" issue list --repo "$REPO" --state open --milestone "$N" --limit 100 \
    --json number,title,labels,body 2>/dev/null)" || die "issue list (refresh) fehlgeschlagen"
fi

# 5) Offener PR mit Bezug auf ein Fokus-Issue? (Slot belegt)
#    AUSNAHMEN, in denen ein offener PR NICHT blockiert:
#    a) hat der Stale-Guard das Issue gerade für einen Retry freigegeben
#       (`triage:redispatch`), darf der PR den Milestone nicht einfrieren — sonst
#       blockiert genau der rot gelaufene PR den Retry, der ihn reparieren soll (real: #905).
#    b) ein Release-PR (`release:human-merge`) ist die *Endabnahme* des Milestones, nicht
#       Arbeit an einem Issue: er wartet auf den Menschen und darf den Slot nicht halten
#       (sonst friert er genau dann alles ein, wenn ein Player-Test einen Retry braucht).
PR_HIT="$(jq -nr --argjson prs "$PRS" --argjson issues "$ISSUES" '
  def refs: ((.title // "") + " " + (.body // "") + " " + (.headRefName // ""))
            | [scan("#([0-9]+)")] | flatten | map(tonumber);
  [ $issues[] | .number ] as $focus
  | [ $issues[] | select((([.labels[].name] | index("triage:redispatch")) != null)) | .number ] as $retry
  | [ $issues[] | select((([.labels[].name] | index("triage:implement")) != null)) | .number ] as $handoff
  | [ $prs[]
      | select((([.labels[]?.name] | index("release:human-merge")) == null))
      | select(refs | any(. as $n | $focus | index($n)))
      | select((refs | any(. as $n | $retry | index($n))) | not)
      | select((refs | any(. as $n | $handoff | index($n))) | not)
      | .number ] | join(",")')"
[ -z "$PR_HIT" ] || skip "offener Fokus-PR: #$PR_HIT"

# 6) ≥1 dispatchbarer Leaf-Kandidat? (Spiegel des Leaf-Gates im Prompt)
LEAF="$(printf '%s' "$ISSUES" | jq -c '
  [ .[]
    | select((.title | test("^\\[(Epic|Umbrella|Milestone|Release)\\]"; "i")) | not)
    | select(([.labels[].name] | any(. == "claimed" or . == "needs:player-test"
        or . == "follow-up" or . == "hold" or . == "question"
        or . == "triage:no-action")) | not)
    | select(( (([.labels[].name] | index("research")) != null)
               and (([.labels[].name] | index("triage:research")) == null) ) | not)
    | select((.body // "" | [scan("(?m)^[ \t]*- \\[ \\][ \t]*#[0-9]+")] | length) < 2)
    | .number ]')"
if [ "$(printf '%s' "$LEAF" | jq 'length' 2>/dev/null)" = "0" ]; then
  # Noch offene `triage:no-action`-Issues sind Buchhaltung, nicht Fertigstellung: die raeumt
  # Schritt 2 (Cleanup) im selben Lauf weg. Erst danach ist der Milestone code-complete.
  if printf '%s' "$ISSUES" | jq -e 'any(.[]; any(.labels[]?; .name == "triage:no-action"))' >/dev/null 2>&1; then
    skip "kein Leaf-Kandidat, aber offene triage:no-action (Cleanup laeuft)"
  fi
  # Kein Leaf mehr ⇒ der Milestone ist CODE-COMPLETE. Die letzte Aufgabe ist der
  # RELEASE-PR (Changelog + Abnahme + Testplan), den der GATE baut und den der Mensch
  # merged. Wir schreiben die Entscheidung und triggern den Gate-Turn — der Agent-Turn
  # hier waere der falsche (er baut Issues ab, nicht Releases).
  # Release bereits ausgeliefert? Der Release-PR schliesst das `[Release]`-Tracking-Issue.
  # Ist dieses ZU, ist der Release durch — dann darf hier nichts erneut anlaufen, solange
  # der Mensch den Milestone noch nicht geschlossen hat (sonst entstuende ein zweiter
  # Release-PR fuer denselben Release). Das Tracking-Issue lebt nicht in $ISSUES (nur offene).
  CLOSED_JSON="$($GH issue list --repo "$REPO" --milestone "$N" --state closed --limit 200 \
      --json number,title,closedAt 2>/dev/null)" || CLOSED_JSON='[]'
  if printf '%s' "$CLOSED_JSON" | jq -e 'any(.[]; .title | test("^\\[Release\\]"; "i"))' >/dev/null 2>&1; then
    skip "Release ausgeliefert ([Release]-Issue geschlossen) — Milestone schliessen"
  fi
  # Release-PR des Fokus: NUR seinen eigenen (`release/<titel>`) betrachten — im Run-ahead
  # koennen anderer Milestones Release-PRs offen sein, die hier nichts zu suchen haben.
  # NUR skippen, wenn er den aktuellen Milestone-Stand schon abbildet; sonst bliebe nach neu
  # gemergter Arbeit der Changelog stehen (real: #951 entstand, als #930 faelschlich zu war).
  REL_PR_NUM="$(printf '%s' "$PRS" | jq -r --arg b "release/$TITLE" \
    'map(select(any(.labels[]?; .name == "release:human-merge")) | select(.headRefName == $b))[0].number // ""')"
  if [ -n "$REL_PR_NUM" ]; then
    rel_commit="$($GH pr view "$REL_PR_NUM" --repo "$REPO" --json commits 2>/dev/null \
      | jq -r '[.commits[].committedDate] | max // ""')"
    newest_closed="$(printf '%s' "$CLOSED_JSON" | jq -r '[.[].closedAt // empty] | max // ""')"
    if [ -n "$rel_commit" ] && [ -n "$newest_closed" ] && [ "$newest_closed" \> "$rel_commit" ]; then
      log "Release-PR #$REL_PR_NUM veraltet (Arbeit nach letztem Release-Commit) → wird aktualisiert"
    else
      skip "code-complete, Release-PR #$REL_PR_NUM laeuft und ist aktuell (wartet auf den Menschen)"
    fi
  fi
  # Idempotenz-Sperre: der Gate-Turn braucht Minuten (Branch + CHANGELOG + PR). Ohne
  # Sperre triggert JEDER 5-Min-Tick erneut — jeder Trigger ist ein voller Modell-Turn.
  # (Real passiert: 22:21 und 22:26 beide getriggert, weil der PR noch nicht existierte.)
  REL_STAMP="${OPENCLAW_STATE_DIR:-/srv/openclaw}/workspace/rift-release-requested.stamp"
  REL_COOLDOWN="${RIFT_RELEASE_COOLDOWN_MIN:-30}"
  if [ -f "$REL_STAMP" ]; then
    stamp_ep="$(cat "$REL_STAMP" 2>/dev/null)"
    case "$stamp_ep" in ''|*[!0-9]*) stamp_ep=0 ;; esac
    if [ "$stamp_ep" -gt 0 ]; then
      rel_age=$(( ( $(date -u +%s) - stamp_ep ) / 60 ))
      if [ "$rel_age" -lt "$REL_COOLDOWN" ]; then
        skip "Release bereits angefragt vor ${rel_age}min (< ${REL_COOLDOWN}min Cooldown)"
      fi
    fi
  fi
  REL_FILE="${OPENCLAW_STATE_DIR:-/srv/openclaw}/workspace/rift-release-decision.md"
  # Release-PRs stapeln: der neue Release-Branch zweigt vom Release-Branch des
  # naechstkleineren offenen Release-PRs ab (sonst `main`) — so kollidieren mehrere
  # offene Release-PRs nicht im CHANGELOG.md beim Mergen in Reihenfolge (Run-ahead).
  REL_BASE="main"
  rel_best=""
  for v in $(printf '%s' "$PRS" | jq -r '.[] | select(any(.labels[]?; .name=="release:human-merge")) | .headRefName // empty' \
             | sed -n 's#^release/##p'); do
    [ "$v" = "$TITLE" ] && continue
    [ "$(printf '%s\n%s\n' "$v" "$TITLE" | sort -V | head -1)" = "$v" ] || continue
    if [ -z "$rel_best" ] || [ "$(printf '%s\n%s\n' "$v" "$rel_best" | sort -V | tail -1)" = "$v" ]; then
      rel_best="$v"
    fi
  done
  [ -n "$rel_best" ] && REL_BASE="release/$rel_best"
  {
    printf '# Release-Entscheidung (Shell-Reconciler, verbindlich)\n\n'
    printf -- '- Zeit: %s\n' "$(date -Is)"
    printf -- '- Milestone: %s (#%s)\n' "$TITLE" "$N"
    printf -- '- Tag-Vorschlag: v%s\n' "$TITLE"
    printf -- '- PR-Titel: chore(release): v%s — <Milestone-Titel> (erlaubter Conventional-Type)\n' "$TITLE"
    printf -- '- Release-Issue: offenes `[Release]`-Issue im Milestone (anlegen, falls es fehlt) — der PR-Body MUSS es per `Closes #<n>` schliessen (Required-Check).\n'
    printf -- '- Basis-Branch: %s · PR-Ziel: %s · Marker-Label: %s\n' "$REL_BASE" "$REL_BASE" "release:human-merge"
    if [ "$REL_BASE" != "main" ]; then
      printf -- '- STACK: Branch `release/%s` von `%s` abzweigen (Vorgaenger-Release noch offen) — NICHT von main.\n' "$TITLE" "$REL_BASE"
    fi
    printf '\nDer Fokus-Milestone hat KEINE offenen Leaf-Kandidaten mehr (code-complete).\n'
    printf 'Aufgabe: Release-PR bauen bzw. aktualisieren — `CHANGELOG.md` schreiben (Factorio-Stil,\n'
    printf 'Kategorien + je eine knappe Zeile, AUS DATEN: geschlossene Milestone-Issues + gemergte PRs;\n'
    printf 'nichts erfinden) und im PR-Body zusaetzlich **Abnahme** (DoD-Kriterien mit Beleg + ehrlichem\n'
    printf 'Status) und **Testplan** (Ziel: staging, aus den `needs:player-test`-Issues) abbilden.\n'
    printf 'Diesen PR NIE mergen — er ist die menschliche Freigabe (Label `release:human-merge`).\n'
    printf 'Abnahme GLOBAL und praezise belegen: Boot-Test = Wall-Time des ganzen boot-test-Jobs\n'
    printf '(uebersprungen durch den Path-Filter = "nicht messbar", nicht "gruen"), high-prio-Bugs\n'
    printf 'repo-weit auflisten. Nicht schoenreden — der Mensch entscheidet damit.\n'
  } > "$REL_FILE" 2>/dev/null || log "WARNUNG: Release-File ($REL_FILE) nicht schreibbar"
  if [ "${RIFT_TICK_DRY:-0}" = "1" ]; then
    log "DRY-RUN: code-complete ($TITLE) — Release-PR faellig, würde rift-pr-gate:main triggern"
    exit 0
  fi
  # Fail-closed: erst stempeln, dann triggern. Scheitert der Trigger, wird nicht gehämmert.
  date -u +%s > "$REL_STAMP" 2>/dev/null || log "WARNUNG: Release-Stamp ($REL_STAMP) nicht schreibbar"
  GATE_ID="$(openclaw automations list --all --json 2>/dev/null \
        | jq -r '.jobs[] | select(.declarationKey == "rift-pr-gate:main") | .id' | head -1)"
  [ -n "$GATE_ID" ] && [ "$GATE_ID" != "null" ] || die "Agent-Job rift-pr-gate:main nicht gefunden"
  log "CODE-COMPLETE ($TITLE #$N) → Release-PR faellig; triggere rift-pr-gate:main ($GATE_ID)"
  openclaw automations run "$GATE_ID" 2>&1 | tail -3
  exit 0
fi

# 6b) Auswahl deterministisch treffen. Die Reihenfolge kommt aus der
#     FOKUS-MILESTONE-BESCHREIBUNG: die Checkliste `- [ ] #NNN` von oben nach unten.
#     Fallback: Checkliste im `[Epic]`-Issue (Altbestand). Sonst: aufsteigende Nummer.
#     Das Ergebnis wird verbindlich in eine Datei geschrieben — `openclaw automations
#     run` nimmt keine Parameter, also ist die Datei der Kanal.
#
#     Nur Checklisten-Zeilen zaehlen (nicht jedes `#NNN` im Prosatext): ein Milestone-Text
#     nennt Issues auch in Prosa (z. B. „erledigt: #337, #393 …"), und das darf die
#     Reihenfolge nicht veraendern. Von einer Zeile zaehlt nur die ERSTE Nummer — ein
#     Klammer-Hinweis wie „- [ ] #877 — Relay (PR #878 offen)" darf #878 nicht mitbringen.
order_from() {
  printf '%s' "$1" \
    | sed -E -n 's/^[[:space:]]*[-*][[:space:]]*\[[ xX]\][[:space:]]*#([0-9]+).*/\1/p'
}
EPIC_BODY="$(printf '%s' "$ISSUES" | jq -r '[.[] | select(.title | test("^\\[Epic\\]"; "i"))][0].body // ""')"
CHOSEN=""
for order_src in "$DESC" "$EPIC_BODY"; do
  [ -n "$order_src" ] || continue
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    if printf '%s' "$LEAF" | jq -e --argjson c "$cand" 'index($c) != null' >/dev/null 2>&1; then
      CHOSEN="$cand"; break
    fi
  done <<< "$(order_from "$order_src")"
  [ -n "$CHOSEN" ] && break
done
[ -n "$CHOSEN" ] || CHOSEN="$(printf '%s' "$LEAF" | jq -r 'sort | .[0]')"
[ -n "$CHOSEN" ] && [ "$CHOSEN" != "null" ] || die "keine Issue auswählbar"

DECISION_FILE="${OPENCLAW_STATE_DIR:-/srv/openclaw}/workspace/rift-triage-decision.md"
CHOSEN_TITLE="$(printf '%s' "$ISSUES" | jq -r --argjson c "$CHOSEN" '.[]|select(.number==$c)|.title')"
# Existiert zum gewählten Issue schon ein offener PR (z. B. nach einem Guard-Retry wegen
# rotem Required-Check)? Dann ist der Branch die Arbeitsgrundlage — einen zweiten PR
# aufzumachen würde den Slot erneut blockieren (Schritt 5 kennt nur „PR offen").
EXIST_PR="$(jq -nr --argjson prs "$PRS" --argjson c "$CHOSEN" '
  # Release-PRs sind nie Arbeitsgrundlage (real: #951 nannte `#930` im Text und wurde
  # faelschlich als bestehender PR fuer #930 gewaehlt, statt des echten #948).
  # Treffer mit Branch-Token/Closing-Keyword sind stark und schlagen blosse Erwaehnungen.
  [ $prs[]
    | select((([.labels[]?.name] | index("release:human-merge")) == null))
    | { n: .number,
        s: ( if ( ((.headRefName // "") | test("(^|[/_-])" + ($c | tostring) + "([/_-]|$)"))
                  or ((.body // "") | test("(?i)\\b(?:fix(?:e[sd])?|clos(?:e[sd]?|ing)|resolve[sd]?)\\b[ \\t]*:?[ \\t]*#" + ($c | tostring) + "\\b")) )
             then 0 else 1 end ),
        hit: ( ( ((.title // "") + " " + (.body // "") + " " + (.headRefName // ""))
                 | [scan("#([0-9]+)")] | flatten | map(tonumber) | index($c) ) != null ) }
    | select(.hit)
  ] | sort_by(.s) | (.[0].n // "") | tostring')"
# Eindeutiges Worker-Label (Pflicht): `sessions_spawn` verweigert ein bereits benutztes Label
# ("label already in use") — ein Retry/Rework mit statischem `triage-<n>` fiel real aus (#929).
# Der Stale-Guard liest nur den Nummern-Token; der Epoch-Suffix stoert ihn nicht.
WORKER_LABEL="triage-${CHOSEN}-$(date -u +%s)"
# Offener Review-Blocker: der letzte `[VERDICT: REQUEST_CHANGES]`-Kommentar auf dem bestehenden
# PR gehoert in den Auftrag. Real (#948): der Fixer wurde nur zum Rebase geschickt, waehrend der
# Review die Pflicht-Screenshots (B1) verlangte — ohne das im Auftrag droht Rebase/Reject-Schleife.
REVIEW_BODY=""
if [ -n "$EXIST_PR" ]; then
  REVIEW_BODY="$(printf '%s' "$PRS" | jq -r --argjson n "$EXIST_PR" '
    [ .[] | select(.number == $n) | .comments[]? | (.body // "")
      | select(test("^\\[VERDICT:[ \\t]*REQUEST_CHANGES\\]")) ] | last // ""')"
fi
{
  printf '# Triage-Entscheidung (Shell-Reconciler, verbindlich)\n\n'
  printf -- '- Zeit: %s\n' "$(date -Is)"
  printf -- '- Fokus-Milestone: %s (#%s)\n' "$TITLE" "$N"
  printf -- '- Issue: #%s — %s\n' "$CHOSEN" "$CHOSEN_TITLE"
  printf -- '- Basis-Branch: main · PR-Ziel: main\n'
  printf -- '- Deliverable: gepushter Branch + offener PR; PR-Body mit `Closes #%s`.\n' "$CHOSEN"
  if [ -n "$EXIST_PR" ]; then
    printf -- '- Bestehender offener PR: #%s — auf DESSEN Branch weiterarbeiten (keinen zweiten PR öffnen).\n' "$EXIST_PR"
  fi
  printf -- '- Worker-Label: %s (PFLICHT fuer `sessions_spawn`; pro Dispatch eindeutig).\n' "$WORKER_LABEL"
  if [ -n "$REVIEW_BODY" ]; then
    printf '\n**Offener Review-Blocker (letzter `[VERDICT: REQUEST_CHANGES]` auf PR #%s) — MUSS im Rework adressiert werden:**\n\n' "$EXIST_PR"
    printf '%s\n' "$REVIEW_BODY"
  fi
  printf '\n**Diese Auswahl ist verbindlich** — keine Neuauswahl, kein Slot-/Leaf-Re-Check im Agent-Turn.\n'
  printf 'Ist das Issue bereits erledigt: kein PR, sondern Kommentar + Label `triage:no-action`.\n'
} > "$DECISION_FILE" 2>/dev/null || log "WARNUNG: Decision-File ($DECISION_FILE) nicht schreibbar"

# 7) Dispatch-Marker deterministisch setzen, BEVOR der Agent-Turn startet: der Slot ist damit
#    sofort belegt (kein zweiter Dispatch im 5-min-Fenster) und `triage:implement` wird
#    abgenommen. Bleibt es kleben, nimmt Schritt 2b im naechsten Tick `orchestrator:dispatched`
#    wieder weg (weil `triage:implement` noch dran ist) und dasselbe Issue wird doppelt
#    dispatcht (real: #929 — der Rework-Worker lief, der Slot sah trotzdem frei aus).
if [ "${RIFT_TICK_DRY:-0}" = "1" ]; then
  log "DRY-RUN: dispatchbar ($TITLE), Issue #$CHOSEN gewählt (Decision-File geschrieben), würde $SELF_KEY triggern"
  exit 0
fi
ID="$(openclaw automations list --all --json 2>/dev/null \
      | jq -r --arg k "$SELF_KEY" '.jobs[] | select(.declarationKey == $k) | .id' | head -1)"
[ -n "$ID" ] && [ "$ID" != "null" ] || die "Agent-Job $SELF_KEY nicht gefunden"
# Erst wenn der Trigger sicher möglich ist, den Slot im Repo belegen (sonst bliebe bei einem
# Fehler ein Dispatch-Label ohne Worker stehen — der Guard muesste es nach 20 min muehsam loesen).
if ! "$GH" issue edit "$CHOSEN" --repo "$REPO" \
     --add-label orchestrator:dispatched --remove-label triage:implement >/dev/null 2>&1; then
  die "Dispatch-Label fuer #$CHOSEN (+orchestrator:dispatched -triage:implement) fehlgeschlagen"
fi

log "DISPATCHBAR ($TITLE) → Issue #$CHOSEN ($CHOSEN_TITLE); triggere $SELF_KEY ($ID)"
openclaw automations run "$ID" 2>&1 | tail -3
exit 0
