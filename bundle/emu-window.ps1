# emu-window.ps1 - position / size the running Android emulator (qemu) window.
#
#   onscreen : if the window opened off-screen (stale saved position, a monitor
#              that is now off), move it back onto the primary monitor.
#   fill     : make the window as large as the primary monitor allows, keeping
#              the current display's aspect ratio (no stretching).
#   big      : switch the emulated display to the large landscape "tablet" size
#              and then fill the monitor - the one-click "make it big".
#   phone    : switch the emulated display back to the phone size.
#
# This never changes the native Win32 window style - doing that from outside
# breaks the emulator's own edge-drag resizing.
param(
  [ValidateSet('onscreen','fill','big','phone')] [string]$Mode = 'onscreen',
  [string]$Adb = '',
  [string]$Serial = ''
)

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class EmuWin {
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h,int x,int y,int w,int ht,bool repaint);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT pt,int f);
  [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
  public struct POINT { public int X, Y; }
  public struct RECT { public int Left, Top, Right, Bottom; }
  public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public int dwFlags; }
}
'@

$SW_RESTORE = 9
$MONITOR_DEFAULTTOPRIMARY = 1
$CHROME = 34   # emulator title bar height, approx
$BARSPACE = 2  # small gap above the window (the control strip now sits INSIDE
               # the window, so no desktop space needs to be reserved for it)

function Adb-Args {
  param([string[]] $rest)
  $a = @()
  if ($Serial) { $a += @('-s', $Serial) }
  return $a + $rest
}

function Guest-Size {
  # returns @(width, height) of the current emulated display, or $null
  if (-not ($Adb -and (Test-Path $Adb))) { return $null }
  try {
    $out = & $Adb (Adb-Args @('exec-out','wm','size')) 2>$null
    $m = [regex]::Matches(($out -join "`n"), '(\d+)x(\d+)')
    if ($m.Count -ge 1) {
      $last = $m[$m.Count - 1]   # "Override size" wins when present
      return @([int]$last.Groups[1].Value, [int]$last.Groups[2].Value)
    }
  } catch { }
  return $null
}

# --- find the emulator window ---
$h = [IntPtr]::Zero
for ($i = 0; $i -lt 60; $i++) {
  $p = Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue |
       Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if ($p) { $h = $p.MainWindowHandle; break }
  Start-Sleep -Milliseconds 500
}
if ($h -eq [IntPtr]::Zero) { Write-Output 'emulator window not found'; exit 1 }
[EmuWin]::ShowWindow($h, $SW_RESTORE) | Out-Null
Start-Sleep -Milliseconds 200

# --- primary monitor work area ---
$pmi = New-Object EmuWin+MONITORINFO
$pmi.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($pmi)
$primary = [EmuWin]::MonitorFromPoint((New-Object EmuWin+POINT), $MONITOR_DEFAULTTOPRIMARY)
[EmuWin]::GetMonitorInfo($primary, [ref]$pmi) | Out-Null
$wa = $pmi.rcWork
$availW = $wa.Right - $wa.Left
$availH = $wa.Bottom - $wa.Top

$r = New-Object EmuWin+RECT; [EmuWin]::GetWindowRect($h, [ref]$r) | Out-Null
$curW = $r.Right - $r.Left
$curH = $r.Bottom - $r.Top

if ($Mode -eq 'onscreen') {
  $onPrimary = ($r.Right -gt ($wa.Left + 40)) -and ($r.Left -lt ($wa.Right - 40)) -and
               ($r.Bottom -gt ($wa.Top + 40)) -and ($r.Top -ge ($wa.Top - 8))
  if (-not $onPrimary) {
    [EmuWin]::MoveWindow($h, $wa.Left + 160, $wa.Top + $BARSPACE, $curW, $curH, $true) | Out-Null
    [EmuWin]::SetForegroundWindow($h) | Out-Null
    Write-Output 'done (moved on-screen)'
  } else {
    Write-Output 'done (already on-screen)'
  }
  exit 0
}

if ($Mode -eq 'phone') {
  if ($Adb -and (Test-Path $Adb)) { & $Adb (Adb-Args @('emu','resize-display','0')) 2>$null | Out-Null }
  Start-Sleep -Seconds 3
  [EmuWin]::MoveWindow($h, $wa.Left + 160, $wa.Top + $BARSPACE, 460, [math]::Min(1000, $availH - $BARSPACE), $true) | Out-Null
  [EmuWin]::SetForegroundWindow($h) | Out-Null
  Write-Output 'done (phone)'
  exit 0
}

if ($Mode -eq 'big') {
  if ($Adb -and (Test-Path $Adb)) { & $Adb (Adb-Args @('emu','resize-display','2')) 2>$null | Out-Null }
  # wait until the guest actually reports the landscape size (up to ~20s)
  for ($k = 0; $k -lt 20; $k++) {
    Start-Sleep -Seconds 1
    $gg = Guest-Size
    if ($gg -and $gg[0] -gt $gg[1]) { break }
  }
  Start-Sleep -Seconds 1
}

# --- fill (also the tail of 'big') ---
$g = Guest-Size
if ($g) { $aspect = $g[0] / $g[1] }
elseif ($curH -gt $CHROME) { $aspect = $curW / ($curH - $CHROME) }
else { $aspect = 0.46 }

# reserve $BARSPACE of desktop above the window for the floating control strip
$usableH = $availH - $BARSPACE
$targetH = $usableH
$targetW = [int]([math]::Round(($usableH - $CHROME) * $aspect))
if ($targetW -gt $availW) {
  $targetW = $availW
  $targetH = [int]([math]::Round($availW / $aspect)) + $CHROME
}
$x = $wa.Left + [int](($availW - $targetW) / 2)
$y = $wa.Top  + $BARSPACE + [int](($usableH - $targetH) / 2)
# apply twice with a beat between - the emulator sometimes snaps back once
[EmuWin]::MoveWindow($h, $x, $y, $targetW, $targetH, $true) | Out-Null
Start-Sleep -Milliseconds 700
[EmuWin]::MoveWindow($h, $x, $y, $targetW, $targetH, $true) | Out-Null
[EmuWin]::SetForegroundWindow($h) | Out-Null
Write-Output ("done ({0} {1} x {2})" -f $Mode, $targetW, $targetH)
