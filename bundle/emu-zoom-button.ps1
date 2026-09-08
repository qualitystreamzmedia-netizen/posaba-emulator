# emu-zoom-button.ps1
# A vertical control strip docked to the RIGHT EDGE of the Android emulator
# window - sitting in the desktop margin beside the screen, exactly where the
# emulator's own toolbar sits (that one is hidden). It tracks the window as it
# moves. Because it lives in the margin it never covers the Android screen and
# has no gap above it - it reads as attached to the window.
#
# Groups, top to bottom, separated by hairline dividers:
#   navigate : back | home | recents | close app
#   volume   : down | up
#   view     : rotate | screenshot | fill screen (blue - toggles fill/restore)
#   power    : power
#   quit     : close the emulator (dark red)
#
# - each button fires its action through adb, fire-and-forget
# - the pressed cell flashes; screenshot briefly shows a tick
# - only visible while the emulator (or this bar) is the foreground window
# - clicks caught with a low-level mouse hook, reliable regardless of focus
# Exits by itself when the emulator window closes.

param(
  [string]$Adb    = '',
  [string]$Serial = ''
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# one instance only (a named mutex is race-free, unlike a pid file)
$script:mtx = New-Object System.Threading.Mutex($false, 'Local\DissolversEmuStrip')
if (-not $script:mtx.WaitOne(0)) { exit }

Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class Win {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h,int x,int y,int w,int ht,bool repaint);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int cx,int cy,uint flags);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int cmd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT r);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h,int f);
  [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
  public delegate bool EnumProc(IntPtr h, IntPtr l);

  public delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool UnhookWindowsHookEx(IntPtr hhk);
  [DllImport("user32.dll")] public static extern IntPtr CallNextHookEx(IntPtr hhk, int code, IntPtr wParam, IntPtr lParam);
  [DllImport("kernel32.dll", CharSet=CharSet.Auto, SetLastError=true)] public static extern IntPtr GetModuleHandle(string name);

  // window-move notifications straight from the OS - no polling
  public delegate void WinEventProc(IntPtr hHook, uint ev, IntPtr hwnd, int idObj, int idChild, uint thread, uint time);
  [DllImport("user32.dll")] public static extern IntPtr SetWinEventHook(uint eMin, uint eMax, IntPtr hmod, WinEventProc cb, uint pid, uint tid, uint flags);
  [DllImport("user32.dll")] public static extern bool UnhookWinEvent(IntPtr h);

  [StructLayout(LayoutKind.Sequential)] public struct MSLLHOOKSTRUCT { public int x; public int y; public uint mouseData; public uint flags; public uint time; public IntPtr dwExtraInfo; }
  public struct RECT { public int Left, Top, Right, Bottom; }
  public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public int dwFlags; }
}
'@

try { [Win]::SetProcessDPIAware() | Out-Null } catch { }

# ---------- adb wiring ----------
if (-not $Adb) {
  $cand = @(
    (Join-Path $PSScriptRoot 'sdk\platform-tools\adb.exe'),
    (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe')
  )
  $Adb = $cand | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $Adb) { $c = Get-Command adb -ErrorAction SilentlyContinue; if ($c) { $Adb = $c.Source } }
}
if (-not $Serial) {
  try {
    $Serial = (& $Adb devices 2>$null | Select-String '^(emulator-\d+)\s+device' |
               ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1)
  } catch { }
}
if (-not $Serial) { $Serial = 'emulator-5554' }
$script:adb    = $Adb
$script:serial = $Serial
$script:shotDir = Join-Path $env:USERPROFILE 'Pictures\Emulator'
try { if (-not (Test-Path $script:shotDir)) { New-Item -ItemType Directory -Path $script:shotDir -Force | Out-Null } } catch { }

function AdbDo([string]$rest) {
  if (-not $script:adb) { return }
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $script:adb
    $psi.Arguments       = "-s $script:serial $rest"
    $psi.CreateNoWindow  = $true
    $psi.UseShellExecute = $false
    $psi.WindowStyle     = [System.Diagnostics.ProcessWindowStyle]::Hidden
    [System.Diagnostics.Process]::Start($psi) | Out-Null
  } catch { }
}
function AdbGet([string]$rest) {
  if (-not $script:adb) { return '' }
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $script:adb
    $psi.Arguments              = "-s $script:serial $rest"
    $psi.CreateNoWindow         = $true
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit(2500) | Out-Null
    return $o
  } catch { return '' }
}
function Close-Foreground {
  $o = AdbGet 'shell dumpsys activity activities'
  $m = [regex]::Match($o, 'topResumedActivity=ActivityRecord\{\S+ \S+ ([A-Za-z0-9_.]+)/')
  if (-not $m.Success) {
    $o2 = AdbGet 'shell dumpsys window'
    $m  = [regex]::Match($o2, 'mCurrentFocus=Window\{\S+ \S+ ([A-Za-z0-9_.]+)/')
  }
  if ($m.Success) {
    $pkg = $m.Groups[1].Value
    if ($pkg -and $pkg -notmatch 'nexuslauncher|systemui|launcher3') {
      AdbDo "shell am force-stop $pkg"
      AdbDo 'shell input keyevent 3'
    } else {
      AdbDo 'shell input keyevent 3'
    }
  } else {
    AdbDo 'shell input keyevent 3'
  }
}
function Toggle-Rotation {
  # 2-way portrait <-> landscape, always upright. 'emu rotate' is a flaky
  # one-way 4-step cycle with no readable state; the reliable lever on a
  # Resizable AVD is the display preset: index 2 = tablet (landscape,
  # 1920x1200), index 0 = phone (portrait, 1080x2340). Decide which way to go
  # from the window's current shape.
  $h = Get-EmuHandle
  if ($h -eq [IntPtr]::Zero) { return }
  $r = New-Object Win+RECT; [Win]::GetWindowRect($h,[ref]$r) | Out-Null
  $landscapeNow = (($r.Right - $r.Left) -ge ($r.Bottom - $r.Top))
  $preset = if ($landscapeNow) { 0 } else { 2 }
  AdbDo "emu resize-display $preset"
}

function Lighten($col, $amt) {
  [System.Drawing.Color]::FromArgb(
    [Math]::Min(255, [int]$col.R + $amt),
    [Math]::Min(255, [int]$col.G + $amt),
    [Math]::Min(255, [int]$col.B + $amt))
}
$CHROME = 34         # emulator title-bar height, approx (also used by Toggle-Zoom)
$script:preZoom       = $null
$script:pendingAction = $null
$script:pendingCell   = $null
$script:pendingShot   = $false
$script:flashCtl      = $null
$script:flashBase     = $null
$script:flashUntil    = [DateTime]::MinValue
$script:shotCtl       = $null
$script:shotUntil     = [DateTime]::MinValue

$script:emuPid = 0
function Get-EmuHandle {
  $p = Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue |
       Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if ($p) { $script:emuPid = $p.Id; return $p.MainWindowHandle }
  $script:emuPid = 0; return [IntPtr]::Zero
}
function Get-ToolbarHandle($mainHandle) {
  $emuPids = @(Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
  $cb = [Win+EnumProc]{
    param($h, $l)
    $p = 0; [Win]::GetWindowThreadProcessId($h, [ref]$p) | Out-Null
    if ($emuPids -contains $p -and $h -ne $mainHandle) {
      $sb = New-Object System.Text.StringBuilder 256
      [Win]::GetClassName($h, $sb, 256) | Out-Null
      if ($sb.ToString() -match 'Tool' -and [Win]::GetWindow($h, 4) -eq $mainHandle) {
        $rc = New-Object Win+RECT; [Win]::GetWindowRect($h, [ref]$rc) | Out-Null
        $w = $rc.Right - $rc.Left; $ht = $rc.Bottom - $rc.Top
        if ($w -gt 20 -and $w -lt 160 -and $ht -gt 100) { $script:tbFound = $h }
      }
    }
    return $true
  }
  $script:tbFound = [IntPtr]::Zero
  [Win]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
  return $script:tbFound
}
function Get-WorkArea($h) {
  $mi = New-Object Win+MONITORINFO
  $mi.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($mi)
  [Win]::GetMonitorInfo([Win]::MonitorFromWindow($h,2), [ref]$mi) | Out-Null
  return $mi.rcWork
}
function Set-WinRect($h, $x, $y, $w, $ht) {
  # SWP_NOZORDER 0x4 | SWP_NOACTIVATE 0x10
  [Win]::SetWindowPos($h, [IntPtr]::Zero, $x, $y, $w, $ht, 0x14) | Out-Null
  Start-Sleep -Milliseconds 60
  $chk = New-Object Win+RECT; [Win]::GetWindowRect($h, [ref]$chk) | Out-Null
  $gw = $chk.Right - $chk.Left; $gh = $chk.Bottom - $chk.Top
  if ([Math]::Abs($gw - $w) -gt 8 -or [Math]::Abs($gh - $ht) -gt 8) {
    [Win]::MoveWindow($h, $x, $y, $w, $ht, $true) | Out-Null   # retry
  }
}
function Toggle-Zoom {
  $h = Get-EmuHandle
  if ($h -eq [IntPtr]::Zero) { return }
  $r = New-Object Win+RECT; [Win]::GetWindowRect($h,[ref]$r) | Out-Null
  $curH = $r.Bottom - $r.Top
  if ($curH -le $CHROME) { return }
  $wa = Get-WorkArea $h
  $availW = $wa.Right - $wa.Left; $availH = $wa.Bottom - $wa.Top
  if ($script:preZoom) {
    $p = $script:preZoom
    Set-WinRect $h $p.Left $p.Top ($p.Right - $p.Left) ($p.Bottom - $p.Top)
    $script:preZoom = $null
  } else {
    $script:preZoom = $r
    # The emulator locks the window to the virtual screen's aspect, so "fill" =
    # as tall as the work area, width following, centred. Ask a bit wider/taller
    # than needed and let the emulator clamp to its aspect.
    Set-WinRect $h $wa.Left $wa.Top $availW $availH
    Start-Sleep -Milliseconds 250
    $g = New-Object Win+RECT; [Win]::GetWindowRect($h,[ref]$g) | Out-Null
    $gw = $g.Right - $g.Left; $gh = $g.Bottom - $g.Top
    $nx = $wa.Left + [int]((($wa.Right - $wa.Left) - $gw) / 2)
    $ny = $wa.Top  + [int]((($wa.Bottom - $wa.Top) - $gh) / 2)
    if ($ny -lt $wa.Top) { $ny = $wa.Top }
    Set-WinRect $h $nx $ny $gw $gh
  }
}

# ---------- the strip: cells (glyph + tooltip + action) and dividers ----------
$MDL = 'Segoe MDL2 Assets'
$CELLW  = 46        # strip width
$CELLH  = 42        # cell height
$DIV    = 9         # divider height
$OVERLAP = 8        # how far the strip's left edge sits inside the window's right edge
$GLYPH_PT = 15
$G_CAM   = [char]0xE722
$G_TICK  = [char]0xE73E
$C_BASE  = [System.Drawing.Color]::FromArgb(24,28,38)
$C_HOVER = [System.Drawing.Color]::FromArgb(55,63,82)
$C_PWR   = [System.Drawing.Color]::FromArgb(150,45,58)   # power hover: muted red
$C_FILL  = [System.Drawing.Color]::FromArgb(37,99,235)   # fill-screen: always blue
$C_QUIT  = [System.Drawing.Color]::FromArgb(120,32,42)   # close-emulator: always dark red
$C_QUITH = [System.Drawing.Color]::FromArgb(176,48,60)   # close-emulator hover
$C_LINE  = [System.Drawing.Color]::FromArgb(58,65,82)
$C_EDGE  = [System.Drawing.Color]::FromArgb(70,78,98)

$cells = @(
  [pscustomobject]@{ Kind='cell'; Glyph=[char]0xE921; Tip='Minimize'   ; Hover=$C_HOVER; Fill=$C_BASE; Shot=$false; Do={ if ($script:emuHwnd -and [Win]::IsWindow($script:emuHwnd)) { [Win]::ShowWindow($script:emuHwnd, 6) | Out-Null } } }
  [pscustomobject]@{ Kind='cell'; Glyph=[char]0xE922; Tip='Maximize / restore'; Hover=$C_HOVER; Fill=$C_BASE; Shot=$false; Do={ Toggle-Zoom } }
  [pscustomobject]@{ Kind='div' }
  [pscustomobject]@{ Kind='cell'; Glyph=[char]0xE72B; Tip='Back'        ; Hover=$C_HOVER; Fill=$C_BASE; Shot=$false; Do={ AdbDo 'shell input keyevent 4'   } }
  [pscustomobject]@{ Kind='cell'; Glyph=[char]0xE80F; Tip='Home'        ; Hover=$C_HOVER; Fill=$C_BASE; Shot=$false; Do={ AdbDo 'shell input keyevent 3'   } }
  [pscustomobject]@{ Kind='cell'; Glyph=[char]0xE7C4; Tip='Recent apps' ; Hover=$C_HOVER; Fill=$C_BASE; Shot=$false; Do={ AdbDo 'shell input keyevent 187' } }
  [pscustomobject]@{ Kind='cell'; Glyph=[char]0xE711; Tip='Close current app'; Hover=$C_HOVER; Fill=$C_BASE; Shot=$false; Do={ Close-Foreground } }
  [pscustomobject]@{ Kind='div' }
  [pscustomobject]@{ Kind='cell'; Glyph=[char]0xE992; Tip='Volume down' ; Hover=$C_HOVER; Fill=$C_BASE; Shot=$false; Do={ AdbDo 'shell input keyevent 25'  } }
  [pscustomobject]@{ Kind='cell'; Glyph=[char]0xE995; Tip='Volume up'   ; Hover=$C_HOVER; Fill=$C_BASE; Shot=$false; Do={ AdbDo 'shell input keyevent 24'  } }
  [pscustomobject]@{ Kind='div' }
  [pscustomobject]@{ Kind='cell'; Glyph=[char]0xE7AD; Tip='Rotate (portrait / landscape)'; Hover=$C_HOVER; Fill=$C_BASE; Shot=$false; Do={ Toggle-Rotation } }
  [pscustomobject]@{ Kind='cell'; Glyph=$G_CAM;       Tip='Screenshot -> Pictures\Emulator'; Hover=$C_HOVER; Fill=$C_BASE; Shot=$true; Do={ AdbDo ("emu screenrecord screenshot `"{0}`"" -f $script:shotDir) } }
  [pscustomobject]@{ Kind='div' }
  [pscustomobject]@{ Kind='cell'; Glyph=[char]0xE7E8; Tip='Power'       ; Hover=$C_PWR;   Fill=$C_BASE; Shot=$false; Do={ AdbDo 'shell input keyevent 26'  } }
  [pscustomobject]@{ Kind='div' }
  [pscustomobject]@{ Kind='cell'; Glyph=[char]0xE8BB; Tip='Close the emulator'; Hover=$C_QUITH; Fill=$C_QUIT; Shot=$false; Do={ AdbDo 'emu kill' } }
)

$barH = 0
foreach ($x in $cells) { if ($x.Kind -eq 'div') { $barH += $DIV } else { $barH += $CELLH } }

$tips = New-Object System.Windows.Forms.ToolTip

$bar = New-Object System.Windows.Forms.Form
$bar.AutoScaleMode   = [System.Windows.Forms.AutoScaleMode]::None
$bar.FormBorderStyle = 'None'
$bar.StartPosition   = 'Manual'
$bar.TopMost         = $true
$bar.ShowInTaskbar   = $false
$bar.ClientSize      = New-Object System.Drawing.Size($CELLW, $barH)
$bar.BackColor       = $C_BASE
$bar.Opacity         = 1.0
$bar.Add_Paint({
  param($s, $e)
  $pen = New-Object System.Drawing.Pen($C_EDGE, 1)
  $e.Graphics.DrawRectangle($pen, 0, 0, ($s.Width - 1), ($s.Height - 1))
  $pen.Dispose()
}.GetNewClosure())

$script:CELLW    = $CELLW
$script:barX     = -99999   # screen-space top-left of the bar (-99999 = hidden)
$script:barY     = -99999
$script:cellRects = @()
$yoff = 0
foreach ($x in $cells) {
  if ($x.Kind -eq 'div') {
    $line = New-Object System.Windows.Forms.Panel
    $line.Size      = New-Object System.Drawing.Size(($CELLW - 16), 1)
    $line.Location  = New-Object System.Drawing.Point(8, ($yoff + [int]($DIV/2)))
    $line.BackColor = $C_LINE
    $bar.Controls.Add($line)
    $yoff += $DIV
    continue
  }
  $c = New-Object System.Windows.Forms.Label
  $c.AutoSize  = $false
  $c.Size      = New-Object System.Drawing.Size($CELLW, $CELLH)
  $c.Location  = New-Object System.Drawing.Point(0, $yoff)
  $c.Text      = $x.Glyph
  $c.Font      = New-Object System.Drawing.Font($MDL, $GLYPH_PT)
  $c.ForeColor = [System.Drawing.Color]::White
  $c.TextAlign = 'MiddleCenter'
  $c.BackColor = $x.Fill
  $tips.SetToolTip($c, $x.Tip)
  $hoverCol = $x.Hover; $baseCol = $x.Fill; $doRef = $x.Do; $cellCtl = $c; $isShot = [bool]$x.Shot
  $c.Add_Click({
    $script:pendingAction = $doRef
    $script:pendingCell   = $cellCtl
    $script:pendingShot   = $isShot
  }.GetNewClosure())
  $c.Add_MouseEnter({ if ($script:flashCtl -ne $this) { $this.BackColor = $hoverCol } }.GetNewClosure())
  $c.Add_MouseLeave({ if ($script:flashCtl -ne $this) { $this.BackColor = $baseCol } }.GetNewClosure())
  $bar.Controls.Add($c)
  $script:cellRects += [pscustomobject]@{ Off=$yoff; H=$CELLH; Do=$x.Do; Ctl=$c; Shot=[bool]$x.Shot }
  $yoff += $CELLH
}

# ---------- low-level mouse hook: click in a cell -> queue its action ----------
# Hit-tests against the bar's current screen position ($script:barX/Y) + the
# fixed per-cell offsets, so a window drag never has to rebuild anything.
$WH_MOUSE_LL  = 14
$WM_LBUTTONUP = 0x0202
$script:lastFire = [DateTime]::MinValue
$script:hookProc = [Win+HookProc]{
  param($code, $wParam, $lParam)
  if ($code -ge 0 -and [int]$wParam -eq $WM_LBUTTONUP -and $script:barX -gt -99999) {
    if (([DateTime]::Now - $script:lastFire).TotalMilliseconds -gt 300) {
      $m = [Runtime.InteropServices.Marshal]::PtrToStructure($lParam, [type]([Win+MSLLHOOKSTRUCT]))
      $relX = $m.x - $script:barX
      if ($relX -ge 0 -and $relX -le $script:CELLW) {
        $relY = $m.y - $script:barY
        foreach ($cl in $script:cellRects) {
          if ($relY -ge $cl.Off -and $relY -lt ($cl.Off + $cl.H)) {
            $script:lastFire      = [DateTime]::Now
            $script:pendingAction = $cl.Do
            $script:pendingCell   = $cl.Ctl
            $script:pendingShot   = $cl.Shot
            break
          }
        }
      }
    }
  }
  return [Win]::CallNextHookEx([IntPtr]::Zero, $code, $wParam, $lParam)
}
$hMod = [Win]::GetModuleHandle('user32.dll')
$script:hookId = [Win]::SetWindowsHookEx($WH_MOUSE_LL, $script:hookProc, $hMod, 0)

# ---------- follow the emulator window ----------
# Position tracking is driven by an OS window-move event (SetWinEventHook), so
# the bar moves the instant the window does - no polling, ~0 idle CPU. A slow
# timer handles only the housekeeping (show/hide by focus, re-assert topmost,
# keep the emulator's own toolbar hidden, notice the emulator quitting).
$script:emuHwnd  = [IntPtr]::Zero
$script:slowCtr  = 0
$script:waTop    = 0
$script:waBottom = 1000000
$script:weHook   = [IntPtr]::Zero

function Move-Bar {
  if ($script:emuHwnd -eq [IntPtr]::Zero -or -not [Win]::IsWindow($script:emuHwnd)) { return }
  $r = New-Object Win+RECT; [Win]::GetWindowRect($script:emuHwnd,[ref]$r) | Out-Null
  $cx = $r.Right - $OVERLAP
  $cy = $r.Top + $CHROME
  if ($cy + $barH -gt $script:waBottom) { $cy = [Math]::Max($script:waTop, $script:waBottom - $barH) }
  if ($cx -ne $script:barX -or $cy -ne $script:barY) {
    # SWP_SHOWWINDOW | SWP_NOACTIVATE, inserted after HWND_TOPMOST
    [Win]::SetWindowPos($bar.Handle, [IntPtr](-1), $cx, $cy, $script:CELLW, $barH, 0x50) | Out-Null
    $script:barX = $cx; $script:barY = $cy
  }
}

# EVENT_OBJECT_LOCATIONCHANGE = 0x800B ; only care about the window itself (idObj 0)
$script:weProc = [Win+WinEventProc]{
  param($hHook, $ev, $hwnd, $idObj, $idChild, $thread, $time)
  if ($idObj -eq 0 -and $hwnd -eq $script:emuHwnd -and $script:barX -gt -99999) { Move-Bar }
}
function Hook-WinEvent {
  if ($script:weHook -ne [IntPtr]::Zero) { [Win]::UnhookWinEvent($script:weHook) | Out-Null; $script:weHook = [IntPtr]::Zero }
  if ($script:emuPid -ne 0) {
    $script:weHook = [Win]::SetWinEventHook(0x800B, 0x800B, [IntPtr]::Zero, $script:weProc, [uint32]$script:emuPid, 0, 0)
  }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 120   # housekeeping only - position tracking is on the WinEvent hook
$timer.Add_Tick({
  # --- fire a queued action + press flash + screenshot tick ---
  if ($script:pendingAction) {
    $a = $script:pendingAction; $cc = $script:pendingCell; $sh = $script:pendingShot
    $script:pendingAction = $null; $script:pendingCell = $null; $script:pendingShot = $false
    if ($cc) {
      $script:flashCtl   = $cc
      $script:flashBase  = $cc.BackColor
      $script:flashUntil = [DateTime]::Now.AddMilliseconds(170)
      $cc.BackColor = (Lighten $cc.BackColor 75)
    }
    & $a
    if ($sh -and $cc) { $script:shotCtl = $cc; $script:shotUntil = [DateTime]::Now.AddMilliseconds(1100); $cc.Text = $G_TICK }
  }
  if ($script:flashCtl -and [DateTime]::Now -gt $script:flashUntil) {
    $script:flashCtl.BackColor = $script:flashBase; $script:flashCtl = $null
  }
  if ($script:shotCtl -and [DateTime]::Now -gt $script:shotUntil) {
    $script:shotCtl.Text = $G_CAM; $script:shotCtl = $null
  }

  $script:slowCtr++

  # --- (re)acquire the window handle only when the cached one went invalid ---
  if ($script:emuHwnd -eq [IntPtr]::Zero -or -not [Win]::IsWindow($script:emuHwnd)) {
    $script:emuHwnd = Get-EmuHandle   # also sets $script:emuPid
    if ($script:emuHwnd -eq [IntPtr]::Zero) {
      if ($script:weHook -ne [IntPtr]::Zero) { [Win]::UnhookWinEvent($script:weHook) | Out-Null }
      if ($script:toolbar -and [Win]::IsWindow($script:toolbar)) { [Win]::ShowWindow($script:toolbar, 5) | Out-Null }
      if ($script:hookId -ne [IntPtr]::Zero) { [Win]::UnhookWindowsHookEx($script:hookId) | Out-Null }
      $bar.Close(); return
    }
    Hook-WinEvent
    $script:barX = -99999
  }
  $h = $script:emuHwnd

  if ([Win]::IsIconic($h) -or -not [Win]::IsWindowVisible($h)) {
    if ($bar.Visible) { $bar.Visible = $false }
    $script:barX = -99999
    return
  }
  # only ride along while the emulator (or our own bar) is the active window
  $fg = [Win]::GetForegroundWindow()
  $fgPid = 0; [Win]::GetWindowThreadProcessId($fg, [ref]$fgPid) | Out-Null
  if ($fgPid -ne $script:emuPid -and $fgPid -ne $PID) {
    if ($bar.Visible) { $bar.Visible = $false }
    $script:barX = -99999
    return
  }

  if ($script:slowCtr % 16 -eq 1) {
    $wa = Get-WorkArea $h; $script:waTop = $wa.Top; $script:waBottom = $wa.Bottom
  }
  if (-not $bar.Visible) { $bar.Visible = $true; $script:barX = -99999 }
  Move-Bar
  # re-assert topmost (a plain TopMost form can fall behind on focus changes)
  [Win]::SetWindowPos($bar.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x13) | Out-Null

  # --- keep the emulator's own toolbar hidden (throttled - EnumWindows) ---
  if ($script:slowCtr % 8 -eq 0 -or -not ($script:toolbar -and [Win]::IsWindow($script:toolbar))) {
    $t = Get-ToolbarHandle $h
    if ($t -ne [IntPtr]::Zero) { $script:toolbar = $t }
  }
  if ($script:toolbar -and [Win]::IsWindow($script:toolbar) -and [Win]::IsWindowVisible($script:toolbar)) {
    [Win]::ShowWindow($script:toolbar, 0) | Out-Null   # SW_HIDE
  }
})

for ($i = 0; $i -lt 120; $i++) { if ((Get-EmuHandle) -ne [IntPtr]::Zero) { break }; Start-Sleep -Milliseconds 500 }
$script:emuHwnd = Get-EmuHandle
if ($script:emuHwnd -eq [IntPtr]::Zero) { exit }
Hook-WinEvent

$r0 = New-Object Win+RECT; [Win]::GetWindowRect($script:emuHwnd,[ref]$r0) | Out-Null
$bar.Location = New-Object System.Drawing.Point(($r0.Right - $OVERLAP), ($r0.Top + $CHROME))
$script:barX = $r0.Right - $OVERLAP; $script:barY = $r0.Top + $CHROME
$timer.Start()
$bar.Show()
[System.Windows.Forms.Application]::Run($bar)
if ($script:weHook -ne [IntPtr]::Zero) { [Win]::UnhookWinEvent($script:weHook) | Out-Null }
if ($script:toolbar -and [Win]::IsWindow($script:toolbar)) { [Win]::ShowWindow($script:toolbar, 5) | Out-Null }
if ($script:hookId -ne [IntPtr]::Zero) { [Win]::UnhookWindowsHookEx($script:hookId) | Out-Null }
