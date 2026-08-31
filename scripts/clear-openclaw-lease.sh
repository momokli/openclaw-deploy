#!/bin/sh
# Clear stale OpenClaw locks from the state dir so migrations + the next
# gateway boot can proceed.
#
# Two independent stale-lock mechanisms bite after a gateway is SIGTERM'd:
#   1. `state_leases` row (scope='startup-migrations', lease_key='global') —
#      blocks the gateway boot until its ~5 min TTL expires.
#   2. `tmp/openclaw-1000/gateway.*.lock*` SQLite lock files — make
#      `openclaw doctor --fix` skip its "exclusive state ownership" migrations
#      (session store, workspace state, agent memory schema) with
#      "the Gateway or another SQLite maintenance command owns this state".
#
# Safe to run ONLY while the gateway is stopped (writers down); both locks are
# re-created on demand. Idempotent: clearing missing rows/files is a no-op.

set -eu

IMAGE="${OPENCLAW_IMAGE:-ghcr.io/momokli/openclaw-deploy:latest}"

docker run --rm --entrypoint node \
    -v openclaw_home:/home/node/.openclaw \
    "$IMAGE" -e '
        const { DatabaseSync } = require("node:sqlite");
        const fs = require("node:fs");
        const path = require("node:path");

        const db = new DatabaseSync("/home/node/.openclaw/state/openclaw.sqlite");
        const r = db
            .prepare("DELETE FROM state_leases WHERE scope = ? AND lease_key = ?")
            .run("startup-migrations", "global");
        console.log("[clear-openclaw-lease] cleared", r.changes, "startup-migrations lease row(s)");
        db.close();

        const lockDir = "/home/node/.openclaw/tmp/openclaw-1000";
        if (fs.existsSync(lockDir)) {
            let removed = 0;
            for (const name of fs.readdirSync(lockDir)) {
                if (/\.lock(\.sqlite(-\w+)?)?$/i.test(name) || name.includes("lock")) {
                    fs.rmSync(path.join(lockDir, name), { force: true });
                    removed++;
                }
            }
            console.log("[clear-openclaw-lease] removed", removed, "stale lock file(s)");
        }
    '
