POSABA ANDROID EMULATOR
=======================

A self-contained Android emulator that carries Posaba TV and the Posaba
calculator with it. Nothing to set up - copy the folder anywhere and run it.


TO RUN
------
Double-click  "Start Posaba.exe"

The emulator opens in a big landscape window filling your main monitor
(first boot takes a minute or two; quicker after that). Posaba TV and the
Posaba calculator are put on the emulator automatically and pinned to the
home screen - then open them from there. Close the window to stop it.

There is no console window, and no app is opened for you - the launcher
only starts the emulator and makes sure the apps are on it.

This is a plain Android build with no Google apps and no Play Store. To
add your own apps, copy an .apk onto the emulator window (or use adb) -
x86/x86_64 APKs only; ARM-only apps will not install.


ON-SCREEN CONTROLS
------------------
A vertical control strip is docked to the window's right edge:
  Minimize / Maximize  -  Back / Home / Recent apps / Close app  -
  Volume down / up  -  Rotate / Screenshot  -  Power  -
  Close emulator (the red button at the bottom).
Hover a button for its name; it flashes when you press it. The strip
only shows while the emulator is the active window.
  - Close app quits whatever app is in front and returns to the home
    screen.
  - Rotate flips between portrait and landscape (always the right way
    up). Portrait uses a phone-sized screen, landscape a tablet-sized
    one, so the picture changes shape and size when you switch.
  - Maximize makes the window as tall as the screen; press again to go
    back. The picture keeps its shape, so on a widescreen monitor there
    is some desktop left at the sides - that is the Android screen's
    shape, not a bug.
  - Screenshot briefly shows a tick and saves the picture to your
    Pictures\Emulator folder.
  - Close emulator shuts the whole emulator down.


RESIZING THE WINDOW
-------------------
This is a "Resizable" Android device, so the window behaves like a
normal window:
- Drag any edge or corner to make it bigger or smaller.
- Double-click  "Fill Screen"  - large landscape layout, filled to the
  monitor (this is also how it opens).
- Double-click  "Phone Size"   - back to a small upright phone.
- If it ever opens off-screen (e.g. a monitor was unplugged),
  "Fill Screen" brings it back to the main monitor.


REQUIREMENTS
------------
- 64-bit Windows 10 or 11
- ~8 GB free RAM (the emulator uses 4 GB)
- Hardware virtualization: turn on "Windows Hypervisor Platform" in
  "Turn Windows features on or off", then reboot; also enable
  virtualization / SVM / VT-x in the BIOS. Without it the emulator still
  runs, just slowly.


WHAT'S INSIDE
-------------
  Start Posaba.exe              launcher (double-click this)
  _run.cmd                      the script it runs
  Fill Screen.vbs               big landscape layout, filled to the monitor
  Phone Size.vbs                small upright phone layout
  emu-window.ps1                helper used by the launchers above
  emu-apps.ps1                  installs + pins the home-screen apps
  emu-zoom-button.ps1           the on-screen control strip
  posaba.ico                    the launcher's icon
  app-debug.apk                 Posaba TV (installed on first boot;
                                keep it here to reinstall a newer build)
  apps\posaba.apk               the Posaba calculator
  sdk\emulator\                 Android emulator
  sdk\platform-tools\           adb
  sdk\system-images\            Android 14 (API 34) x86_64, plain AOSP
  avd\Dissolvers.avd\           the virtual device (Resizable device type)


UPDATING AN APP
---------------
Replace app-debug.apk (Posaba TV) or apps\posaba.apk (calculator) with a
newer build. The next launch installs it in place automatically.


RESETTING
---------
To wipe everything and start clean, delete every userdata* file from
avd\Dissolvers.avd\  (keep config.ini). The next launch rebuilds them
and reinstalls the apps.
