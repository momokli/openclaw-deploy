#!/usr/bin/env bash
# tests/rift-triage-tick/run.sh — Offline-Harness für scripts/rift-triage-tick.sh.
#
# Kein Netz, kein `gh`/`openclaw`: PATH-Shims antworten aus Fixtures und protokollieren,
# was der Tick tut. Geprüft wird die Trigger-Entscheidung (Agent-Turn ja/nein) UND die
# Kern-Zusicherung aus Schritt 1 der Runner-Architektur:
#
#   Guard und Cleanup laufen IMMER — auch wenn der Slot belegt ist.
#
# (Vorher gated der Tick aufs Label und verhinderte damit den Aufräum-Turn; real wurde
# daraus der Deadlock bei #393/#895.)
#
# Aufruf:
#   bash tests/rift-triage-tick/run.sh
#
# Exit 0 = alle Tests grün.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="${RIFT_TRIAGE_TICK_SCRIPT:-$ROOT/scripts/rift-triage-tick.sh}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FX="$TMP/fx"; mkdir -p "$FX"
ACTIONS="$TMP/actions.log"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else notok "$1 (erwartet: $2 | ist: $3)"; fi; }

# ── Shims ────────────────────────────────────────────────────────────────────
cat > "$TMP/rift-focus-milestone.sh" <<'SHIM'
#!/bin/bash
[ -f "$FX/focus" ] || exit 3
cat "$FX/focus"
SHIM

cat > "$TMP/rift-stale-dispatch.sh" <<'SHIM'
#!/bin/bash
printf 'guard\n' >> "$ACTIONS"
echo "summary issues=0 stale=0 redispatched=0 capped=0 skipped=0"
SHIM

cat > "$TMP/rift-triage-cleanup.sh" <<'SHIM'
#!/bin/bash
printf 'cleanup\n' >> "$ACTIONS"
echo "nichts zu tun"
SHIM

cat > "$TMP/gh" <<'SHIM'
#!/bin/bash
case "$1 $2" in
  "issue list")
    case "$*" in
      *"--state closed"*)        cat "$FX/issues-closed.json" ;;
      *orchestrator:dispatched*) cat "$FX/dispatched.json" ;;
      *)                         cat "$FX/issues.json" ;;
    esac ;;
  "pr list") cat "$FX/prs.json" ;;
  "issue edit") printf 'issue-edit %s\n' "$*" >> "$ACTIONS" ;;
esac
exit 0
SHIM

cat > "$TMP/openclaw" <<'SHIM'
#!/bin/bash
if [ "$1 $2 $3" = "automations list --all" ]; then
  echo '{"jobs":[{"declarationKey":"rift-triage:main","id":"JOB-1"},{"declarationKey":"rift-pr-gate:main","id":"JOB-2"}]}'
elif [ "$1 $2" = "automations run" ]; then
  printf 'trigger %s\n' "$3" >> "$ACTIONS"
fi
exit 0
SHIM

chmod +x "$TMP"/*
export PATH="$TMP:$PATH" FX ACTIONS RIFT_GH="$TMP/gh"
# Decision-File landet unter $OPENCLAW_STATE_DIR/workspace → im Test in den TMP-Baum lenken.
export OPENCLAW_STATE_DIR="$TMP/state"; mkdir -p "$OPENCLAW_STATE_DIR/workspace"
DECISION="$OPENCLAW_STATE_DIR/workspace/rift-triage-decision.md"

# ── Fixtures ─────────────────────────────────────────────────────────────────
focus()     { printf '%s' "$1" > "$FX/focus"; }
focus_ok()  { focus '{"title":"1.0.1","number":12,"open_issues":7}'; }
nofocus()   { rm -f "$FX/focus"; }
dispatched(){ printf '%s' "$1" > "$FX/dispatched.json"; }
issues()    { printf '%s' "$1" > "$FX/issues.json"; }
milestone_closed() { printf '%s' "$1" > "$FX/issues-closed.json"; }
prs()       { printf '%s' "$1" > "$FX/prs.json"; }
reset()     { : > "$ACTIONS"; focus_ok; dispatched '[]'; issues '[{"number":896,"title":"ci: build parallel","labels":[],"body":""}]'; prs '[]'; milestone_closed '[]'; rm -f "$OPENCLAW_STATE_DIR/workspace/rift-release-requested.stamp"; }

run() { out="$("$SCRIPT" 2>&1)"; rc=$?; }

echo "== Dispatchbar: Trigger =="
reset
run
check "Exit 0" "0" "$rc"
check "Guard lief" "1" "$(grep -c '^guard$' "$ACTIONS")"
check "Cleanup lief" "1" "$(grep -c '^cleanup$' "$ACTIONS")"
check "Agent-Turn getriggert" "trigger JOB-1" "$(grep '^trigger' "$ACTIONS")"
check "Decision-File nennt #896" "1" "$(grep -c 'Issue: #896' "$DECISION" 2>/dev/null || echo 0)"
check "Decision-File schliesst per Closes" "1" "$(grep -c 'Closes #896' "$DECISION" 2>/dev/null || echo 0)"

echo
echo "== Auswahl-Reihenfolge: Checkliste aus der MILESTONE-Beschreibung =="
# Ab jetzt zaehlt die Milestone-Beschreibung (nicht mehr der Epic-Body) — der Runner
# nimmt die Checkliste oben -> unten. Die Nummern-Reihenfolge darf NICHT gewinnen.
focus '{"title":"1.0.1","number":12,"open_issues":7,"description":"- [ ] #900\n- [ ] #896"}'
issues '[{"number":896,"title":"kleinere Nummer","labels":[],"body":""},{"number":900,"title":"groessere Nummer","labels":[],"body":""}]'
run
check "Checkliste schlaegt Nummern-Reihenfolge" "1" "$(grep -c 'Issue: #900' "$DECISION" 2>/dev/null || echo 0)"

# Nicht-Leaf (Epic) an erster Stelle: der naechste Leaf gewinnt.
focus '{"title":"1.0.1","number":12,"open_issues":7,"description":"- [ ] #724\n- [ ] #896"}'
issues '[{"number":724,"title":"[Epic] 1.0.1","labels":[],"body":""},{"number":896,"title":"leaf","labels":[],"body":""}]'
run
check "Epic-Eintrag wird uebersprungen" "1" "$(grep -c 'Issue: #896' "$DECISION" 2>/dev/null || echo 0)"

# Prosa im Milestone-Text darf die Reihenfolge NICHT veraendern: nur Checklisten-Zeilen zaehlen.
focus '{"title":"1.0.1","number":12,"open_issues":7,"description":"Erledigt: #900, #910 - nur Prosa, keine Checkliste."}'
issues '[{"number":896,"title":"leaf","labels":[],"body":""},{"number":900,"title":"nur in Prosa genannt","labels":[],"body":""}]'
run
check "Prosa-#NNN aendert die Reihenfolge nicht (aufsteigend)" "1" "$(grep -c 'Issue: #896' "$DECISION" 2>/dev/null || echo 0)"

# Von einer Checklisten-Zeile zaehlt nur die ERSTE Nummer: ein Klammer-Hinweis darf nicht ziehen.
focus '{"title":"1.0.1","number":12,"open_issues":7,"description":"- [ ] #724 (Epic, siehe #900)\n- [ ] #896"}'
issues '[{"number":724,"title":"[Epic] 1.0.1","labels":[],"body":""},{"number":896,"title":"leaf","labels":[],"body":""},{"number":900,"title":"nur Klammer-Hinweis","labels":[],"body":""}]'
run
check "Klammer-#NNN auf einer Zeile zieht nicht" "1" "$(grep -c 'Issue: #896' "$DECISION" 2>/dev/null || echo 0)"

# Leere Beschreibung -> unveraendert aufsteigende Nummer (Altverhalten).
reset
run
check "ohne Beschreibung: aufsteigend" "1" "$(grep -c 'Issue: #896' "$DECISION" 2>/dev/null || echo 0)"

# Ein `[Release]`-Tracking-Issue ist KEIN Arbeits-Issue: es darf nie dispatcht werden und
# der Milestone gilt weiter als code-complete (sonst wuerde der Release-PR sich selbst blockieren).
reset
issues '[{"number":913,"title":"[Release] 1.0.1 — Solid & schnell","labels":[{"name":"enhancement"}],"body":"Release-Tracking"}]'
: > "$ACTIONS"
run
check "[Release] wird nicht dispatcht" "0" "$(grep -c 'trigger JOB-1' "$ACTIONS")"
check "Milestone gilt trotzdem als code-complete (Gate)" "trigger JOB-2" "$(grep '^trigger' "$ACTIONS")"

# Release ausgeliefert: der Release-PR schliesst das [Release]-Issue. Ist es ZU, darf kein
# zweiter Release anlaufen, solange der Milestone formal noch offen ist (real: #912 gemergt,
# 1.0.1 noch nicht geschlossen).
reset
issues '[{"number":900,"title":"irgendein Alt-Issue","labels":[{"name":"question"}],"body":""}]'
milestone_closed '[{"number":913,"title":"[Release] 1.0.1 — Solid & schnell"}]'
: > "$ACTIONS"
run
check "kein zweiter Release-Trigger" "0" "$(grep -c '^trigger' "$ACTIONS")"
check "Log nennt den ausgelieferten Release" "1" "$(printf '%s' "$out" | grep -c 'Release ausgeliefert')"

echo
echo "== Slot belegt: KEIN Trigger — aber Guard+Cleanup MUESSEN laufen (Schritt-1-Fix) =="
reset
dispatched '[{"number":777}]'
run
check "Exit 0 (Skip)" "0" "$rc"
check "kein Trigger" "0" "$(grep -c '^trigger' "$ACTIONS")"
check "Guard lief trotzdem" "1" "$(grep -c '^guard$' "$ACTIONS")"
check "Cleanup lief trotzdem" "1" "$(grep -c '^cleanup$' "$ACTIONS")"

echo
echo "== Offener Fokus-PR: kein Trigger =="
reset
dispatched '[{"number":900,"title":"fix","body":"Refs #896","headRefName":"fix/x"}]'
run
check "Exit 0 (Skip)" "0" "$rc"
check "kein Trigger" "0" "$(grep -c '^trigger' "$ACTIONS")"

echo
echo "== Guard-Retry (triage:redispatch): offener PR friert den Milestone NICHT ein =="
# Real: PR #905 (roter boot-test) blockierte den kompletten 1.0.1-Fokus. Hat der Stale-Guard
# das Issue für den Retry freigegeben, darf Schritt 5 nicht mehr greifen — und das
# Decision-File muss den bestehenden PR als Arbeitsgrundlage nennen.
reset
issues '[{"number":896,"title":"ci: build parallel","labels":[{"name":"triage:redispatch"}],"body":""}]'
prs '[{"number":900,"title":"fix","body":"Refs #896","headRefName":"fix/x"}]'
run
check "Exit 0" "0" "$rc"
check "Agent-Turn getriggert" "trigger JOB-1" "$(grep '^trigger' "$ACTIONS")"
check "Decision-File nennt #896" "1" "$(grep -c 'Issue: #896' "$DECISION" 2>/dev/null || echo 0)"
check "Decision-File nennt bestehenden PR #900" "1" "$(grep -c 'Bestehender offener PR: #900' "$DECISION" 2>/dev/null || echo 0)"

echo
echo "== Handoff klebrig: triage:implement + orchestrator:dispatched -> Tick raeumt ab =="
# Der Gate gibt nach REQUEST_CHANGES an A zurueck; vergisst er das Abnehmen des
# Dispatch-Labels, bleibt der WIP=1-Slot belegt und A kommt nie ran (real: #909, 3,5 h).
reset
issues '[{"number":909,"title":"[Feature] Parked Solo","labels":[{"name":"triage:implement"},{"name":"orchestrator:dispatched"}],"body":""}]'
prs '[{"number":917,"title":"feat(#909): Parked Solo","body":"Closes #909","headRefName":"feat/909-x"}]'
run
check "Exit 0" "0" "$rc"
check "Handoff-Buchhaltung geloggt" "1" "$(printf '%s' "$out" | grep -c 'Handoff #909')"
check "Retry wird dispatcht" "trigger JOB-1" "$(grep '^trigger' "$ACTIONS")"

echo
echo "== Dispatch belegt den Slot deterministisch + nimmt triage:implement ab =="
# Regression #929: der Tick muss den Slot VOR dem Agent-Turn belegen und `triage:implement`
# abnehmen — sonst nimmt Schritt 2b im naechsten Lauf `orchestrator:dispatched` wieder ab
# (weil triage:implement klebt) und derselbe Rework-Worker wird doppelt gestartet.
reset
issues '[{"number":896,"title":"ci: build parallel","labels":[{"name":"triage:implement"}],"body":""}]'
: > "$ACTIONS"
run
check "Exit 0" "0" "$rc"
check "Agent-Turn getriggert" "trigger JOB-1" "$(grep '^trigger' "$ACTIONS")"
check "Dispatch belegt Slot + nimmt triage:implement ab" "1" \
  "$(grep -c 'issue-edit issue edit 896 .*--add-label orchestrator:dispatched .*--remove-label triage:implement' "$ACTIONS")"
check "Decision-File nennt das eindeutige Worker-Label" "1" \
  "$(grep -c 'Worker-Label: triage-896-' "$DECISION" 2>/dev/null || echo 0)"
# Naechster Tick: das Issue traegt jetzt `orchestrator:dispatched` -> KEIN zweiter Dispatch.
dispatched '[{"number":896}]'
: > "$ACTIONS"
run
check "zweiter Tick dispatcht nicht (Slot belegt)" "0" "$(grep -c '^trigger' "$ACTIONS")"

echo
echo "== Gate-Uebergabe (triage:implement): offener PR blockiert den Retry NICHT =="
# Der Gate gibt nach REQUEST_CHANGES an Runner A zurueck (`orchestrator:dispatched` weg,
# `triage:implement` drauf). Ohne diese Ausnahme in Schritt 5 waere das eine Sackgasse:
# A skippt wegen "offener Fokus-PR" und der Fix passiert nie (real: #301/#915).
reset
issues '[{"number":301,"title":"Retention","labels":[{"name":"triage:implement"}],"body":""}]'
prs '[{"number":915,"title":"feat(deploy): Retention","body":"Closes #301","headRefName":"feat/301-x"}]'
run
check "Retry wird dispatcht" "trigger JOB-1" "$(grep '^trigger' "$ACTIONS")"
check "Decision-File nennt #301" "1" "$(grep -c 'Issue: #301' "$DECISION" 2>/dev/null || echo 0)"
check "Decision-File nennt den bestehenden PR #915" "1" "$(grep -c 'Bestehender offener PR: #915' "$DECISION" 2>/dev/null || echo 0)"

echo
echo "== Bestehender PR: Release-PR ignorieren, echten Feature-PR waehlen (real #951 vs #948) =="
reset
issues '[{"number":930,"title":"Solo-Button","labels":[{"name":"triage:implement"}],"body":""}]'
prs '[{"number":951,"title":"chore(release): v1.0.3","body":"Closes #950\nHinweis: #930 ist nicht in main","headRefName":"release/1.0.3","labels":[{"name":"release:human-merge"}]},{"number":948,"title":"feat(#930): Solo-Button","body":"Closes #930","headRefName":"feat/930-proxy-solo-self-send","labels":[]}]'
run
check "Exit 0" "0" "$rc"
check "Agent-Turn getriggert" "trigger JOB-1" "$(grep '^trigger' "$ACTIONS")"
check "Decision-File nennt #948" "1" "$(grep -c 'Bestehender offener PR: #948' "$DECISION" 2>/dev/null || echo 0)"
check "Release-PR #951 wird NICHT gewaehlt" "0" "$(grep -c 'Bestehender offener PR: #951' "$DECISION" 2>/dev/null || true)"

# Ein Release-PR, der das Issue nur im Prosa nennt, ist kein Arbeits-PR.
reset
issues '[{"number":930,"title":"Solo-Button","labels":[{"name":"triage:implement"}],"body":""}]'
prs '[{"number":951,"title":"chore(release): v1.0.3","body":"siehe #930","headRefName":"release/1.0.3","labels":[{"name":"release:human-merge"}]}]'
run
check "kein bestehender PR aus Prosa-Erwaehnung" "0" "$(grep -c 'Bestehender offener PR' "$DECISION" 2>/dev/null || true)"

echo
echo "== Code-complete (nur Epics/Spikes): Release-PR faellig -> Gate-Turn =="
# Kein Leaf mehr heisst: der Milestone ist CODE-COMPLETE. Die letzte Aufgabe ist der
# Release-PR (Changelog + Abnahme + Testplan) — den baut der GATE, nicht die Triage.
REL="$OPENCLAW_STATE_DIR/workspace/rift-release-decision.md"
reset
issues '[{"number":724,"title":"[Epic] 1.0.1","labels":[],"body":""},{"number":486,"title":"[Spike] X","labels":[{"name":"research"}],"body":""}]'
run
check "Exit 0" "0" "$rc"
check "Gate-Turn getriggert (nicht Triage)" "trigger JOB-2" "$(grep '^trigger' "$ACTIONS")"
check "kein Triage-Trigger" "0" "$(grep -c 'trigger JOB-1' "$ACTIONS")"
check "Release-Decision nennt den Milestone" "1" "$(grep -c 'Milestone: 1.0.1' "$REL" 2>/dev/null || echo 0)"
check "Release-Decision nennt das Tag" "1" "$(grep -c 'Tag-Vorschlag: v1.0.1' "$REL" 2>/dev/null || echo 0)"

# Ein zweiter Tick innerhalb der Sperre darf NICHT erneut triggern (Token-Schutz):
# der Gate-Turn braucht Minuten (Branch + CHANGELOG + PR).
reset
issues '[{"number":724,"title":"[Epic]","labels":[],"body":""}]'
run
check "erster Lauf triggert den Release" "trigger JOB-2" "$(grep '^trigger' "$ACTIONS")"
: > "$ACTIONS"
run
check "zweiter Lauf triggert nicht (Cooldown)" "0" "$(grep -c '^trigger' "$ACTIONS")"
check "Log nennt den Cooldown" "1" "$(printf '%s' "$out" | grep -c 'Release bereits angefragt')"

# Ein laufender Release-PR darf nicht jeden Tick erneut triggern.
reset
issues '[{"number":724,"title":"[Epic]","labels":[],"body":""}]'
prs '[{"number":950,"title":"chore(release): 1.0.1","body":"","headRefName":"release/1.0.1","labels":[{"name":"release:human-merge"}]}]'
run
check "Exit 0 (Release laeuft)" "0" "$rc"
check "kein Trigger, solange der Release-PR laeuft" "0" "$(grep -c '^trigger' "$ACTIONS")"

# R4: der Release-PR blockiert die Arbeit an einem offenen Issue NICHT (sonst friert die
# Endabnahme genau dann alles ein, wenn ein Player-Test einen Retry braucht).
reset
issues '[{"number":896,"title":"leaf","labels":[],"body":""}]'
prs '[{"number":950,"title":"chore(release): 1.0.1","body":"Closes #896","headRefName":"release/1.0.1","labels":[{"name":"release:human-merge"}]}]'
run
check "Release-PR blockiert den Slot nicht" "trigger JOB-1" "$(grep '^trigger' "$ACTIONS")"

echo
echo "== triage:no-action zaehlt als kein Leaf-Kandidat (kein Release-Trigger) =="
reset
issues '[{"number":896,"title":"ci: build parallel","labels":[{"name":"triage:no-action"}],"body":""}]'
run
check "Exit 0 (Skip)" "0" "$rc"
check "kein Release-Trigger (Cleanup laeuft noch)" "0" "$(grep -c '^trigger' "$ACTIONS")"

echo
echo "== Fokus erschoepft: code-complete -> Release faellig, KEIN Dispatch =="
# Real (1.0.2): der Mensch schliesst das letzte Issue; open_issues faellt auf 0, aber es GIBT
# geschlossene Arbeit. Dann ist der Milestone code-complete und der Gate baut den Release-PR —
# der Tick darf hier NICHT "erschöpft" skippen (sonst blieb der Changelog-PR aus).
reset
focus '{"title":"1.0.1","number":12,"open_issues":0,"closed_issues":18}'
issues '[]'
rm -f "$REL"
run
check "Exit 0" "0" "$rc"
check "kein Triage-Trigger" "0" "$(grep -c 'trigger JOB-1' "$ACTIONS")"
check "Gate-Turn getriggert (Release)" "trigger JOB-2" "$(grep '^trigger' "$ACTIONS")"
check "Release-Decision nennt den Milestone" "1" "$(grep -c 'Milestone: 1.0.1' "$REL" 2>/dev/null || echo 0)"

# Ein wirklich leerer Milestone (0 offen UND 0 geschlossen) hat nichts auszuliefern -> Skip.
reset
focus '{"title":"1.0.1","number":12,"open_issues":0,"closed_issues":0}'
issues '[]'
run
check "Exit 0 (Skip)" "0" "$rc"
check "kein Trigger" "0" "$(grep -c '^trigger' "$ACTIONS")"

echo
echo "== Kein Fokus-Milestone: kein Trigger =="
reset; nofocus
run
check "Exit 0 (Skip)" "0" "$rc"
check "kein Trigger" "0" "$(grep -c '^trigger' "$ACTIONS")"

echo
printf '== %d ok, %d fail ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
