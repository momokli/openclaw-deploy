#!/usr/bin/env bash
# setup-node-exec-allowlist.sh — idempotent exec-approvals allowlist for the
# planet Node host build toolchain (Issue #65).
#
# Why: `exec host=node` runs build/coding tasks on the Node host `planet`.
# The host-local exec approvals document is the enforceable source of truth for
# that host. With the requested policy at `security=full`/`ask=off` nothing is
# gated today, but a tightened `allowlist` policy would refuse every unmatched
# command ("not in the allowlist"). This script pre-seeds the *minimal* set of
# build-toolchain executables so the build agents keep working under
# allowlist policy — without going full YOLO.
#
# Scope: only the executables the coding pipeline actually invokes on planet:
#   git, gh, cargo, rustc, rustup, node, npm
# Nothing else (no shells, no interpreters, no generic `sh -c`). Subprocesses
# spawned *by* those tools (cc/ld/make inside cargo) are not gated by the
# allowlist and therefore do not need entries.
#
# Where to run: on the Gateway host (where `openclaw` targets `--node planet`).
# Node exec approvals are stored in the node's own state DB and can only be
# edited remotely through `openclaw approvals ... --node <id|name|ip>`.
#
# Idempotent: `allowlist add` for an already-present pattern is a no-op, so the
# script is safe to re-run. `--remove` removes the same entries again (rollback).
#
# Usage:
#   ./setup-node-exec-allowlist.sh                 # add (default)
#   ./setup-node-exec-allowlist.sh --remove        # rollback
#   NODE=planet AGENTS="feature-dev-developer" ./setup-node-exec-allowlist.sh
#
# Env overrides:
#   NODE      Node id/name/ip to target           (default: planet)
#   AGENTS    Space-separated agent ids           (default: build pipeline)
#   PATTERNS  Space-separated executable patterns (default: toolchain below)

set -euo pipefail

NODE="${NODE:-planet}"
AGENTS="${AGENTS:-coding-orchestrator feature-dev-planner feature-dev-setup feature-dev-developer feature-dev-verifier feature-dev-tester feature-dev-reviewer}"
PATTERNS="${PATTERNS:-/usr/bin/git /usr/bin/gh /home/momo/.cargo/bin/cargo /home/momo/.cargo/bin/rustc /home/momo/.cargo/bin/rustup /opt/node/bin/node /opt/node/bin/npm}"
ACTION="add"
[ "${1:-}" = "--remove" ] && ACTION="remove"

log()  { echo "[setup-node-exec-allowlist] $*"; }
warn() { echo "[setup-node-exec-allowlist] WARN: $*" >&2; }

if ! command -v openclaw >/dev/null 2>&1; then
    warn "openclaw CLI not found on PATH — run this on the Gateway host"
    exit 1
fi

log "target node: $NODE"
log "action:      $ACTION"
log "agents:      $AGENTS"
log "patterns:    $PATTERNS"
echo

ok=0
fail=0
for agent in $AGENTS; do
    for pattern in $PATTERNS; do
        if openclaw approvals allowlist "$ACTION" --node "$NODE" --agent "$agent" "$pattern" >/dev/null 2>&1; then
            ok=$((ok + 1))
        else
            warn "failed: $ACTION $agent $pattern"
            fail=$((fail + 1))
        fi
    done
done

log "$ACTION done: $ok ok, $fail failed"
echo

# ── Verification ─────────────────────────────────────────────────────
log "verification: openclaw approvals get --node $NODE --json"
if command -v python3 >/dev/null 2>&1; then
    openclaw approvals get --node "$NODE" --json 2>/dev/null \
        | python3 -c 'import json,sys
d = json.load(sys.stdin)
agents = d.get("file", {}).get("agents", {})
total = sum(len(a.get("allowlist", [])) for a in agents.values())
print(f"  agents with entries: {len(agents)}")
print(f"  allowlist entries:   {total}")
for name in sorted(agents):
    pats = sorted(e.get("pattern", "?") for e in agents[name].get("allowlist", []))
    print(f"  - {name}: {len(pats)} entries")'
else
    openclaw approvals get --node "$NODE" 2>/dev/null | tail -n 40
fi

log "done."
