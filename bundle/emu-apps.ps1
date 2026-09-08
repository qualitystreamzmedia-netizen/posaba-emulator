# emu-apps.ps1
# Re-installs the sideloaded home-screen apps (Downloader, APKPure, Posaba
# calculator) after a cold boot and drops their icons onto the first home
# screen, next to Posaba TV. The portable
# emulator always boots -no-snapshot, which wipes every app except Dissolvers
# (which _run.cmd reinstalls); once userdata-qemu.img exists it persists, so
# most of this is a no-op after the first launch - but it self-heals if not.
#
# Icons go on the WORKSPACE (container -100), not the dock/hotseat: the phone
# (portrait) hotseat only holds ~4 icons so APKPure kept falling off it.
#
# APKs live in .\apps\ :  apps\apkpure.apk
#                         apps\posaba.apk
#                         apps\downloader\{com.esaba.downloader,config.*}.apk

param(
  [string]$Adb    = (Join-Path $PSScriptRoot 'sdk\platform-tools\adb.exe'),
  [string]$Serial = 'emulator-5554'
)

$ErrorActionPreference = 'SilentlyContinue'
$appsD = Join-Path $PSScriptRoot 'apps'

function Sh([string]$cmd)  { & $Adb -s $Serial shell "su 0 $cmd" }
function Installed($pkg)   { (& $Adb -s $Serial shell pm list packages $pkg) -match [regex]::Escape("package:$pkg") }
# count via a pushed .sql file - an inline "SELECT count(*)" loses its parens to
# the device shell ("syntax error: unexpected '('").
function FavCount($db) {
  $qf = Join-Path $env:TEMP 'emu-fav.sql'
  if (-not (Test-Path $qf)) { Set-Content -Path $qf -Value 'SELECT count(1) FROM favorites;' -Encoding ascii -NoNewline }
  if (-not $script:favPushed) { & $Adb -s $Serial push $qf /data/local/tmp/emu-fav.sql *> $null; $script:favPushed = $true }
  (Sh "sh -c 'sqlite3 $script:dbDir/$db < /data/local/tmp/emu-fav.sql 2>/dev/null'") -replace '\D',''
}

# ---- 1. install the apps if a cold boot wiped them --------------------------
if (-not (Installed 'com.esaba.downloader')) {
  $d = Join-Path $appsD 'downloader'
  $parts = @('com.esaba.downloader.apk','config.arm64_v8a.apk','config.en.apk','config.mdpi.apk') |
           ForEach-Object { Join-Path $d $_ } | Where-Object { Test-Path $_ }
  if ($parts) { & $Adb -s $Serial install-multiple -r @parts | Out-Null }
}
if (-not (Installed 'com.apkpure.aegon')) {
  $a = Join-Path $appsD 'apkpure.apk'
  if (Test-Path $a) { & $Adb -s $Serial install -r $a | Out-Null }
}
if (-not (Installed 'com.dissolvers.calc88a')) {
  $p = Join-Path $appsD 'posaba.apk'
  if (Test-Path $p) { & $Adb -s $Serial install -r $p | Out-Null }
}

# ---- 2. put their icons on the first home screen -------------------------
$script:dbDir = '/data/data/com.google.android.apps.nexuslauncher/databases'
$dbDir = $script:dbDir
function Resolve-Comp($pkg, $fallback) {
  $c = ((& $Adb -s $Serial shell cmd package resolve-activity --brief $pkg) -split "`r?`n" |
        Where-Object { $_ -match ("^" + [regex]::Escape($pkg) + "/") } | Select-Object -Last 1).Trim()
  if (-not $c) { $c = $fallback }
  # expand the pkg/.rel.Class shorthand to a fully-qualified name for the
  # favorites intent string (the launcher won't resolve the relative form).
  if ($c -match "^([^/]+)/\.(.+)$") { $c = "$($Matches[1])/$($Matches[1]).$($Matches[2])" }
  $c
}
$dls = 'com.esaba.downloader/com.esaba.downloader.ui.main.MainActivity'
$pps = 'com.apkpure.aegon/com.apkpure.aegon.main.activity.FirstSeemPageActivity'
$pbc = Resolve-Comp 'com.dissolvers.calc88a' 'com.dissolvers.calc88a/crc64af2439e7ed34c779.MainActivity'
$tvc = Resolve-Comp 'com.dissolvers.iptv'    'com.dissolvers.iptv/com.dissolvers.iptv.ui.DisclaimerActivity'
function Intent-Str($c) { "#Intent;action=android.intent.action.MAIN;category=android.intent.category.LAUNCHER;launchFlags=0x10200000;component=$c;end" }
$dlIntent = Intent-Str $dls
$ppIntent = Intent-Str $pps
$pbIntent = Intent-Str $pbc
$tvIntent = Intent-Str $tvc
$cols = 'title,intent,container,screen,cellX,cellY,spanX,spanY,itemType,appWidgetId,modified,restored,profileId,rank,options,appWidgetSource'

# workspace (container -100), first page, cellX 0..3 at cellY 3. cellY 3 is empty
# in both the 6x5 (tablet) and 4x5 (phone) default layouts. Clear those cells
# first - a cell collision makes the launcher silently drop our shortcut.
$sql = @"
DELETE FROM favorites WHERE intent LIKE '%com.esaba.downloader%' OR intent LIKE '%com.apkpure.aegon%' OR intent LIKE '%com.dissolvers.calc88a%' OR intent LIKE '%com.dissolvers.iptv%';
DELETE FROM favorites WHERE container=-100 AND screen=0 AND cellY=3 AND cellX IN (0,1,2,3);
INSERT INTO favorites ($cols) VALUES
 ('Posaba TV','$tvIntent',-100,0,0,3,1,1,0,-1,0,0,0,0,0,-1),
 ('Posaba','$pbIntent',-100,0,1,3,1,1,0,-1,0,0,0,0,0,-1),
 ('Downloader','$dlIntent',-100,0,2,3,1,1,0,-1,0,0,0,0,0,-1),
 ('APKPure','$ppIntent',-100,0,3,3,1,1,0,-1,0,0,0,0,0,-1);
PRAGMA wal_checkpoint(TRUNCATE);
"@
$tmp = Join-Path $env:TEMP 'emu-apps.sql'
Set-Content -Path $tmp -Value $sql -Encoding ascii -NoNewline
& $Adb -s $Serial push $tmp /data/local/tmp/emu-apps.sql | Out-Null

# The launcher owns its databases dir. Any launcher*.db that is 0 bytes or owned
# by someone else (root, left by an earlier bad edit) makes NexusLauncher CRASH
# to a black screen when it switches to that grid - delete those so it can
# recreate them cleanly.
$owner = ((Sh "stat -c %U $dbDir") -join '').Trim()
if ($owner) {
  foreach ($f in ((Sh "ls $dbDir") -split '\s+' | Where-Object { $_ -match '^launcher.*\.db$' })) {
    $info = ((Sh "stat -c '%U %s' $dbDir/$f") -join '').Trim() -split '\s+'
    if ($info[0] -ne $owner -or $info[1] -eq '0') {
      Sh "rm -f $dbDir/$f $dbDir/$f-journal $dbDir/$f-wal $dbDir/$f-shm" | Out-Null
    }
  }
}

# Wait for the launcher to finish writing its default layout, then edit only the
# grid DB(s) that already have a populated favorites table (editing one that
# isn't there yet creates a broken file; editing before defaults land makes the
# launcher skip Phone/Chrome/Gmail).
$liveDbs = @()
for ($i = 0; $i -lt 40; $i++) {
  $liveDbs = @(); $ready = $false
  foreach ($name in ((Sh "ls $dbDir") -split '\s+' | Where-Object { $_ -match '^launcher.*\.db$' })) {
    $n = FavCount $name
    if ($n -ne '') { $liveDbs += $name; if ([int]$n -ge 6) { $ready = $true } }
  }
  if ($ready) { break }
  Start-Sleep -Milliseconds 750
}
Start-Sleep -Milliseconds 1200
if (-not $liveDbs) { return }

Sh "am force-stop com.google.android.apps.nexuslauncher" | Out-Null
Start-Sleep -Milliseconds 800

foreach ($name in $liveDbs) {
  Sh "sh -c 'sqlite3 $dbDir/$name < /data/local/tmp/emu-apps.sql'" 2>&1 | Out-Null
}

# The phone-grid DB (launcher_4_by_5.db) usually doesn't exist yet - the launcher
# only creates it the first time you rotate to portrait, long after this runs.
# Seed it from the grid we just populated so the icons are there in portrait too;
# the launcher reflows the columns on load.
$src = $liveDbs | Where-Object { (FavCount $_) -and [int](FavCount $_) -ge 6 } | Select-Object -First 1
if ($src) {
  foreach ($g in @('launcher_4_by_5.db','launcher_6_by_5.db','launcher.db')) {
    if ($g -eq $src) { continue }
    if ((FavCount $g) -eq '') {
      Sh "sh -c 'cp $dbDir/$src $dbDir/$g'" | Out-Null
      Sh "sh -c 'rm -f $dbDir/$g-journal $dbDir/$g-wal $dbDir/$g-shm'" | Out-Null
      Sh "chown ${owner}:${owner} $dbDir/$g" | Out-Null
      Sh "chmod 660 $dbDir/$g" | Out-Null
    }
  }
}

# ---- 3. bump the on-device font a little ---------------------------------
# Scales Android system UI text + the Dissolvers app (it uses sp sizes). Retry
# until it sticks - a single put right after boot sometimes doesn't take.
for ($i = 0; $i -lt 6; $i++) {
  if (((& $Adb -s $Serial shell settings get system font_scale) -replace '\s','') -eq '1.15') { break }
  & $Adb -s $Serial shell settings put system font_scale 1.15 | Out-Null
  Start-Sleep -Milliseconds 800
}

& $Adb -s $Serial shell am start -c android.intent.category.HOME -a android.intent.action.MAIN | Out-Null
