# Posaba Android Emulator

A portable Android emulator bundle preloaded with **Posaba TV** (the IPTV
player) and the **Posaba calculator** — both pinned to the home screen.

It runs plain AOSP Android 14: no Google apps, no Play Store, no ads. Add
your own apps by dropping an `.apk` on the window (x86/x86_64 only).

*(This repo was `dissolvers-emulator`; old links redirect here.)*

## Install

Run **`Install-Posaba.exe`** ([v1 release](../../releases/tag/v1)) — a ~55 KB
launcher. It downloads the bundle (~1 GB) from the release, extracts it, adds a
Desktop + Start Menu shortcut, and offers to launch. First emulator boot takes
~2 minutes while it installs the apps.

`PosabaTV.apk` is also attached on its own (no emulator).

## What's in this repo

- `bundle/` — the launcher / helper scripts that live at the root of the bundle
  (`_run.cmd`, `emu-apps.ps1`, `emu-window.ps1`, `emu-zoom-button.ps1`, `README.txt`).
- `installer/` — `StartPosaba.cs` (the `Start Posaba.exe` launcher),
  `PosabaWebInstaller.cs` (the installer/uninstaller), and the packaging scripts
  (`make-lean-zip.ps1`, `make-posaba-ico.ps1`, `render-icons.ps1`).

The emulator binaries, system image and the AVD are **not** in git — they're in
the release zip.

## Publishing an update

```
gh release upload v1 PosabaEmulator.zip --repo qualitystreamzmedia-netizen/posaba-emulator --clobber
```
Same links, so nobody needs a new installer.
