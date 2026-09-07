#!/usr/bin/env bash
# Run on a macOS Flutter host (Nova) from the OneDrop repo root.
# Builds One Drop as two single-architecture apps and wraps each in its own DMG.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/app"
VERSION_FILE="$ROOT/version"
DIST="$PROJECT/dist"

[[ "$(uname -s)" == "Darwin" ]] || { echo "One Drop macOS builds require macOS." >&2; exit 1; }
[[ -f "$PROJECT/pubspec.yaml" ]] || { echo "Missing One Drop project: $PROJECT" >&2; exit 1; }
[[ -f "$VERSION_FILE" ]] || { echo "Missing OneDrop version: $VERSION_FILE" >&2; exit 1; }

export PATH="${HOME}/flutter/bin:${PATH}"
if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x "${HOME}/homebrew/bin/brew" ]]; then
  eval "$("${HOME}/homebrew/bin/brew" shellenv)"
fi
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  elif command -v xcode-select >/dev/null; then
    DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
    export DEVELOPER_DIR
  fi
fi
if [[ -n "${DEVELOPER_DIR:-}" && -d "$DEVELOPER_DIR/usr/bin" ]]; then
  export PATH="$DEVELOPER_DIR/usr/bin:$PATH"
fi
command -v flutter >/dev/null || { echo "flutter not found on PATH." >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "xcodebuild not found; set DEVELOPER_DIR to Xcode.app/Contents/Developer." >&2; exit 1; }
command -v hdiutil >/dev/null || { echo "hdiutil not found." >&2; exit 1; }

SEMVER="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ "$SEMVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid OneDrop semver: $SEMVER" >&2; exit 1; }
IFS=. read -r MAJOR MINOR PATCH <<< "$SEMVER"
BUILD_NUMBER=$((10#$MAJOR * 10000 + 10#$MINOR * 100 + 10#$PATCH))
BUILD_DATE="$(date -u +%y%m%d)"
LABEL="v$SEMVER-$BUILD_DATE"

cd "$PROJECT"
flutter config --no-enable-swift-package-manager >/dev/null
flutter pub get
flutter build macos --config-only --release --build-name "$SEMVER" --build-number "$BUILD_NUMBER" \
  --dart-define="APP_VERSION=$SEMVER" --dart-define="APP_BUILD_DATE=$BUILD_DATE"

WORKSPACE="$PROJECT/macos/Runner.xcworkspace"
[[ -d "$WORKSPACE" ]] || { echo "Missing $WORKSPACE" >&2; exit 1; }

thin_to_arch() {
  local app="$1"
  local arch="$2"
  python3 - "$app" "$arch" <<'PY'
import os
import subprocess
import sys

app, arch = sys.argv[1], sys.argv[2]
for root, _dirs, files in os.walk(app):
    for name in files:
        path = os.path.join(root, name)
        try:
            info = subprocess.check_output(["file", "-b", path], text=True)
        except subprocess.CalledProcessError:
            continue
        if "Mach-O" not in info:
            continue
        try:
            arches = subprocess.check_output(["lipo", "-archs", path], text=True).split()
        except subprocess.CalledProcessError:
            continue
        if arch not in arches:
            sys.exit(f"{path} has no {arch} slice ({' '.join(arches)})")
        if len(arches) == 1:
            continue
        tmp = path + ".thin"
        subprocess.check_call(["lipo", "-thin", arch, path, "-output", tmp])
        os.replace(tmp, path)
PY
}

find_app() {
  local products="$1"
  if [[ -d "$products/One Drop.app" ]]; then
    echo "$products/One Drop.app"
    return
  fi
  local apps=()
  shopt -s nullglob
  apps=("$products"/*.app)
  shopt -u nullglob
  [[ ${#apps[@]} -gt 0 ]] || return 1
  echo "${apps[0]}"
}

package_dmg() {
  local app="$1"
  local volname="$2"
  local artifact="$3"
  local stage
  stage="$(mktemp -d)"
  ditto "$app" "$stage/$(basename "$app")"
  ln -s /Applications "$stage/Applications"
  rm -f "$artifact"
  hdiutil create \
    -volname "$volname" \
    -srcfolder "$stage" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$artifact" >/dev/null
  rm -rf "$stage"
}

build_one() {
  local arch="$1"
  local slug="$2"
  local volname="$3"
  local other
  if [[ "$arch" == "arm64" ]]; then
    other=x86_64
  else
    other=arm64
  fi
  local dd="$PROJECT/build/macos-dd-$slug"
  rm -rf "$dd"
  echo "==> xcodebuild One Drop ($arch / $slug)"
  xcodebuild \
    -workspace "$WORKSPACE" \
    -scheme Runner \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$dd" \
    ARCHS="$arch" \
    ONLY_ACTIVE_ARCH=YES \
    EXCLUDED_ARCHS="$other" \
    CODE_SIGNING_ALLOWED=NO \
    build
  local products="$dd/Build/Products/Release"
  local app
  app="$(find_app "$products")"
  [[ -n "$app" && -d "$app" ]] || { echo "One Drop .app not found under $products" >&2; exit 1; }
  thin_to_arch "$app" "$arch"
  local executable_name
  executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
  local executable="$app/Contents/MacOS/$executable_name"
  [[ -f "$executable" ]] || { echo "Missing executable: $executable" >&2; exit 1; }
  local got
  got="$(lipo -archs "$executable")"
  [[ "$got" == "$arch" ]] || { echo "Expected $arch, got: $got ($executable)" >&2; exit 1; }
  codesign --force --deep --sign - "$app"
  mkdir -p "$DIST"
  local artifact="$DIST/onedrop-macos-$slug-$LABEL.dmg"
  echo "==> DMG $artifact"
  package_dmg "$app" "$volname" "$artifact"
  echo "One Drop $slug ($arch): $artifact"
}

build_one arm64 silicon "One Drop (Apple Silicon)"
build_one x86_64 intel "One Drop (Intel)"
echo "One Drop macOS disk images: $DIST/onedrop-macos-{silicon,intel}-$LABEL.dmg"
