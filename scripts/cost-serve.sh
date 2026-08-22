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
    basicauth {
        momo $2a$14$kEu6v5eiSns8Y4TSiBW47OYZC5B/1c5sJHIQXFwvXe.4UDa2VxNHW
    }
    root * /srv/cost
    file_server
    encode gzip
}
EOF
fi

# Reload Caddy
docker exec caddy-caddy-1 caddy reload --config /etc/caddy/Caddyfile
echo "caddy reloaded for $DOMAIN"
