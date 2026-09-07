#!/usr/bin/env bash
set -euo pipefail
eval "$("$HOME/homebrew/bin/brew" shellenv)"
LIMA_NAME="${ONEDROP_LIMA_NAME:-${MESSAGEME_LIMA_NAME:-messageme-ut}}"
REPO_DIR="${ONEDROP_REPO_DIR:-$HOME/src/onedrop-ut-current}"
PRODUCT="${1:-ubuntu-touch}"

if [[ "$PRODUCT" != "ubuntu-touch" ]]; then
  echo "Supported product: ubuntu-touch (got: $PRODUCT)" >&2
  exit 1
fi

if ! limactl list | awk -v n="$LIMA_NAME" '$1==n && $2=="Running"{found=1} END{exit !found}'; then
  limactl start --yes "$LIMA_NAME"
fi

if grep -RIl $'\r' --include='*.sh' "$REPO_DIR/scripts" >/dev/null 2>&1; then
  echo "ERROR: CRLF found under $REPO_DIR/scripts — re-sync after stripping CR." >&2
  exit 1
fi

limactl shell "$LIMA_NAME" -- bash -lc \
  "set -euo pipefail; export PATH=\"\$HOME/flutter/bin:\$PATH\"; cd \"$REPO_DIR\"; sed -i 's/\r\$//' scripts/package-ubuntu-touch.sh scripts/build-onedrop-linux.sh; bash scripts/package-ubuntu-touch.sh; ls -lh app/dist/onedrop-ubuntu-touch-*.tar.gz 2>/dev/null | tail -5"
