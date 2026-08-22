#!/bin/bash
# Wire the cost dashboard into Caddy + DNS (idempotent).
# Run on .149: ./scripts/cost-serve.sh
set -euo pipefail

CADDYFILE="/home/momo/caddy/Caddyfile"
DOMAINS="/home/momo/home_domains.txt"
DOMAIN="cost.openclaw.simonklimke.de"

# DNS record
grep -qx "$DOMAIN" "$DOMAINS" || echo "$DOMAIN" >> "$DOMAINS"

# Caddy block (idempotent — append only if absent)
if ! grep -q "^$DOMAIN {" "$CADDYFILE"; then
  cp "$CADDYFILE" "$CADDYFILE.bak-cost"
  cat >> "$CADDYFILE" <<'EOF'

cost.openclaw.simonklimke.de {
    reverse_proxy oauth2-proxy-cost:4180
    encode gzip
}

:9092 {
    root * /srv/cost
    file_server
}
EOF
fi

# Reload Caddy
docker exec caddy-caddy-1 caddy reload --config /etc/caddy/Caddyfile
echo "caddy reloaded for $DOMAIN"
