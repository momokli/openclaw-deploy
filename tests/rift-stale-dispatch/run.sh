#!/usr/bin/env bash
# tests/rift-stale-dispatch/run.sh — Offline-Harness für scripts/rift-stale-dispatch.sh.
#
# Kein Netz, kein echtes `gh`/`openclaw`: beide werden durch PATH-Shims ersetzt, die aus
# Fixtures lesen und Mutationen in ein Logfile schreiben. Geprüft werden die Stale-Signale
# (S1–S5: Dispatch-Alter, verlinkter offener PR, Aktivität, Worker-Session-Status) und die
# Loop-Bremse (G1–G4: Zähler, Hard Cap, Cooldown, Lauf-Budget) — inklusive des real
# beobachteten Lock-Falls (3× `failed`, Label bleibt kleben → #401).
#
# Aufruf:
#   bash tests/rift-stale-dispatch/run.sh          # grüner Lauf gegen das echte Script
#   bash tests/rift-stale-dispatch/run.sh --red    # red-before-green: Fixture ohne Guard
#
# Exit 0 = alle Tests grün.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="${RIFT_STALE_DISPATCH_SCRIPT:-$ROOT/scripts/rift-stale-dispatch.sh}"
MODE="${1:-}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FIX="$TMP/fixtures"
FAKEBIN="$TMP/bin"
MUTLOG="$TMP/mutations.log"
mkdir -p "$FIX/timeline" "$FIX/sessions" "$FAKEBIN"

PASS=0; FAIL=0; N=0
ok()    { N=$((N+1)); PASS=$((PASS+1)); printf 'ok %d - %s\n' "$N" "$1"; }
notok() { N=$((N+1)); FAIL=$((FAIL+1)); printf 'not ok %d - %s\n' "$N" "$1"; }

# ── PATH-Shim: clanker-gh (liest Fixtures, protokolliert Mutationen) ────────
cat > "$FAKEBIN/clanker-gh" <<'SHIM'
#!/bin/bash
set -uo pipefail
fix="${GH_FIXTURE_DIR:?GH_FIXTURE_DIR not set}"
log="${GH_MUT_LOG:?GH_MUT_LOG not set}"
url=""
for a in "$@"; do case "$a" in repos/*) url="$a" ;; esac; done
num="${url#*/issues/}"; num="${num%%/*}"; [ "$num" = "$url" ] && num=""
case "${1:-}" in
  issue) cat "$fix/issues.json"; exit 0 ;;
  pr)    cat "$fix/prs.json";    exit 0 ;;
  label) cat "$fix/labels.json"; exit 0 ;;
  api) ;;
  *) echo "shim: unsupported command: $*" >&2; exit 1 ;;
esac
case "$url" in
  *"/milestones?state=open&per_page=100") cat "$fix/milestones.json" ;;
  *"/timeline?per_page=100")
    [ -f "$fix/timeline/$num.json" ] || { echo "shim: no timeline fixture for #$num" >&2; exit 1; }
    cat "$fix/timeline/$num.json" ;;
  *"/comments")
    printf 'POST-COMMENT %s %s\n' "$num" "$(cat)" >> "$log" ;;
  *"/labels/"*)
    printf 'DELETE-LABEL %s\n' "$url" >> "$log" ;;
  *"/labels")
    case "$url" in
      */issues/*) printf 'POST-LABEL %s %s\n' "$num" "$(cat)" >> "$log" ;;
      *)          printf 'CREATE-LABEL %s\n' "$(cat)" >> "$log" ;;
    esac ;;
  *) echo "shim: unsupported api url: $url" >&2; exit 1 ;;
esac
exit 0
SHIM

# ── PATH-Shim: openclaw (sessions list) ─────────────────────────────────────
cat > "$FAKEBIN/openclaw" <<'SHIM'
#!/bin/bash
set -uo pipefail
fix="${GH_FIXTURE_DIR:?GH_FIXTURE_DIR not set}"
agent=""
while [ $# -gt 0 ]; do case "$1" in --agent) agent="$2"; shift 2 ;; *) shift ;; esac; done
f="$fix/sessions/$agent.json"
[ -f "$f" ] || { echo "shim: no sessions fixture for $agent" >&2; exit 1; }
cat "$f"
SHIM
chmod +x "$FAKEBIN/clanker-gh" "$FAKEBIN/openclaw"

# ── Helfer ──────────────────────────────────────────────────────────────────
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
ago_iso() { iso $(( $(date -u +%s) - $1 * 60 )); }
ago_ms()  { echo $(( ( $(date -u +%s) - $1 * 60 ) * 1000 )); }

ev_labeled() { jq -cn --arg at "$1" --arg l "$2" '{event:"labeled", created_at:$at, label:{name:$l}}'; }
ev_unlabeled() { jq -cn --arg at "$1" --arg l "$2" '{event:"unlabeled", created_at:$at, label:{name:$l}}'; }
ev_commented() { jq -cn --arg at "$1" --arg b "$2" '{event:"commented", created_at:$at, body:$b}'; }
ev_referenced() { jq -cn --arg at "$1" '{event:"referenced", created_at:$at}'; }
ev_xref() {  # $1 at, $2 number, $3 state, $4 isPr 1|0
  jq -cn --arg at "$1" --argjson n "$2" --arg st "$3" --argjson pr "$4" \
    '{event:"cross-referenced", created_at:$at,
      source:{issue:{number:$n, state:$st, pull_request:(if $pr == 1 then {} else null end)}}}';
}
sess() { jq -cn --arg l "$1" --arg st "$2" --argjson up "$3" '{label:$l, status:$st, updatedAt:$up}'; }
marker() { printf '<!-- rift-triage:redispatch attempt=%s dispatch=x at=y -->' "$1"; }

ISSUE_DISPATCHED='[{"number":401,"title":"Ironium","url":"u","labels":[{"name":"orchestrator:dispatched"},{"name":"triage:implement"}]}]'
ISSUE_NO_DISPATCH='[{"number":401,"title":"Ironium","url":"u","labels":[{"name":"triage:implement"}]}]'
# Outcome-Label: der Worker signalisiert damit „Dispatch abgeschlossen, hier ist nichts
# weiter zu bauen" (erledigt / Prämisse widerlegt / Research-Bericht abgeliefert).
# Das Cleanup schließt das Issue daraufhin und gibt den WIP=1-Slot frei.
ISSUE_NO_ACTION='[{"number":401,"title":"Spike","url":"u","labels":[{"name":"orchestrator:dispatched"},{"name":"triage:no-action"}]}]'
PRS_NONE='[]'
LABELS_NO_RD='[{"name":"orchestrator:dispatched"},{"name":"triage:implement"}]'
LABELS_WITH_RD='[{"name":"triage:redispatch"}]'

TIMELINE=()   # Timeline-Events des Kandidaten-Issues (JSON-Zeilen)
SESSIONS=()   # Session-Rows (JSON-Zeilen), Agent coding-orchestrator

# setup <issues-json> <prs-json> <labels-json>
setup() {
  rm -rf "$FIX/timeline" "$FIX/sessions"; mkdir -p "$FIX/timeline" "$FIX/sessions"
  printf '%s' "$1" > "$FIX/issues.json"
  printf '%s' "$2" > "$FIX/prs.json"
  printf '%s' "$3" > "$FIX/labels.json"
  printf '[{"number":8,"title":"1.0"}]' > "$FIX/milestones.json"
  if [ "${#TIMELINE[@]}" -gt 0 ]; then printf '%s\n' "${TIMELINE[@]}" | jq -sc '.' > "$FIX/timeline/401.json"
  else echo '[]' > "$FIX/timeline/401.json"; fi
  if [ "${#SESSIONS[@]}" -gt 0 ]; then printf '%s\n' "${SESSIONS[@]}" | jq -sc '{count:length, sessions:.}' > "$FIX/sessions/coding-orchestrator.json"
  else echo '{"count":0,"sessions":[]}' > "$FIX/sessions/coding-orchestrator.json"; fi
  echo '{"count":0,"sessions":[]}' > "$FIX/sessions/planning-orchestrator.json"
  : > "$MUTLOG"
  TIMELINE=(); SESSIONS=()
}

RC=0; OUT=""; ERR=""
run() {
  RC=0
  OUT="$(GH_FIXTURE_DIR="$FIX" GH_MUT_LOG="$MUTLOG" PATH="$FAKEBIN:$PATH" \
        bash "$SCRIPT" -m 1.0 "$@" 2>"$TMP/err")" || RC=$?
  ERR="$(cat "$TMP/err")"
}
want()  { case "$OUT" in *"$1"*) ok "$2" ;; *) notok "$2 (out: $(printf '%s' "$OUT" | tr '\n' '|'))" ;; esac; }
mut()   { case "$(cat "$MUTLOG")" in *"$1"*) ok "$2" ;; *) notok "$2 (mut: $(tr '\n' '|' < "$MUTLOG"))" ;; esac; }
nomut() { [ -s "$MUTLOG" ] && notok "$1 (Mutationen: $(tr '\n' '|' < "$MUTLOG"))" || ok "$1"; }
muts()  { grep -c "^$1" "$MUTLOG" 2>/dev/null || echo 0; }

# ── red-before-green: Guard-loses Script gibt ALLES frei ────────────────────
if [ "$MODE" = "--red" ]; then
  echo "== red-before-green: fixtures/naive-release-all.sh (erwartet: fällt durch) =="
  NAIVE="$HERE/fixtures/naive-release-all.sh"
  [ -x "$NAIVE" ] || { echo "  FAIL Fixture fehlt/nicht ausführbar: $NAIVE"; exit 1; }
  red=0
  # Fall A: frischer Dispatch + verlinkter offener PR → der naive Guard gibt trotzdem frei.
  TIMELINE=("$(ev_labeled "$(ago_iso 2)" orchestrator:dispatched)")
  SESSIONS=()
  setup "$ISSUE_DISPATCHED" '[{"number":412,"headRefName":"feature/401-x","body":"Closes #401"}]' "$LABELS_NO_RD"
  ROUT="$(GH_FIXTURE_DIR="$FIX" GH_MUT_LOG="$MUTLOG" PATH="$FAKEBIN:$PATH" bash "$NAIVE" -m 1.0 2>/dev/null || true)"
  case "$ROUT" in *REDISPATCH*) echo "  --   naiv gibt frisches/verlinktes Issue frei → red bestätigt"; red=$((red+1)) ;;
    *) echo "  FAIL naiv hat nicht freigegeben" ;; esac
  # Fall B: Hard Cap (3 Versuche) erreicht → der naive Guard kennt keinen Zähler.
  TIMELINE=("$(ev_labeled "$(ago_iso 900)" orchestrator:dispatched)"
            "$(ev_commented "$(ago_iso 800)" "$(marker 1)")"
            "$(ev_commented "$(ago_iso 700)" "$(marker 2)")"
            "$(ev_commented "$(ago_iso 600)" "$(marker 3)")")
  SESSIONS=()
  setup "$ISSUE_DISPATCHED" "$PRS_NONE" "$LABELS_WITH_RD"
  ROUT="$(GH_FIXTURE_DIR="$FIX" GH_MUT_LOG="$MUTLOG" PATH="$FAKEBIN:$PATH" bash "$NAIVE" -m 1.0 2>/dev/null || true)"
  case "$ROUT" in *REDISPATCH*) echo "  --   naiv ignoriert den Hard Cap → red bestätigt"; red=$((red+1)) ;;
    *) echo "  FAIL naiv respektierte den Cap (unerwartet)" ;; esac
  echo "== red proof: $red/2 Signaturen scheitern am Guard-losen Script =="
  [ "$red" = 2 ] && { echo "RED OK"; exit 0; }
  echo "RED INCOMPLETE"; exit 1
fi

# ── 1. Der reale Lock-Fall: 3× failed, kein PR, keine Aktivität → Retry ─────
echo "== 1. Lock-Fall (#401): Dispatch alt, Worker failed, kein PR → REDISPATCH =="
TIMELINE=("$(ev_labeled "$(ago_iso 120)" orchestrator:dispatched)"
          "$(ev_unlabeled "$(ago_iso 115)" orchestrator:dispatched)"
          "$(ev_labeled "$(ago_iso 100)" orchestrator:dispatched)"
          "$(ev_labeled "$(ago_iso 95)" orchestrator:dispatched)")
SESSIONS=("$(sess triage-401 failed "$(ago_ms 110)")"
          "$(sess triage-401 failed "$(ago_ms 100)")"
          "$(sess triage-401 failed "$(ago_ms 94)")")
setup "$ISSUE_DISPATCHED" "$PRS_NONE" "$LABELS_NO_RD"
run
want "REDISPATCH 401 attempts=1 dispatch_age=95min" "stale Issue wird freigegeben (Alter ab letztem Dispatch)"
mut "POST-COMMENT 401 " "Marker-Kommentar wird VOR der Freigabe gepostet"
mut "DELETE-LABEL repos/momokli/riftbreaker-battle-mod/issues/401/labels/orchestrator%3Adispatched" "orchestrator:dispatched wird entfernt"
mut "POST-LABEL 401 " "triage:redispatch wird gesetzt"
mut "CREATE-LABEL" "fehlendes triage:redispatch-Label wird angelegt"
[ "$RC" = 0 ] && ok "Exit 0" || notok "Exit $RC"

# ── 2. Loop-Protection unangetastet: nur Kandidaten MIT Dispatch-Label ──────
echo "== 2. Issue ohne Dispatch-Label wird nicht angefasst =="
setup "$ISSUE_NO_DISPATCH" "$PRS_NONE" "$LABELS_NO_RD"
run
want "summary issues=0 stale=0 redispatched=0" "nicht-dispatched Issues sind keine Kandidaten"
nomut "keine Mutationen"

# ── 3. S2: frischer Dispatch → kein Retry ──────────────────────────────────
echo "== 3. S2: frischer Dispatch (< grace) → kein Retry =="
TIMELINE=("$(ev_labeled "$(ago_iso 2)" orchestrator:dispatched)")
setup "$ISSUE_DISPATCHED" "$PRS_NONE" "$LABELS_NO_RD"
run
want "SKIP 401 dispatch-fresh" "jüngerer Dispatch bleibt unangetastet"
nomut "keine Mutationen"

# ── 4. S3: verlinkter offener PR (Branch-Konvention / Body-Keyword / xref) ──
echo "== 4. S3: verlinkter offener PR → kein Retry =="
for variant in branch body xref; do
  TIMELINE=("$(ev_labeled "$(ago_iso 90)" orchestrator:dispatched)")
  PRS="$PRS_NONE"
  case "$variant" in
    branch) PRS='[{"number":412,"headRefName":"feature/401-ironium","body":"kein Keyword"}]' ;;
    body)   PRS='[{"number":412,"headRefName":"feature/x","body":"Fixes #401 (ironium readout)"}]' ;;
    xref)   TIMELINE+=("$(ev_xref "$(ago_iso 60)" 412 open 1)") ;;
  esac
  setup "$ISSUE_DISPATCHED" "$PRS" "$LABELS_NO_RD"
  run
  want "SKIP 401 linked-pr-open" "offener PR erkannt via $variant"
  nomut "keine Mutationen ($variant)"
done
TIMELINE=("$(ev_labeled "$(ago_iso 90)" orchestrator:dispatched)")
setup "$ISSUE_DISPATCHED" '[{"number":412,"headRefName":"feature/363-x","body":"analog zu carbonium (#363)"}]' "$LABELS_NO_RD"
run
want "REDISPATCH 401" "fremder PR (nur #363 erwähnt) schützt #401 nicht"
TIMELINE=("$(ev_labeled "$(ago_iso 90)" orchestrator:dispatched)"
          "$(ev_xref "$(ago_iso 80)" 355 closed 1)")
setup "$ISSUE_DISPATCHED" "$PRS_NONE" "$LABELS_NO_RD"
run
want "SKIP 401 activity-since-dispatch" "Cross-Reference nach dem Dispatch = Aktivität"

# ── 5. S4: Aktivität (Kommentar / Commit-Referenz) seit dem Dispatch ───────
echo "== 5. S4: Aktivität seit dem Dispatch → kein Retry =="
TIMELINE=("$(ev_labeled "$(ago_iso 90)" orchestrator:dispatched)"
          "$(ev_commented "$(ago_iso 30)" "Zwischenstand: P4 ist grün")")
setup "$ISSUE_DISPATCHED" "$PRS_NONE" "$LABELS_NO_RD"
run
want "SKIP 401 activity-since-dispatch" "Kommentar nach Dispatch = Aktivität"
TIMELINE=("$(ev_labeled "$(ago_iso 90)" orchestrator:dispatched)"
          "$(ev_commented "$(ago_iso 120)" "alter Kommentar VOR dem Dispatch")"
          "$(ev_referenced "$(ago_iso 88)")")
setup "$ISSUE_DISPATCHED" "$PRS_NONE" "$LABELS_NO_RD"
run
want "SKIP 401 activity-since-dispatch" "Commit-Referenz nach Dispatch = Aktivität"
TIMELINE=("$(ev_labeled "$(ago_iso 90)" orchestrator:dispatched)"
          "$(ev_commented "$(ago_iso 120)" "alter Kommentar VOR dem Dispatch")")
setup "$ISSUE_DISPATCHED" "$PRS_NONE" "$LABELS_NO_RD"
run
want "REDISPATCH 401" "Aktivität VOR dem Dispatch schützt nicht"

# ── 6. S5: Worker-Session-Status ───────────────────────────────────────────
echo "== 6. S5: Worker-Session seit dem Dispatch =="
TIMELINE=("$(ev_labeled "$(ago_iso 90)" orchestrator:dispatched)"); SESSIONS=("$(sess triage-401 done "$(ago_ms 60)")")
setup "$ISSUE_DISPATCHED" "$PRS_NONE" "$LABELS_NO_RD"
run
want "BLOCKED 401 worker-done-ohne-outcome" "done ohne Outcome -> geparkt (Slot frei, Mensch entscheidet)"
# Mit Outcome-Label ist derselbe Fall gesund: das Cleanup schließt das Issue (S3b).
TIMELINE=("$(ev_labeled "$(ago_iso 90)" orchestrator:dispatched)"); SESSIONS=("$(sess triage-401 done "$(ago_ms 60)")")
setup "$ISSUE_NO_ACTION" "$PRS_NONE" "$LABELS_NO_RD"
run
want "SKIP 401 no-action-label" "Outcome-Label gesetzt -> Cleanup übernimmt (kein Parken)"
TIMELINE=("$(ev_labeled "$(ago_iso 90)" orchestrator:dispatched)"); SESSIONS=("$(sess triage-401 done "$(ago_ms 200)")")
setup "$ISSUE_DISPATCHED" "$PRS_NONE" "$LABELS_NO_RD"
run
want "REDISPATCH 401" "done-Session VOR dem Dispatch zählt nicht (alter Versuch)"
TIMELINE=("$(ev_labeled "$(ago_iso 90)" orchestrator:dispatched)"); SESSIONS=("$(sess triage-401 running "$(ago_ms 5)")")
setup "$ISSUE_DISPATCHED" "$PRS_NONE" "$LABELS_NO_RD"
run
want "SKIP 401 worker-running" "frische running-Session = läuft noch"
TIMELINE=("$(ev_labeled "$(ago_iso 90)" orchestrator:dispatched)"); SESSIONS=("$(sess triage-401 running "$(ago_ms 300)")")
setup "$ISSUE_DISPATCHED" "$PRS_NONE" "$LABELS_NO_RD"
run
want "REDISPATCH 401" "Zombie-running-Session (älter als TTL) sperrt nicht dauerhaft"
TIMELINE=("$(ev_labeled "$(ago_iso 90)" orchestrator:dispatched)"); SESSIONS=("$(sess dev-401-impl done "$(ago_ms 60)")")
setup "$ISSUE_DISPATCHED" "$PRS_NONE" "$LABELS_NO_RD"
run
want "BLOCKED 401 worker-done-ohne-outcome" "auch freie Labels mit Issue-Nummer zählen (real: dev-267-impl)"
TIMELINE=("$(ev_labeled "$(ago_iso 90)" orchestrator:dispatched)"); SESSIONS=("$(sess dev-4010 done "$(ago_ms 60)")")
setup "$ISSUE_DISPATCHED" "$PRS_NONE" "$LABELS_NO_RD"
run
want "REDISPATCH 401" "Label mit fremder Nummer (dev-4010) schützt #401 nicht"

# ── 7. G1–G3: Zähler, Hard Cap, Cooldown ──────────────────────────────────
echo "== 7. Loop-Bremse: Zähler/Hard Cap/Cooldown =="
TIMELINE=("$(ev_labeled "$(ago_iso 300)" orchestrator:dispatched)"
          "$(ev_commented "$(ago_iso 280)" "$(marker 1)")"
          "$(ev_unlabeled "$(ago_iso 270)" orchestrator:dispatched)"
          "$(ev_labeled "$(ago_iso 260)" orchestrator:dispatched)")
SESSIONS=("$(sess triage-401 failed "$(ago_ms 259)")")
setup "$ISSUE_DISPATCHED" "$PRS_NONE" "$LABELS_WITH_RD"
run
want "REDISPATCH 401 attempts=2" "zweiter Retry zählt den Versuch hoch (Vormarker = kein Fortschritt)"
TIMELINE=("$(ev_labeled "$(ago_iso 90)" orchestrator:dispatched)"
          "$(ev_commented "$(ago_iso 10)" "$(marker 1)")")
setup "$ISSUE_DISPATCHED" "$PRS_NONE" "$LABELS_WITH_RD"
run
want "SKIP 401 cooldown" "Cooldown blockt zu schnelles Nachfassen"
nomut "keine Mutationen im Cooldown"
TIMELINE=("$(ev_labeled "$(ago_iso 900)" orchestrator:dispatched)"
          "$(ev_commented "$(ago_iso 800)" "$(marker 1)")"
          "$(ev_commented "$(ago_iso 700)" "$(marker 2)")"
          "$(ev_commented "$(ago_iso 600)" "$(marker 3)")")
setup "$ISSUE_DISPATCHED" "$PRS_NONE" "$LABELS_WITH_RD"
run
want "BLOCKED 401 cap-erreicht attempts=3" "Hard Cap: nach 3 Versuchen parken (Slot frei statt Deadlock)"
want "summary issues=1 stale=1 redispatched=0 capped=1" "Cap wird gezählt"
mut "POST-LABEL 401 " "Parken setzt das Blocked-Label"

# ── 8. G4: Lauf-Budget ────────────────────────────────────────────────────
echo "== 8. G4: max. --max-per-run Freigaben pro Lauf =="
ISSUES_TWO='[{"number":401,"title":"a","url":"u","labels":[{"name":"orchestrator:dispatched"}]},
             {"number":402,"title":"b","url":"u","labels":[{"name":"orchestrator:dispatched"}]}]'
TIMELINE=("$(ev_labeled "$(ago_iso 90)" orchestrator:dispatched)")
SESSIONS=()
setup "$ISSUES_TWO" "$PRS_NONE" "$LABELS_WITH_RD"
cp "$FIX/timeline/401.json" "$FIX/timeline/402.json"
run --max-per-run 1
want "REDISPATCH 401" "erste Freigabe im Lauf-Budget"
want "SKIP 402 cap-per-run" "zweite Freigabe wird auf den nächsten Lauf vertagt"
want "summary issues=2 stale=2 redispatched=1" "Budget respektiert"

# ── 9. --dry-run ändert nichts ────────────────────────────────────────────
echo "== 9. --dry-run =="
TIMELINE=("$(ev_labeled "$(ago_iso 90)" orchestrator:dispatched)")
SESSIONS=("$(sess triage-401 failed "$(ago_ms 89)")")
setup "$ISSUE_DISPATCHED" "$PRS_NONE" "$LABELS_NO_RD"
run --dry-run
want "REDISPATCH 401 attempts=1" "dry-run zeigt die Entscheidung"
want "dry-run=1" "Summary markiert den dry-run"
nomut "dry-run mutiert nichts"

# ── 10. Usage/Fehlerpfade ─────────────────────────────────────────────────
echo "== 10. Usage & Fehlerpfade =="
TIMELINE=("$(ev_labeled "$(ago_iso 90)" orchestrator:dispatched)")
setup "$ISSUE_DISPATCHED" "$PRS_NONE" "$LABELS_NO_RD"
RC=0; OUT="$(GH_FIXTURE_DIR="$FIX" GH_MUT_LOG="$MUTLOG" PATH="$FAKEBIN:$PATH" bash "$SCRIPT" 2>&1)" || RC=$?
[ "$RC" = 0 ] && ok "ohne -m: Default ist scope=all" || notok "Exit 0 erwartet, war $RC"
case "$OUT" in *"scope=all"*) ok "Log nennt scope=all" ;; *) notok "Log: $OUT" ;; esac
run --milestone
[ "$RC" = 2 ] && ok "fehlender Flagwert → Exit 2" || notok "Exit 2 erwartet, war $RC"
run --help
want "rift-stale-dispatch.sh" "--help funktioniert"

echo
echo "== $PASS/$N Tests grün =="
[ "$FAIL" = 0 ] || exit 1
exit 0
