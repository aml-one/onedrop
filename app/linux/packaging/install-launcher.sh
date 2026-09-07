#!/usr/bin/env bash
# Install OneDrop into the Lomiri / desktop app drawer (portable tarball).
# Run from the extracted onedrop folder:
#   chmod +x install-launcher.sh && ./install-launcher.sh
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
cd "$HERE"

APP_ID="one.aml.onedrop"
ICON_NAME="${APP_ID}.png"
DESKTOP_NAME="${APP_ID}.desktop"
BIN="$HERE/onedrop"

same_path() {
  local a b
  a="$(readlink -f "$1" 2>/dev/null || echo "$1")"
  b="$(readlink -f "$2" 2>/dev/null || echo "$2")"
  [[ -n "$a" && "$a" == "$b" ]]
}

safe_cp() {
  local src="$1" dest="$2"
  if [[ ! -f "$src" || ! -s "$src" ]]; then
    return 1
  fi
  mkdir -p "$(dirname "$dest")"
  if same_path "$src" "$dest"; then
    return 0
  fi
  cp -f "$src" "$dest"
}

if [[ ! -x "$BIN" ]]; then
  echo "onedrop binary not found next to this script: $BIN" >&2
  exit 1
fi

HOME_DIR="${HOME:-}"
if [[ -z "$HOME_DIR" ]]; then
  echo "HOME is unset — cannot install launcher" >&2
  exit 1
fi

DATA_HOME="${XDG_DATA_HOME:-$HOME_DIR/.local/share}"
APPS_DIR="$DATA_HOME/applications"
AUTOSTART_DIR="${XDG_CONFIG_HOME:-$HOME_DIR/.config}/autostart"
ICON_ROOT="$DATA_HOME/icons/hicolor"
PIXMAPS_DIR="$DATA_HOME/pixmaps"
STABLE_ICON_DIR="$DATA_HOME/$APP_ID/icons"
STABLE_ICON="$STABLE_ICON_DIR/app.png"
mkdir -p "$APPS_DIR" "$PIXMAPS_DIR" "$STABLE_ICON_DIR" "$AUTOSTART_DIR"
chmod +x "$BIN" "$HERE/install-launcher.sh" 2>/dev/null || true

ICON_SRC=""
for candidate in \
  "$HERE/$ICON_NAME" \
  "$HERE/one.aml.onedrop.png" \
  "$HERE/data/flutter_assets/assets/icon/app_icon.png"
do
  if [[ -f "$candidate" && -s "$candidate" ]]; then
    ICON_SRC="$candidate"
    break
  fi
done

if [[ -n "$ICON_SRC" ]]; then
  safe_cp "$ICON_SRC" "$STABLE_ICON" || true
  mkdir -p "$ICON_ROOT/256x256/apps" "$ICON_ROOT/128x128/apps" "$ICON_ROOT/64x64/apps" "$ICON_ROOT/48x48/apps"
  safe_cp "$ICON_SRC" "$ICON_ROOT/256x256/apps/$ICON_NAME" || true
  safe_cp "$ICON_SRC" "$PIXMAPS_DIR/$ICON_NAME" || true
fi

ICON_LINE="Icon=$STABLE_ICON"
if [[ ! -f "$STABLE_ICON" ]]; then
  ICON_LINE="Icon=$HERE/$ICON_NAME"
fi

cat > "$APPS_DIR/$DESKTOP_NAME" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=OneDrop
GenericName=File transfer
Comment=Send and receive files over the same Wi-Fi
Exec=$BIN
$ICON_LINE
Terminal=false
Categories=Network;FileTransfer;
StartupNotify=false
X-GNOME-Autostart-enabled=true
StartupWMClass=onedrop
EOF
chmod 644 "$APPS_DIR/$DESKTOP_NAME"
safe_cp "$APPS_DIR/$DESKTOP_NAME" "$AUTOSTART_DIR/$DESKTOP_NAME" || true
echo "Installed $APPS_DIR/$DESKTOP_NAME"
echo "Autostart $AUTOSTART_DIR/$DESKTOP_NAME"
