@echo off
rem Started hidden by "Start Posaba.exe" - no console is shown.
setlocal EnableExtensions

set "ROOT=%~dp0"
set "ANDROID_HOME=%ROOT%sdk"
set "ANDROID_SDK_ROOT=%ROOT%sdk"
set "ANDROID_AVD_HOME=%ROOT%avd"
set "ANDROID_EMULATOR_HOME=%ROOT%avd"
set "EMU=%ROOT%sdk\emulator\emulator.exe"
set "ADB=%ROOT%sdk\platform-tools\adb.exe"
set "APK=%ROOT%app-debug.apk"
set "SERIAL=emulator-5554"

rem --- Point the virtual device at wherever this folder currently is ---
> "%ROOT%avd\Dissolvers.ini" (
    echo avd.ini.encoding=UTF-8
    echo path=%ROOT%avd\Dissolvers.avd
    echo path.rel=avd\Dissolvers.avd
    echo target=android-34
)

rem --- Start the emulator if it isn't already running ---
"%ADB%" -s %SERIAL% get-state >nul 2>&1
if errorlevel 1 (
    start "" /b "%EMU%" -avd Dissolvers -gpu swiftshader_indirect -no-snapshot -no-boot-anim
)

rem --- Wait for it to finish booting ---
"%ADB%" -s %SERIAL% wait-for-device
:waitboot
set "BOOT="
for /f "usebackq tokens=*" %%b in (`"%ADB%" -s %SERIAL% shell getprop sys.boot_completed 2^>nul`) do set "BOOT=%%b"
if not "%BOOT%"=="1" (
    ping -n 4 -w 1000 127.0.0.1 >nul
    goto waitboot
)

rem --- Make sure Posaba TV is installed (it isn't launched - open it yourself) ---
rem     Retry a few times - a very first boot can reject the install while the
rem     data partition is still initialising.
for /l %%n in (1,1,5) do (
    "%ADB%" -s %SERIAL% shell pm list packages com.dissolvers.iptv 2>nul | find "com.dissolvers.iptv" >nul
    if errorlevel 1 (
        if exist "%APK%" "%ADB%" -s %SERIAL% install -r "%APK%" >nul 2>&1
        ping -n 4 -w 1000 127.0.0.1 >nul
    )
)
rem --- Update in place when this bundle ships a newer build. install -r
rem     updates; if an older debug build changed the signature, fall back to
rem     uninstall + install (the app re-seeds its "Free TV" playlist). ---
if exist "%APK%" (
    "%ADB%" -s %SERIAL% install -r "%APK%" >nul 2>&1
    if errorlevel 1 (
        "%ADB%" -s %SERIAL% uninstall com.dissolvers.iptv >nul 2>&1
        "%ADB%" -s %SERIAL% install "%APK%" >nul 2>&1
    )
)

rem --- Re-add the sideloaded home-screen apps (Posaba calculator, Downloader,
rem     APKPure). A -no-snapshot boot wipes every app except Posaba TV, so this
rem     runs each launch: installs from .\apps\ if missing + pins the icons. ---
powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%ROOT%emu-apps.ps1" -Adb "%ADB%" -Serial %SERIAL%

rem --- (font bump is applied inside emu-apps.ps1, which retries until it sticks) ---

rem --- Stop the resizable device auto-rotating on its own. Leave user-rotation
rem     "free" so the Rotate button (emulator's own rotate) still works. ---
"%ADB%" -s %SERIAL% shell settings put system accelerometer_rotation 0 >nul 2>&1
"%ADB%" -s %SERIAL% shell wm user-rotation free >nul 2>&1

rem --- Open big: switch to the large landscape layout and fill the monitor.
rem     Detached so it still runs if this window is closed first. ---
start "" powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%ROOT%emu-window.ps1" big -Adb "%ADB%" -Serial %SERIAL%

rem --- Custom vertical control strip on the window's right edge (back, home,
rem     recents, close-app, volume, rotate, screenshot, fill, power, quit).
rem     Hides the emulator's own toolbar and stands in for it. ---
start "" powershell -NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File "%ROOT%emu-zoom-button.ps1" -Adb "%ADB%" -Serial %SERIAL%

endlocal
