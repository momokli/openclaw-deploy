#!/usr/bin/env bash
# fixtures/naive.sh — der "Vorher"-Zustand aus Issue #27: ein Report wird unveraendert
# als Announce ausgegeben (`cat`). Kein Cap, keine Dedupe. Dient dem red-before-green-
# Nachweis in tests/announce-guard/run.sh --red.
#
# Nutzung: fixtures/naive.sh <report.md>   (oder stdin)
set -uo pipefail
if [ $# -ge 1 ] && [ -n "${1:-}" ]; then
    cat -- "$1"
else
    cat
fi
