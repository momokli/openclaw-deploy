#!/usr/bin/env bash
# verify-pages.sh — wait for a GitHub Pages build via the Pages Builds API.
#
# Replaces ad-hoc `sleep 20; curl -s | grep` loops with a deterministic API
# poll of `repos/{owner}/{repo}/pages/builds/latest`, with timeout + backoff.
# See workspace/skills/deploy-status/SKILL.md ("Pages-Deploy verifizieren").
#
# Usage:
#   scripts/verify-pages.sh <owner/repo> [options]
#
# Options:
#   --since <iso8601>    Only accept a build created at/after this UTC timestamp.
#                        Default: created_at of the current latest build
#                        (stale-guard: the previous build is often already `built`).
#   --commit <sha>       Only accept a build whose commit matches <sha> (prefix ok).
#                        Strongest signal — use the SHA you just pushed.
#   --no-baseline        Accept the current latest build even if it is not newer.
#   --rename-wait <s>    Sleep <s> before the first check (CDN invalidation after a
#                        repo rename; 20s is a good default there).
#   --url <url>          After `built`, also require HTTP 200 from this URL.
#   --timeout <s>        Overall budget in seconds (default 300).
#   --interval <s>       Initial poll interval in seconds (default 5).
#   --max-interval <s>   Backoff cap in seconds (default 30).
#   --quiet              Only print the final result.
#   -h | --help
#
# Exit codes:
#   0  built (and --url reachable, if given)
#   1  timeout — build still queued/building
#   2  build errored or cancelled
#   3  Pages not enabled / no build observed within timeout (HTTP 404)
#   4  usage error or missing tooling (`gh`)
#   5  built, but --url did not return HTTP 200 within the budget

set -uo pipefail

usage() { sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; }

REPO=""
SINCE=""
COMMIT=""
NO_BASELINE=0
RENAME_WAIT=0
URL=""
TIMEOUT=300
INTERVAL=5
MAX_INTERVAL=30
QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --since)        SINCE="${2:-}"; shift 2 ;;
        --commit)       COMMIT="${2:-}"; shift 2 ;;
        --no-baseline)  NO_BASELINE=1; shift ;;
        --rename-wait)  RENAME_WAIT="${2:-}"; shift 2 ;;
        --url)          URL="${2:-}"; shift 2 ;;
        --timeout)      TIMEOUT="${2:-}"; shift 2 ;;
        --interval)     INTERVAL="${2:-}"; shift 2 ;;
        --max-interval) MAX_INTERVAL="${2:-}"; shift 2 ;;
        --quiet)        QUIET=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        -*)             echo "verify-pages: unknown option: $1" >&2; usage >&2; exit 4 ;;
        *)              if [ -z "$REPO" ]; then REPO="$1"; shift; else
                            echo "verify-pages: unexpected argument: $1" >&2; usage >&2; exit 4
                        fi ;;
    esac
done

[ -n "$REPO" ] || { echo "verify-pages: <owner/repo> required" >&2; usage >&2; exit 4; }
case "$REPO" in */*) : ;; *) echo "verify-pages: <owner/repo> must contain a slash" >&2; exit 4 ;; esac
for n in TIMEOUT INTERVAL MAX_INTERVAL RENAME_WAIT; do
    case "$n" in
        TIMEOUT)      v="$TIMEOUT" ;;
        INTERVAL)     v="$INTERVAL" ;;
        MAX_INTERVAL) v="$MAX_INTERVAL" ;;
        RENAME_WAIT)  v="$RENAME_WAIT" ;;
    esac
    case "$v" in ''|*[!0-9]*) echo "verify-pages: $n must be an integer (got '$v')" >&2; exit 4 ;; esac
done

command -v gh >/dev/null 2>&1 || { echo "verify-pages: 'gh' not found in PATH" >&2; exit 4; }

log() { [ "$QUIET" = 1 ] || echo "[verify-pages $(date -u +%H:%M:%S)] $*"; }
fail() { echo "verify-pages: $*" >&2; }

EP="repos/$REPO/pages/builds/latest"
ERRFILE="$(mktemp)"
trap 'rm -f "$ERRFILE"' EXIT

# Fetch the latest build. Sets STATUS / CREATED / COMMIT; returns:
#   0  ok (fields set)
#   2  HTTP 404 — Pages not enabled / no build yet
#   3  other API error (message on stderr)
fetch_latest() {
    local out
    if out="$(gh api "$EP" --jq '"\(.status)\t\(.created_at // "")\t\(.commit // "")"' 2>"$ERRFILE")"; then
        read -r STATUS CREATED COMMIT_SHA <<<"$out"
        return 0
    fi
    if grep -q "HTTP 404" "$ERRFILE"; then return 2; fi
    if grep -qE "HTTP 401|HTTP 403|authentication|gh auth login" "$ERRFILE"; then
        fail "GitHub auth failed (run 'gh auth status'): $(tr '\n' ' ' <"$ERRFILE")"
        return 4
    fi
    fail "gh api error: $(tr '\n' ' ' <"$ERRFILE")"
    return 3
}

# ISO-8601 UTC timestamps (YYYY-MM-DDTHH:MM:SSZ) compare correctly as strings.
newer_or_equal() { [ -z "$1" ] && return 0; [ "$2" \> "$1" ] || [ "$2" = "$1" ]; }
newer() { [ -n "$1" ] && [ "$2" \> "$1" ]; }

# ── Optional rename/CDN grace period ────────────────────────────
if [ "$RENAME_WAIT" -gt 0 ]; then
    log "rename/CDN wait ${RENAME_WAIT}s before first check"
    sleep "$RENAME_WAIT"
fi

# ── Stale-guard baseline ────────────────────────────────────────
SINCE_STRICT=0
if [ "$NO_BASELINE" = 0 ] && [ -z "$SINCE" ] && [ -z "$COMMIT" ]; then
    if fetch_latest; then
        SINCE="$CREATED"
        SINCE_STRICT=1
        log "baseline: current latest build created_at=$SINCE (must be newer)"
    else
        log "no current Pages build yet — accepting the first 'built'"
    fi
fi
if [ -n "$SINCE" ]; then
    if [ "$SINCE_STRICT" = 1 ]; then log "accepting builds strictly newer than: $SINCE"
    else log "accepting builds since: $SINCE"; fi
fi
[ -n "$COMMIT" ] && log "accepting commit: $COMMIT"

START="$(date +%s)"
LAST_404=0

while :; do
    fetch_latest
    rc=$?

    if [ "$rc" = 4 ]; then exit 4; fi
    if [ "$rc" = 2 ]; then
        LAST_404=1
        log "Pages build not found (HTTP 404) — waiting"
    elif [ "$rc" = 3 ]; then
        log "transient API error — waiting"
    else
        LAST_404=0
        if [ "$STATUS" = "errored" ] || [ "$STATUS" = "cancelled" ]; then
            fail "Pages build $STATUS (commit=${COMMIT_SHA:-?})"
            exit 2
        fi
        if [ "$STATUS" = "built" ]; then
            ok=1
            if [ -n "$SINCE" ]; then
                if [ "$SINCE_STRICT" = 1 ]; then newer "$SINCE" "$CREATED" || ok=0
                else newer_or_equal "$SINCE" "$CREATED" || ok=0; fi
            fi
            if [ -n "$COMMIT" ] && [ "${COMMIT_SHA#"$COMMIT"}" = "$COMMIT_SHA" ]; then ok=0; fi
            if [ "$ok" = 1 ]; then
                log "Pages build built (commit=${COMMIT_SHA:-?}, created=$CREATED)"
                break
            fi
            log "status=built but for an older build (created=$CREATED, want >$SINCE${COMMIT:+ / commit $COMMIT}) — waiting"
        else
            log "status=$STATUS (commit=${COMMIT_SHA:-?}, created=$CREATED) — waiting"
        fi
    fi

    ELAPSED=$(( $(date +%s) - START ))
    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        if [ "$LAST_404" = 1 ]; then
            fail "timeout after ${ELAPSED}s: no Pages build found (HTTP 404) — is Pages enabled for $REPO?"
            exit 3
        fi
        fail "timeout after ${ELAPSED}s: build did not reach 'built'"
        exit 1
    fi

    sleep "$INTERVAL"
    INTERVAL=$(( INTERVAL * 2 ))
    [ "$INTERVAL" -gt "$MAX_INTERVAL" ] && INTERVAL="$MAX_INTERVAL"
done

# ── Optional live-URL check (CDN may lag behind the build status) ──
if [ -n "$URL" ]; then
    command -v curl >/dev/null 2>&1 || { fail "'curl' not found (needed for --url)"; exit 4; }
    while :; do
        code="$(curl -s -o /dev/null -w '%{http_code}' "$URL" || echo 000)"
        if [ "$code" = "200" ]; then
            log "$URL → HTTP 200"
            break
        fi
        ELAPSED=$(( $(date +%s) - START ))
        if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
            fail "built, but $URL returned HTTP $code within ${ELAPSED}s"
            exit 5
        fi
        log "$URL → HTTP $code — waiting (CDN)"
        sleep "$INTERVAL"
        INTERVAL=$(( INTERVAL * 2 ))
        [ "$INTERVAL" -gt "$MAX_INTERVAL" ] && INTERVAL="$MAX_INTERVAL"
    done
fi

log "OK: Pages deploy verified for $REPO"
exit 0
