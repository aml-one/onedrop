# One Drop

Desktop tray client for AmL Gallery **One Drop** — send and receive photos and
videos next to the clock. Not the full Gallery app.

## Platforms

| Platform | Role |
|----------|------|
| **Windows** | Tray panel, LAN transfer, AirGrab catch fog (native) |
| **Linux** | Tray panel, LAN transfer, autostart — AirGrab camera not yet |
| **macOS** | Tray panel (see `scripts/build-onedrop-macos.sh`) |

Nearby radio (DropP2p / Wi‑Fi Direct style) stays on Android + Windows. Linux
discovers peers on the same Wi‑Fi via UDP hello + HTTP transfer.

## Build Linux (Windows host via WSL — same bridge as MessageMe)

```powershell
# from the Gallery repo root on Windows
.\scripts\build-onedrop-linux-wsl.ps1
```

That picks the **Ubuntu** distro (skips `docker-desktop`), uses `~/flutter` inside WSL, and runs `scripts/build-onedrop-linux.sh`.

One-time tray dep if missing:

```bash
wsl -d Ubuntu -u root -- apt-get install -y libayatana-appindicator3-dev
```

## Build Linux (native Linux host)

```bash
# from the Gallery repo root
chmod +x scripts/build-onedrop-linux.sh
./scripts/build-onedrop-linux.sh
```

Artifact: `onedrop/dist/onedrop-linux-<arch>-v<semver>-<yymmdd>.tar.gz`

Needs Flutter Linux desktop deps (GTK 3, clang, cmake, ninja, pkg-config).

Quick local run without packaging:

```bash
cd onedrop
flutter pub get
flutter run -d linux
# or
flutter build linux --release
./build/linux/x64/release/bundle/onedrop
```

After extracting the tarball, point `Exec=` / `Icon=` in
`one.aml.onedrop.desktop` at the extracted binary and PNG, then copy the
desktop file to `~/.local/share/applications/`.

## Build Windows

Use the usual Flutter Windows release flow from `onedrop/` (native AirGrab +
resource-cap plugins live under `windows/runner/`).
