#!/usr/bin/env bash
# Ubuntu twin of publish-onedrop.ps1.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
# shellcheck disable=SC1091
source "$here/publish-client.sh"
file="${1:-}"
if [[ -z "$file" ]]; then
  file="$(ls -1t "$root"/app/dist/* 2>/dev/null | head -n 1 || true)"
fi
[[ -n "$file" && -f "$file" ]] || { echo "No artifact. Build first or pass the file path." >&2; exit 1; }
publish_client_release "$file" "onedropWindows"
