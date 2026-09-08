param(
  [string]$Src = 'C:\DissolversEmulator',
  [string]$Out = 'C:\Emulator\Dissolvers Emulator Distribution\PosabaEmulator.zip',
  [string]$BaseName = 'PosabaEmulator',
  [switch]$SkipSdk
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

# Regenerated-on-boot / bulky state we never ship. _run.cmd rebuilds these +
# reinstalls the apps on first launch.
$skip = @(
  'avd\Dissolvers.avd\snapshots',
  'avd\Dissolvers.avd\data',
  'avd\Dissolvers.avd\modem_simulator',
  'avd\Dissolvers.avd\tmpAdbCmds'
)
$skipFilePatterns = @(
  'userdata-qemu.img*', 'cache.img*', '*.qcow2', '*.lock',
  'hardware-qemu.ini', 'emulator-user.ini', 'multiinstance.lock'
)

function Skip($rel) {
  if ($SkipSdk -and ($rel -eq 'sdk' -or $rel.StartsWith('sdk\'))) { return $true }
  foreach ($d in $skip) { if ($rel -eq $d -or $rel.StartsWith($d + '\')) { return $true } }
  $leaf = Split-Path $rel -Leaf
  foreach ($p in $skipFilePatterns) { if ($leaf -like $p) { return $true } }
  return $false
}

if (Test-Path $Out) { Remove-Item $Out -Force }
New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null

$fs = [System.IO.File]::Create($Out)
$zip = New-Object System.IO.Compression.ZipArchive ($fs, [System.IO.Compression.ZipArchiveMode]::Create)
$srcFull = (Resolve-Path $Src).Path.TrimEnd('\')
$n = 0; $bytes = 0
Get-ChildItem -LiteralPath $srcFull -Recurse -File -Force | ForEach-Object {
  $rel = $_.FullName.Substring($srcFull.Length + 1)
  if (Skip $rel) { return }
  $entryName = "$BaseName/" + ($rel -replace '\\', '/')
  try {
    $e = $zip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
    $es = $e.Open()
    $in = [System.IO.File]::OpenRead($_.FullName)
    $in.CopyTo($es)
    $in.Close(); $es.Close()
    $n++; $bytes += $_.Length
    if ($n % 25 -eq 0) { Write-Host ("  {0} files, {1:N0} MB in" -f $n, ($bytes / 1MB)) }
  } catch { Write-Host "  skip (locked): $rel" }
}
$zip.Dispose(); $fs.Close()
Write-Host ("done: {0} - {1} files, {2:N0} MB -> {3:N0} MB zip" -f $Out, $n, ($bytes/1MB), ((Get-Item $Out).Length/1MB))
