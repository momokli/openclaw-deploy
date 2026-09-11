#!/usr/bin/env bash
# Pre-fix ad-hoc Pages verification (kept only to prove red-before-green).
#
# This emulates the fragile `sleep + curl | grep` pattern that Issue #36
# replaces: it always "succeeds" and never inspects the build status API, so it
# cannot detect an errored build or a stale (previous) `built` build.
#
# Usage: fixtures/pre-fix.sh <owner/repo> [ignored options...]
set -uo pipefail

REPO="${1:-}"
URL="https://${REPO%%/*}.github.io/${REPO##*/}/"

sleep 1
curl -s "$URL" | grep -q "html" || true
exit 0
