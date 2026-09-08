Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase
$ErrorActionPreference = 'Stop'

function New-Mark {
    # Posaba mark in a 1024x1024 coordinate space, returns a DrawingGroup
    $dg = New-Object System.Windows.Media.DrawingGroup

    function Add-Stroke([string]$data, [string]$hex, [double]$w) {
        $geo = [System.Windows.Media.Geometry]::Parse($data)
        $pen = New-Object System.Windows.Media.Pen ([System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString($hex))), $w
        $pen.StartLineCap = 'Round'; $pen.EndLineCap = 'Round'; $pen.LineJoin = 'Round'
        $gd = New-Object System.Windows.Media.GeometryDrawing ($null, $pen, $geo)
        $dg.Children.Add($gd) | Out-Null
    }
    function Add-Fill([string]$data, [string]$hex) {
        $geo = [System.Windows.Media.Geometry]::Parse($data)
        $br  = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString($hex))
        $gd  = New-Object System.Windows.Media.GeometryDrawing ($br, $null, $geo)
        $dg.Children.Add($gd) | Out-Null
    }

    Add-Stroke 'M118,686 Q512,1074 906,686' '#7C3AED' 84

    Add-Stroke 'M328,512 L224,880 M328,512 L432,880 M286,748 L370,748' '#22B8E0' 72
    Add-Fill   'M234,392 A94,94 0 1 1 422,392 A94,94 0 1 1 234,392 Z' '#22B8E0'

    Add-Stroke 'M696,512 L592,880 M696,512 L800,880 M654,748 L738,748' '#7C3AED' 72
    Add-Fill   'M602,392 A94,94 0 1 1 790,392 A94,94 0 1 1 602,392 Z' '#7C3AED'

    Add-Stroke 'M512,286 L378,892 M512,286 L646,892 M446,626 L578,626' '#14A098' 92
    Add-Fill   'M390,178 A122,122 0 1 1 634,178 A122,122 0 1 1 390,178 Z' '#14A098'

    return $dg
}

function Render-Png([int]$size, [string]$out, [string]$mode) {
    # mode: 'square' (white rounded bg), 'round' (white circle bg), 'fg' (transparent, adaptive safe zone)
    $vis = New-Object System.Windows.Media.DrawingVisual
    $dc  = $vis.RenderOpen()

    $mark = New-Mark

    if ($mode -eq 'square') {
        $bg = New-Object System.Windows.Media.RectangleGeometry ((New-Object System.Windows.Rect 0,0,$size,$size)), ($size*0.22), ($size*0.22)
        $dc.DrawGeometry([System.Windows.Media.Brushes]::White, $null, $bg)
        $scale = ($size * 0.70) / 1024.0
        $off = ($size - 1024.0*$scale) / 2.0
    } elseif ($mode -eq 'round') {
        $bg = New-Object System.Windows.Media.EllipseGeometry ((New-Object System.Windows.Point ($size/2.0),($size/2.0))), ($size/2.0), ($size/2.0)
        $dc.DrawGeometry([System.Windows.Media.Brushes]::White, $null, $bg)
        $scale = ($size * 0.62) / 1024.0
        $off = ($size - 1024.0*$scale) / 2.0
    } else {
        # adaptive foreground: 108dp canvas, art must sit within centre ~66dp -> ~0.50 of canvas
        $scale = ($size * 0.52) / 1024.0
        $off = ($size - 1024.0*$scale) / 2.0
    }

    $tg = New-Object System.Windows.Media.TransformGroup
    $tg.Children.Add((New-Object System.Windows.Media.ScaleTransform $scale,$scale)) | Out-Null
    $tg.Children.Add((New-Object System.Windows.Media.TranslateTransform $off,$off)) | Out-Null
    $dc.PushTransform($tg)
    $dc.DrawDrawing($mark)
    $dc.Pop()
    $dc.Close()

    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap ($size, $size, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($vis)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb)) | Out-Null
    $fs = [System.IO.File]::Create($out)
    $enc.Save($fs); $fs.Close()
    Write-Host "  $out ($size)"
}

$res = $args[0]
$dens = @{ 'mdpi'=1; 'hdpi'=1.5; 'xhdpi'=2; 'xxhdpi'=3; 'xxxhdpi'=4 }
foreach ($d in $dens.Keys) {
    $m = $dens[$d]
    $dir = Join-Path $res "mipmap-$d"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Render-Png ([int](48*$m))  (Join-Path $dir 'ic_launcher.png')            'square'
    Render-Png ([int](48*$m))  (Join-Path $dir 'ic_launcher_round.png')      'round'
    Render-Png ([int](108*$m)) (Join-Path $dir 'ic_launcher_foreground.png') 'fg'
}
Write-Host "done"
