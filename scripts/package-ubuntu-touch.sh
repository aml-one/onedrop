#!/usr/bin/env bash
# Package the Linux aarch64 Flutter bundle as Ubuntu Touch tar.gz + install-launcher.
# Run on an arm64 Linux host from the OneDrop repo root after (or instead of)
# scripts/build-onedrop-linux.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/app"
VERSION_FILE="$ROOT/version"
DIST="$PROJECT/dist"

[[ -f "$PROJECT/pubspec.yaml" ]] || { echo "Missing OneDrop project: $PROJECT" >&2; exit 1; }
[[ -f "$VERSION_FILE" ]] || { echo "Missing OneDrop version: $VERSION_FILE" >&2; exit 1; }

SEMVER="$(tr -d '[:space:]' < "$VERSION_FILE")"
BUILD_DATE="$(date -u +%y%m%d)"
LABEL="v$SEMVER-$BUILD_DATE"

ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64) ;;
  *)
    echo "Ubuntu Touch packaging expects aarch64 (got $ARCH)." >&2
    exit 1
    ;;
esac

if [[ ! -x "$PROJECT/build/linux/arm64/release/bundle/onedrop" ]]; then
  bash "$ROOT/scripts/build-onedrop-linux.sh"
fi

BUNDLE="$PROJECT/build/linux/arm64/release/bundle"
mkdir -p "$DIST"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/onedrop"
cp -a "$BUNDLE/." "$STAGE/onedrop/"
install -m 644 "$PROJECT/linux/packaging/one.aml.onedrop.desktop" \
  "$STAGE/onedrop/one.aml.onedrop.desktop"
install -m 644 "$PROJECT/assets/icon/app_icon.png" \
  "$STAGE/onedrop/one.aml.onedrop.png"
install -m 755 "$PROJECT/linux/packaging/install-launcher.sh" \
  "$STAGE/onedrop/install-launcher.sh"
sed -i \
  -e "s|^Exec=.*|Exec=$HOME/apps/OneDrop/onedrop|" \
  -e "s|^Icon=.*|Icon=$HOME/apps/OneDrop/one.aml.onedrop.png|" \
  "$STAGE/onedrop/one.aml.onedrop.desktop"

ARTIFACT="$DIST/onedrop-ubuntu-touch-arm64-$LABEL.tar.gz"
rm -f "$ARTIFACT"
tar -C "$STAGE" -czf "$ARTIFACT" onedrop
echo "OneDrop Ubuntu Touch: $ARTIFACT"
echo "Extract, then ./install-launcher.sh (autostart + drawer)."
