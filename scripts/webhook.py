#!/usr/bin/env python3
"""Deploy webhook receiver for OpenClaw.

Listens on port 18791 and, on a POST to /deploy with the correct bearer
token, triggers `openclaw-build.service` (which pulls GHCR + recreates the
container). This is the HTTPS target used by the GitHub Actions workflow
(`.github/workflows/build.yml`) so a push to `main` deploys without waiting
for the 30-minute systemd timer.

The shared secret lives in `/opt/apps/openclaw/webhook-token` (NOT in git);
GitHub holds the same value as the `DEPLOY_TOKEN` repository secret.
"""

import hmac
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN_FILE = "/opt/apps/openclaw/webhook-token"
PORT = 18791


def read_token():
    with open(TOKEN_FILE) as f:
        return f.read().strip()


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/deploy":
            self.send_response(404)
            self.end_headers()
            return
        auth = self.headers.get("Authorization", "").strip()
        if not hmac.compare_digest(auth, "Bearer " + read_token()):
            self.send_response(401)
            self.end_headers()
            return
        subprocess.run(["sudo", "-n", "systemctl", "start", "openclaw-build.service"])
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"status":"triggered"}')

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
