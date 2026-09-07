#!/usr/bin/env bash
# Run on a Linux Flutter host from the OneDrop repo root.
# Builds One Drop (tray LAN client) and packs a relocatable tarball + .desktop.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/app"
VERSION_FILE="$ROOT/version"
DIST="$PROJECT/dist"

[[ "$(uname -s)" == "Linux" ]] || { echo "One Drop Linux builds require Linux." >&2; exit 1; }
[[ -f "$PROJECT/pubspec.yaml" ]] || { echo "Missing One Drop project: $PROJECT" >&2; exit 1; }
[[ -f "$VERSION_FILE" ]] || { echo "Missing OneDrop version: $VERSION_FILE" >&2; exit 1; }

export PATH="${HOME}/flutter/bin:${PATH}"
command -v flutter >/dev/null || { echo "flutter not found on PATH." >&2; exit 1; }
command -v cmake >/dev/null || { echo "cmake not found (install build-essential / clang / cmake / ninja / gtk)." >&2; exit 1; }
# tray_manager needs Ayatana AppIndicator headers on Linux.
if ! pkg-config --exists ayatana-appindicator3-0.1 && ! pkg-config --exists appindicator3-0.1; then
  echo "Missing AppIndicator (tray_manager). On Ubuntu: sudo apt install libayatana-appindicator3-dev" >&2
  exit 1
fi

SEMVER="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ "$SEMVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid OneDrop semver: $SEMVER" >&2; exit 1; }
IFS=. read -r MAJOR MINOR PATCH <<< "$SEMVER"
BUILD_NUMBER=$((10#$MAJOR * 10000 + 10#$MINOR * 100 + 10#$PATCH))
BUILD_DATE="$(date -u +%y%m%d)"
LABEL="v$SEMVER-$BUILD_DATE"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH_SLUG=x64 ;;
  aarch64|arm64) ARCH_SLUG=arm64 ;;
  *) ARCH_SLUG="$ARCH" ;;
esac

cd "$PROJECT"
flutter pub get
flutter build linux --release \
  --build-name "$SEMVER" \
  --build-number "$BUILD_NUMBER" \
  --dart-define="APP_VERSION=$SEMVER" \
  --dart-define="APP_BUILD_DATE=$BUILD_DATE"

BUNDLE="$PROJECT/build/linux/$ARCH_SLUG/release/bundle"
[[ -d "$BUNDLE" ]] || { echo "Missing Flutter Linux bundle: $BUNDLE" >&2; exit 1; }
[[ -x "$BUNDLE/onedrop" ]] || { echo "Missing onedrop binary in $BUNDLE" >&2; exit 1; }

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

# Rewrite Exec/Icon for a relocatable install next to the binary.
sed -i \
  -e "s|^Exec=.*|Exec=/usr/local/lib/onedrop/onedrop|" \
  -e "s|^Icon=.*|Icon=/usr/local/lib/onedrop/one.aml.onedrop.png|" \
  "$STAGE/onedrop/one.aml.onedrop.desktop"

ARTIFACT="$DIST/onedrop-linux-$ARCH_SLUG-$LABEL.tar.gz"
rm -f "$ARTIFACT"
tar -C "$STAGE" -czf "$ARTIFACT" onedrop
echo "One Drop Linux ($ARCH_SLUG): $ARTIFACT"
echo "Install hint: extract, then ./install-launcher.sh (drawer + autostart)."

if [[ "$ARCH_SLUG" == "x64" ]]; then
  command -v dpkg-deb >/dev/null || { echo "dpkg-deb not found; install dpkg-dev to emit the .deb." >&2; exit 1; }
  DEB_ROOT="$(mktemp -d)"
  mkdir -p \
    "$DEB_ROOT/DEBIAN" \
    "$DEB_ROOT/usr/lib/onedrop" \
    "$DEB_ROOT/usr/bin" \
    "$DEB_ROOT/usr/share/applications" \
    "$DEB_ROOT/usr/share/icons/hicolor/256x256/apps"
  cp -a "$BUNDLE/." "$DEB_ROOT/usr/lib/onedrop/"
  ln -s /usr/lib/onedrop/onedrop "$DEB_ROOT/usr/bin/onedrop"
  install -m 644 "$PROJECT/assets/icon/app_icon.png" \
    "$DEB_ROOT/usr/share/icons/hicolor/256x256/apps/one.aml.onedrop.png"
  cat > "$DEB_ROOT/usr/share/applications/one.aml.onedrop.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=One Drop
GenericName=File transfer
Comment=Send and receive files over the same Wi-Fi
Exec=/usr/lib/onedrop/onedrop
Icon=one.aml.onedrop
Terminal=false
Categories=Network;FileTransfer;
StartupNotify=false
X-GNOME-Autostart-enabled=true
StartupWMClass=onedrop
EOF
  cat > "$DEB_ROOT/DEBIAN/control" <<EOF
Package: onedrop
Version: $SEMVER
Section: net
Priority: optional
Architecture: amd64
Maintainer: AmL <hello@aml.one>
Depends: libgtk-3-0, libayatana-appindicator3-1 | libappindicator3-1
Description: OneDrop — send files nearby over Wi-Fi
Homepage: https://aml.one
EOF
  chmod 644 "$DEB_ROOT/DEBIAN/control"
  DEB="$DIST/onedrop-linux-x64-$LABEL.deb"
  rm -f "$DEB"
  dpkg-deb --root-owner-group --build "$DEB_ROOT" "$DEB"
  rm -rf "$DEB_ROOT"
  echo "One Drop Linux deb: $DEB"
fi
