# emu-apps.ps1
# Run once after every cold boot. The portable emulator always boots
# -no-snapshot; once userdata-qemu.img exists apps persist, so this is mostly a
# no-op after the first launch - but it self-heals if not.
#
#   * installs the Posaba calculator (apps\posaba.apk, com.dissolvers.calc88a)
#   * pins Posaba TV + Posaba to the home screen
#   * silences the broken AOSP "Search" box (com.android.quicksearchbox crashes)
#   * bumps the on-device font a touch
#
# Image is plain AOSP (no Google apps, no ARM translation) -> the launcher is
# Launcher3. Its live workspace lives in databases\launcher_<C>_by_<R>.db, NOT
# the legacy launcher.db - we detect whichever one it is actually using.

param(
  [string]$Adb    = (Join-Path $PSScriptRoot 'sdk\platform-tools\adb.exe'),
  [string]$Serial = 'emulator-5554'
)

$ErrorActionPreference = 'SilentlyContinue'
$appsD  = Join-Path $PSScriptRoot 'apps'
$LAUNCH = 'com.android.launcher3'
$dbDir  = "/data/data/$LAUNCH/databases"

function Sh([string]$cmd) { & $Adb -s $Serial shell "su 0 $cmd" }
function Installed($pkg)  { (& $Adb -s $Serial shell pm list packages $pkg) -match [regex]::Escape("package:$pkg") }

# ---- 1. install the calculator if a cold boot wiped it ---------------------
if (-not (Installed 'com.dissolvers.calc88a')) {
  $p = Join-Path $appsD 'posaba.apk'
  if (Test-Path $p) { & $Adb -s $Serial install -r $p | Out-Null }
}

# ---- 2. kill the crashing AOSP search box ---------------------------------
Sh "pm disable-user --user 0 com.android.quicksearchbox" | Out-Null

# ---- 3. find the launcher's live workspace DB ----------------------------
# Wait for Launcher3 to have created + populated its grid DB.
$db = $null
for ($i = 0; $i -lt 40; $i++) {
  $names = (Sh "sh -c 'ls $dbDir 2>/dev/null'") -split "`r?`n" |
           Where-Object { $_ -match '^launcher(_\d+_by_\d+)?\.db$' }
  # prefer a grid-sized db (launcher_6_by_5.db); fall back to launcher.db
  $grid = $names | Where-Object { $_ -match '_by_' } | Select-Object -First 1
  $cand = if ($grid) { $grid } else { $names | Select-Object -First 1 }
  if ($cand) {
    $full = "$dbDir/$cand"
    $n = (Sh "sqlite3 $full 'SELECT count(1) FROM favorites'") -replace '\D',''
    if ($n -ne '' -and [int]$n -ge 3) { $db = $full; break }
  }
  Start-Sleep -Milliseconds 750
}
if (-not $db) { return }

# ---- 4. resolve launcher components + pin the icons --------------------
function Resolve-Comp($pkg, $fallback) {
  $c = ((& $Adb -s $Serial shell cmd package resolve-activity --brief $pkg) -split "`r?`n" |
        Where-Object { $_ -match ("^" + [regex]::Escape($pkg) + "/") } | Select-Object -Last 1).Trim()
  if (-not $c) { $c = $fallback }
  if ($c -match "^([^/]+)/\.(.+)$") { $c = "$($Matches[1])/$($Matches[1]).$($Matches[2])" }
  $c
}
function Intent-Str($c) {
  $pkg = ($c -split '/')[0]
  "#Intent;action=android.intent.action.MAIN;category=android.intent.category.LAUNCHER;launchFlags=0x10200000;package=$pkg;component=$c;end"
}
$tvc = Resolve-Comp 'com.dissolvers.iptv'    'com.dissolvers.iptv/com.dissolvers.iptv.ui.DisclaimerActivity'
$pbc = Resolve-Comp 'com.dissolvers.calc88a' 'com.dissolvers.calc88a/crc64af2439e7ed34c779.MainActivity'
$cols = 'title,intent,container,screen,cellX,cellY,spanX,spanY,itemType,appWidgetId,modified,restored,profileId,rank,options,appWidgetSource'

# Workspace = container -100, screen 0. Put the two apps on row 1 (row 0 holds
# the search box + the default Gallery shortcut). Clear those two cells first -
# a collision makes Launcher3 silently drop the shortcut.
$sql = @"
DELETE FROM favorites WHERE intent LIKE '%com.dissolvers.%';
DELETE FROM favorites WHERE container=-100 AND screen=0 AND cellY=1 AND cellX IN (0,1);
INSERT INTO favorites ($cols) VALUES
 ('Posaba TV','$(Intent-Str $tvc)',-100,0,0,1,1,1,0,-1,0,0,0,0,0,-1),
 ('Posaba','$(Intent-Str $pbc)',-100,0,1,1,1,1,0,-1,0,0,0,0,0,-1);
"@
$tmp = Join-Path $env:TEMP 'emu-apps.sql'
Set-Content -Path $tmp -Value $sql -Encoding ascii -NoNewline
& $Adb -s $Serial push $tmp /data/local/tmp/emu-apps.sql | Out-Null
# /data/local/tmp is not readable by the launcher uid; stage it inside its dir.
$staged = "/data/data/$LAUNCH/emu-apps.sql"
Sh "cp /data/local/tmp/emu-apps.sql $staged" | Out-Null

Sh "am force-stop $LAUNCH" | Out-Null
Start-Sleep -Milliseconds 600
Sh "sqlite3 $db < $staged" | Out-Null
Sh "rm $staged" | Out-Null

# Force Launcher3 to reload its model from the DB (a plain force-stop is not
# always enough - toggling the component guarantees a cold start).
Sh "pm disable-user $LAUNCH" | Out-Null
Start-Sleep -Milliseconds 800
Sh "pm enable $LAUNCH" | Out-Null
Start-Sleep -Milliseconds 800

# ---- 5. bump the on-device font a little -------------------------------
for ($i = 0; $i -lt 6; $i++) {
  if (((& $Adb -s $Serial shell settings get system font_scale) -replace '\s','') -eq '1.15') { break }
  & $Adb -s $Serial shell settings put system font_scale 1.15 | Out-Null
  Start-Sleep -Milliseconds 800
}

& $Adb -s $Serial shell am start -c android.intent.category.HOME -a android.intent.action.MAIN | Out-Null
