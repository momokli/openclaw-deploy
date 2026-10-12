#!/bin/bash
# Kompatibilitäts-Shim: die Engine heißt jetzt `runner-pr-gate-tick.sh`.
# Die laufenden `--command`-Payloads der Ticks rufen noch die alten Bare-Namen
# auf; dieses Shim hält sie bis zum nächsten `automations-apply` am Leben.
set -euo pipefail
exec "$(dirname "$0")/runner-pr-gate-tick.sh" "$@"
