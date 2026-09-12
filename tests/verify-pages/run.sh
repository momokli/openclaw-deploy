#!/usr/bin/env bash
# Offline harness for scripts/verify-pages.sh.
#
# Pure bash + a stubbed `gh`/`curl` on PATH — no network, no real GitHub calls.
# Scenarios drive `repos/<owner>/<repo>/pages/builds/latest` responses and assert
# the exit code + key log lines of the verifier.
#
# Usage:
#   tests/verify-pages/run.sh            # green run against the real script
#   tests/verify-pages/run.sh --red      # red-before-green proof (pre-fix script fails)

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="${VERIFY_PAGES_SCRIPT:-$REPO_ROOT/scripts/verify-pages.sh}"
MODE="${1:-}"

PASS=0
FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

# make_stub <dir> — writes a `gh` + `curl` stub into <dir>/bin.
#   gh   : emits the next line of $VP_STATE/responses (status<TAB>created<TAB>commit);
#          the line `404` emits `HTTP 404` on stderr; `ERROR` emits a generic error.
#   curl : emits $VP_CURL_CODE (default 200) on stdout as the HTTP status.
make_stub() {
    mkdir -p "$1/bin"
    cat >"$1/bin/gh" <<'STUB'
#!/usr/bin/env bash
STATE="${VP_STATE:?}"
n=0
[ -f "$STATE/counter" ] && n="$(cat "$STATE/counter")"
n=$((n + 1))
echo "$n" >"$STATE/counter"
line="$(sed -n "${n}p" "$STATE/responses")"
[ -z "$line" ] && line="$(tail -n1 "$STATE/responses")"
case "$line" in
    404)   echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
    ERROR) echo "gh: server error" >&2; exit 1 ;;
esac
IFS=$'\t' read -r st cr co <<<"$line"
printf '%s\t%s\t%s\n' "$st" "$cr" "$co"
STUB
    cat >"$1/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Ignore args; emit the configured HTTP status code (curl -w '%{http_code}').
echo "${VP_CURL_CODE:-200}"
STUB
    chmod +x "$1/bin/gh" "$1/bin/curl"
}

# run_case <name> <expected-exit> <expect|-> <responses-file-content> -- <args...>
run_case() {
    local name="$1" expected="$2" expect_substr="$3" responses="$4"; shift 4
    [ "$1" = "--" ] && shift
    local dir="$TMPROOT/$name"
    mkdir -p "$dir"
    printf '%b' "$responses" >"$dir/responses"
    make_stub "$dir"
    local out rc
    out="$(VP_STATE="$dir" VP_CURL_CODE="${CASE_CURL_CODE:-200}" PATH="$dir/bin:$PATH" "$SCRIPT" "$@" 2>&1)"
    rc=$?
    if [ "$rc" != "$expected" ]; then
        bad "$name: exit $rc, expected $expected"; printf '%s\n' "$out" | sed 's/^/       /'
        return
    fi
    if [ "$expect_substr" != "-" ] && ! printf '%s' "$out" | grep -qF "$expect_substr"; then
        bad "$name: output missing '$expect_substr'"; printf '%s\n' "$out" | sed 's/^/       /'
        return
    fi
    ok "$name (exit $rc)"
}

COMMON_FAST=(--interval 1 --max-interval 1 --timeout 8)

# NOTE: baseline fetch consumes response line 1; the loop consumes the rest.
# Lines are `status<TAB>created_at<TAB>commit`.

if [ "$MODE" = "--red" ]; then
    echo "== red-before-green: pre-fix ad-hoc script (expected to FAIL) =="
    PRE="$REPO_ROOT/tests/verify-pages/fixtures/pre-fix.sh"
    [ -x "$PRE" ] || { echo "  FAIL pre-fix fixture missing: $PRE"; exit 1; }
    local_red=0
    # stale-built must be rejected (exit 1); pre-fix always exits 0.
    for pair in "stale_built 1" "errored 2"; do
        name="${pair%% *}"; expected="${pair##* }"
        dir="$TMPROOT/red-$name"; mkdir -p "$dir"
        if [ "$name" = "stale_built" ]; then
            printf '%b' "built\t2026-09-01T10:00:00Z\taaa\nbuilt\t2026-09-01T10:00:00Z\taaa\n" >"$dir/responses"
        else
            printf '%b' "built\t2026-09-01T10:00:00Z\taaa\nerrored\t2026-09-01T10:05:00Z\tbbb\n" >"$dir/responses"
        fi
        make_stub "$dir"
        out="$(VP_STATE="$dir" PATH="$dir/bin:$PATH" "$PRE" momokli/example "${COMMON_FAST[@]}" 2>&1)"; rc=$?
        if [ "$rc" = "$expected" ]; then
            bad "red:$name — pre-fix unexpectedly returned $rc"
        else
            printf '  red  %s: pre-fix exit %s (expected %s) → red confirmed\n' "$name" "$rc" "$expected"
            local_red=$((local_red + 1))
        fi
    done
    echo "== red proof: $local_red/2 signature scenarios fail on the pre-fix script =="
    [ "$local_red" = 2 ] && { echo "RED OK"; exit 0; }
    echo "RED INCOMPLETE"; exit 1
fi

echo "== tests/verify-pages/run.sh — script: $SCRIPT =="
[ -x "$SCRIPT" ] || { echo "  FAIL verifier not executable: $SCRIPT"; exit 1; }

run_case green_queued_building_built 0 "Pages deploy verified" \
"built\t2026-09-01T10:00:00Z\taaa\nqueued\t2026-09-01T10:05:00Z\tbbb\nbuilding\t2026-09-01T10:05:10Z\tbbb\nbuilt\t2026-09-01T10:05:20Z\tbbb\n" \
    -- momokli/example "${COMMON_FAST[@]}"

run_case errored 2 "Pages build errored" \
"built\t2026-09-01T10:00:00Z\taaa\nerrored\t2026-09-01T10:05:00Z\tbbb\n" \
    -- momokli/example "${COMMON_FAST[@]}"

run_case stale_built_rejected 1 "did not reach 'built'" \
"built\t2026-09-01T10:00:00Z\taaa\nbuilt\t2026-09-01T10:00:00Z\taaa\n" \
    -- momokli/example --interval 1 --max-interval 1 --timeout 2

run_case pages_enabled_late 0 "Pages deploy verified" \
"404\n404\nbuilt\t2026-09-01T10:05:00Z\tbbb\n" \
    -- momokli/example "${COMMON_FAST[@]}"

run_case pages_never_enabled 3 "is Pages enabled" \
"404\n404\n" \
    -- momokli/example --interval 1 --max-interval 1 --timeout 2

run_case commit_match 0 "Pages deploy verified" \
"built\t2026-09-01T10:05:00Z\tbbb123\n" \
    -- momokli/example --no-baseline --commit bbb "${COMMON_FAST[@]}"

run_case commit_mismatch 1 "did not reach 'built'" \
"built\t2026-09-01T10:05:00Z\taaa123\n" \
    -- momokli/example --no-baseline --commit bbb --interval 1 --max-interval 1 --timeout 2

run_case url_ok 0 "HTTP 200" \
"built\t2026-09-01T10:05:00Z\tbbb\n" \
    -- momokli/example --no-baseline --url https://momokli.github.io/example/ "${COMMON_FAST[@]}"

CASE_CURL_CODE=500 run_case url_not_ready 5 "returned HTTP 500" \
"built\t2026-09-01T10:05:00Z\tbbb\n" \
    -- momokli/example --no-baseline --url https://momokli.github.io/example/ "${COMMON_FAST[@]}"

# usage errors (no gh/state needed)
out="$( "$SCRIPT" 2>&1 )"; rc=$?
if [ "$rc" = 4 ]; then ok "usage_missing_repo (exit 4)"; else bad "usage_missing_repo: exit $rc, expected 4"; fi
out="$( "$SCRIPT" momokli/example --bogus 2>&1 )"; rc=$?
if [ "$rc" = 4 ]; then ok "usage_unknown_option (exit 4)"; else bad "usage_unknown_option: exit $rc, expected 4"; fi

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" = 0 ] && { echo "GREEN OK"; exit 0; }
exit 1
