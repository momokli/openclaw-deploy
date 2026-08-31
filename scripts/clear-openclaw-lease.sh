#!/bin/sh
# Clear a stale OpenClaw `startup-migrations` lease from the state SQLite DB.
#
# A gateway that was SIGTERM'd mid-migration leaves this lease behind; it
# blocks the next gateway boot until its ~5 minute TTL expires. Safe to run
# only while the gateway is stopped (writers down) — the lease is re-created
# on the next boot whenever a startup migration actually needs to run.
#
# Idempotent: deleting a non-existent row is a no-op.

set -eu

IMAGE="${OPENCLAW_IMAGE:-ghcr.io/momokli/openclaw-deploy:latest}"

docker run --rm --entrypoint node \
    -v openclaw_home:/home/node/.openclaw \
    "$IMAGE" -e '
        const { DatabaseSync } = require("node:sqlite");
        const db = new DatabaseSync("/home/node/.openclaw/state/openclaw.sqlite");
        const r = db
            .prepare("DELETE FROM state_leases WHERE scope = ? AND lease_key = ?")
            .run("startup-migrations", "global");
        console.log("[clear-openclaw-lease] cleared", r.changes, "startup-migrations lease row(s)");
        db.close();
    '
