#!/usr/bin/env bash
# Upload helper. Keep in step with publish-lib.ps1.
set -euo pipefail
PUBLISH_SSH_TARGET="ambrus@frankfurt.aml.one"
PUBLISH_SSH_PORT="717"
PUBLISH_REMOTE_DIR="/home/ambrus/www/aml/onedrop.aml.one/downloads"
_pc_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
publish_client_release() {
  local file="$1" platform="$2"
  local remote="${3:-$PUBLISH_REMOTE_DIR}"
  local target="${4:-${PUBLISH_SSH_TARGET}}"
  local port="${5:-${PUBLISH_SSH_PORT:-717}}"
  [[ -f "$file" ]] || { echo "File not found: $file" >&2; return 1; }
  local py="$_pc_root/scripts/release-manifest.py"
  [[ -f "$py" ]] || { echo "Missing $py" >&2; return 1; }
  local name size sha tmp
  name="$(basename "$file")"
  size="$(wc -c < "$file" | tr -d ' ')"
  sha="$(sha256sum "$file" | awk '{print $1}')"
  tmp="$(mktemp)"
  python3 - "$tmp" "$platform" "$name" "$size" "$sha" <<'PY'
import json, re, sys
path, platform, name, size, sha = sys.argv[1:]
m = re.search(r"v(\d+\.\d+\.\d+)", name)
version = m.group(1) if m else "0.0.0"
bm = re.search(r"-(\d{6})(?:\.[A-Za-z0-9]+)?$", name)
build = int(bm.group(1)) if bm else 0
json.dump({
    "platform": platform,
    "version": version,
    "buildNumber": build,
    "label": version,
    "file": name,
    "sizeBytes": int(size),
    "sha256": sha,
}, open(path, "w", encoding="utf-8"))
PY
  echo "Uploading $name -> ${target}:$remote (port $port)"
  ssh -p "$port" -o StrictHostKeyChecking=accept-new "$target" "mkdir -p '$remote'"
  scp -P "$port" -o StrictHostKeyChecking=accept-new "$file" "${target}:${remote}/$name"
  scp -P "$port" -o StrictHostKeyChecking=accept-new "$py" "${target}:/tmp/aml-release-manifest.py"
  scp -P "$port" -o StrictHostKeyChecking=accept-new "$tmp" "${target}:/tmp/aml-release-entry.json"
  ssh -p "$port" -o StrictHostKeyChecking=accept-new "$target" \
    "python3 /tmp/aml-release-manifest.py merge '$remote' /tmp/aml-release-entry.json && python3 /tmp/aml-release-manifest.py validate '$remote'"
  mkdir -p "$_pc_root/data/releases"
  python3 "$py" merge "$_pc_root/data/releases" "$tmp"
  rm -f "$tmp"
  echo "Published $platform $name"
}
