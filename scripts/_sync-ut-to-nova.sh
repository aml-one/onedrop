#!/usr/bin/env bash
set -euo pipefail
HOST="${ONEDROP_UT_HOST:-ambrus@192.168.31.230}"
DEST="${ONEDROP_UT_DEST:-/Users/ambrus/src/onedrop-ut-current}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if grep -RIl $'\r' --include='*.sh' "$ROOT/scripts" >/dev/null 2>&1; then
  echo "ERROR: CRLF in local .sh files — strip CR before sync." >&2
  grep -RIl $'\r' --include='*.sh' "$ROOT/scripts" >&2 || true
  exit 1
fi

AML_UI="$(cd "$ROOT/../global-assets/packages/aml_ui" && pwd)"
[[ -f "$AML_UI/pubspec.yaml" ]] || { echo "Missing aml_ui at $AML_UI" >&2; exit 1; }
GLOBAL_PACKAGES="$(dirname "$DEST")/global-assets/packages"

ssh -o StrictHostKeyChecking=accept-new "$HOST" "mkdir -p '$DEST' '$GLOBAL_PACKAGES'"

rsync -az --delete --info=progress2 \
  --exclude '.dart_tool' \
  --exclude 'build' \
  "$AML_UI/" "${HOST}:${GLOBAL_PACKAGES}/aml_ui/"

rsync -az --delete --info=progress2 \
  --exclude '.git' \
  --exclude '.dart_tool' \
  --exclude 'build' \
  --exclude 'dist' \
  --exclude 'android/.gradle' \
  --exclude 'android/app/build' \
  --exclude 'linux/flutter/ephemeral' \
  --exclude 'macos/Flutter/ephemeral' \
  --exclude 'windows/flutter/ephemeral' \
  --exclude 'ios' \
  "$ROOT/app" "$ROOT/packages" "$ROOT/scripts" "$ROOT/version" "$ROOT/changelog" \
  "${HOST}:${DEST}/"

ssh -o StrictHostKeyChecking=accept-new "$HOST" \
  "find '$DEST/scripts' -name '*.sh' -print0 2>/dev/null | xargs -0 sed -i '' -e 's/\r$//' 2>/dev/null || true; cat '$DEST/version'"

echo "Synced to ${HOST}:${DEST}"
