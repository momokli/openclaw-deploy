#!/bin/bash
# fixtures/naive-release-all.sh — Guard-loses Gegenstück zu scripts/rift-stale-dispatch.sh.
#
# Dient NUR dem red-before-green-Nachweis in tests/rift-stale-dispatch/run.sh: es gibt
# jedes Issue mit `orchestrator:dispatched` frei — ohne Stale-Check (Alter/PR/Aktivität/
# Worker-Session) und ohne Loop-Bremse (Zähler/Hard Cap/Cooldown/Lauf-Budget). Genau so
# sähe der „Quick Fix" aus: verlinkte PRs und frische Dispatches werden zerrissen und
# nach 3 Fehlversuchen dreht sich die Schleife unendlich weiter.
set -uo pipefail

R=momokli/riftbreaker-battle-mod
M="${2:-1.0}"

clanker-gh issue list --repo "$R" --state open --milestone "$M" --json number,labels \
  | jq -r '.[] | select(any(.labels[]?; .name == "orchestrator:dispatched")) | .number' \
  | while read -r n; do
      [ -n "$n" ] || continue
      clanker-gh issue edit "$n" --repo "$R" \
        --remove-label orchestrator:dispatched --add-label triage:redispatch >/dev/null 2>&1 || true
      echo "REDISPATCH $n"
    done
