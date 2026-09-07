#!/bin/bash
# Install/refresh onedrop.aml.one Caddy site block (downloads only).
set -euo pipefail

CADDYFILE=/etc/caddy/Caddyfile
BLOCK='onedrop.aml.one {
	encode zstd gzip

	handle /downloads* {
		root * /var/www/aml/onedrop.aml.one
		file_server
		header Cache-Control "public, max-age=300"
		@manifest path /downloads/version.json /downloads/releases.json
		header @manifest Cache-Control "no-cache"
	}

	handle {
		redir https://aml.one 302
	}

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "DENY"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	request_body {
		max_size 90MB
	}
}
'

python3 - <<PY
from pathlib import Path
import re
p = Path("$CADDYFILE")
text = p.read_text() if p.exists() else ""
block = """$BLOCK"""
text2, n = re.subn(
    r"\n?onedrop\.aml\.one \{[\s\S]*?\n\}\n?",
    "\n" + block.strip() + "\n",
    text,
    count=1,
)
if n == 0:
    text2 = text.rstrip() + "\n\n" + block.strip() + "\n"
    print("Adding onedrop.aml.one block to $CADDYFILE")
else:
    print("Refreshing onedrop.aml.one block in $CADDYFILE")
p.write_text(text2)
PY

caddy adapt --config "$CADDYFILE" --adapter caddyfile > /tmp/caddy-config-onedrop.json
code=$(curl -sS -o /tmp/caddy-load-onedrop.out -w "%{http_code}" -X POST "http://127.0.0.1:2019/load" \
  -H "Content-Type: application/json" \
  --data-binary @/tmp/caddy-config-onedrop.json || echo "000")
echo "Caddy admin load HTTP $code"
if [ "$code" != "200" ]; then
  cat /tmp/caddy-load-onedrop.out 2>/dev/null >&2 || true
  if sudo -n systemctl reload caddy 2>/dev/null; then
    echo "Fell back to sudo systemctl reload caddy"
  elif systemctl reload caddy 2>/dev/null; then
    echo "Reloaded via systemctl"
  else
    echo "ERROR: could not reload Caddy" >&2
    exit 1
  fi
fi
rm -f /tmp/caddy-config-onedrop.json /tmp/caddy-load-onedrop.out
echo "Caddy reloaded OK for onedrop.aml.one"
