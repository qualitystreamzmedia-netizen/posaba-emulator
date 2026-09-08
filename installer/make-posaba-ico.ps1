param([string]$Out)
Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase
$ErrorActionPreference = 'Stop'

$strokes = @(
  @('M118,686 Q512,1074 906,686', '#7C3AED', 84),
  @('M328,512 L224,880 M328,512 L432,880 M286,748 L370,748', '#22B8E0', 72),
  @('M696,512 L592,880 M696,512 L800,880 M654,748 L738,748', '#7C3AED', 72),
  @('M512,286 L378,892 M512,286 L646,892 M446,626 L578,626', '#14A098', 92)
)
$fills = @(
  @('M234,392 A94,94 0 1 1 422,392 A94,94 0 1 1 234,392 Z', '#22B8E0'),
  @('M602,392 A94,94 0 1 1 790,392 A94,94 0 1 1 602,392 Z', '#7C3AED'),
  @('M390,178 A122,122 0 1 1 634,178 A122,122 0 1 1 390,178 Z', '#14A098')
)
# draw order: arc, cyan legs, cyan head, violet legs, violet head, teal legs, teal head
$order = @(
  @('s',0), @('s',1), @('f',0), @('s',2), @('f',1), @('s',3), @('f',2)
)

function Render-Png([int]$size) {
  $vis = New-Object System.Windows.Media.DrawingVisual
  $dc  = $vis.RenderOpen()

  $bgRect = New-Object System.Windows.Rect 0, 0, $size, $size
  $bg = New-Object System.Windows.Media.RectangleGeometry $bgRect, ($size * 0.22), ($size * 0.22)
  $dc.DrawGeometry([System.Windows.Media.Brushes]::White, $null, $bg)

  $scale = ($size * 0.72) / 1024.0
  $off   = ($size - 1024.0 * $scale) / 2.0
  $tg = New-Object System.Windows.Media.TransformGroup
  $null = $tg.Children.Add((New-Object System.Windows.Media.ScaleTransform $scale, $scale))
  $null = $tg.Children.Add((New-Object System.Windows.Media.TranslateTransform $off, $off))
  $dc.PushTransform($tg)

  foreach ($step in $order) {
    if ($step[0] -eq 's') {
      $d = $strokes[$step[1]]
      $brush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($d[1]))
      $pen = New-Object System.Windows.Media.Pen $brush, ([double]$d[2])
      $pen.StartLineCap = 'Round'; $pen.EndLineCap = 'Round'; $pen.LineJoin = 'Round'
      $dc.DrawGeometry($null, $pen, [System.Windows.Media.Geometry]::Parse($d[0]))
    } else {
      $d = $fills[$step[1]]
      $brush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($d[1]))
      $dc.DrawGeometry($brush, $null, [System.Windows.Media.Geometry]::Parse($d[0]))
    }
  }

  $dc.Pop()
  $dc.Close()

  $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap $size, $size, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
  $rtb.Render($vis)

  if ($size -ge 64) {
    # PNG frame (Vista+)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $null = $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $ms = New-Object System.IO.MemoryStream
    $enc.Save($ms)
    return , $ms.ToArray()
  }

  # BMP/DIB frame (max compatibility for small sizes)
  $stride = $size * 4
  $top = New-Object 'byte[]' ($stride * $size)
  $rtb.CopyPixels($top, $stride, 0)          # BGRA, top-down
  $ms = New-Object System.IO.MemoryStream
  $bw2 = New-Object System.IO.BinaryWriter $ms
  $bw2.Write([uint32]40); $bw2.Write([int32]$size); $bw2.Write([int32]($size * 2))
  $bw2.Write([uint16]1); $bw2.Write([uint16]32); $bw2.Write([uint32]0)
  $bw2.Write([uint32]0); $bw2.Write([int32]0); $bw2.Write([int32]0)
  $bw2.Write([uint32]0); $bw2.Write([uint32]0)
  for ($y = $size - 1; $y -ge 0; $y--) { $bw2.Write($top, $y * $stride, $stride) }   # bottom-up
  $maskRow = [math]::Ceiling($size / 32.0) * 4
  $bw2.Write((New-Object 'byte[]' ($maskRow * $size)))                              # AND mask = all 0
  $bw2.Flush()
  return , $ms.ToArray()
}

$sizes = @(16, 24, 32, 48, 64, 128, 256)
$blobs = New-Object 'System.Collections.Generic.List[byte[]]'
foreach ($s in $sizes) {
  $bytes = Render-Png $s
  Write-Host ("  {0}px -> {1} bytes" -f $s, $bytes.Length)
  $blobs.Add($bytes)
}

$fs = [System.IO.File]::Create($Out)
$bw = New-Object System.IO.BinaryWriter $fs
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
  $s = $sizes[$i]; $b = $blobs[$i]
  $dim = [byte]($(if ($s -ge 256) { 0 } else { $s }))
  $bw.Write($dim); $bw.Write($dim); $bw.Write([byte]0); $bw.Write([byte]0)
  $bw.Write([uint16]1); $bw.Write([uint16]32)
  $bw.Write([uint32]$b.Length); $bw.Write([uint32]$offset)
  $offset += $b.Length
}
foreach ($b in $blobs) { $bw.Write($b, 0, $b.Length) }
$bw.Flush(); $fs.Close()
Write-Host "wrote $Out ($((Get-Item $Out).Length) bytes)"
