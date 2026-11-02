# Draws the app icon and writes:
#   assets/icon-1024.png            (source for the macOS .icns)
#   windows/TransformTo/app.ico     (16..256 px, PNG-compressed entries)
#   windows/ShellExtension/Assets/  (package logos)
# Run with Windows PowerShell:  powershell -ExecutionPolicy Bypass -File assets\make-icon.ps1
Add-Type -AssemblyName System.Drawing

function New-IconBitmap([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)

    # Rounded square with a diagonal gradient.
    $s = [float]$size
    $r = $s * 0.22
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $r * 2, $r * 2, 180, 90)
    $path.AddArc($s - $r * 2 - 1, 0, $r * 2, $r * 2, 270, 90)
    $path.AddArc($s - $r * 2 - 1, $s - $r * 2 - 1, $r * 2, $r * 2, 0, 90)
    $path.AddArc(0, $s - $r * 2 - 1, $r * 2, $r * 2, 90, 90)
    $path.CloseFigure()
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.PointF 0, 0), (New-Object System.Drawing.PointF $s, $s), ([System.Drawing.Color]::FromArgb(255, 79, 70, 229)), ([System.Drawing.Color]::FromArgb(255, 168, 85, 247))
    $g.FillPath($brush, $path)

    # Two opposing arrows: "this format <-> that format".
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), ($s * 0.085)
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
    $l = $s * 0.24; $rt = $s * 0.76; $y1 = $s * 0.37; $y2 = $s * 0.63; $h = $s * 0.13
    $g.DrawLine($pen, $l, $y1, $rt, $y1)
    $g.DrawLines($pen, [System.Drawing.PointF[]]@((New-Object System.Drawing.PointF ($rt - $h), ($y1 - $h)), (New-Object System.Drawing.PointF $rt, $y1), (New-Object System.Drawing.PointF ($rt - $h), ($y1 + $h))))
    $g.DrawLine($pen, $rt, $y2, $l, $y2)
    $g.DrawLines($pen, [System.Drawing.PointF[]]@((New-Object System.Drawing.PointF ($l + $h), ($y2 - $h)), (New-Object System.Drawing.PointF $l, $y2), (New-Object System.Drawing.PointF ($l + $h), ($y2 + $h))))
    $g.Dispose()
    return $bmp
}

function Get-PngBytes($bmp) {
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    return $ms.ToArray()
}

$root = Split-Path $PSScriptRoot -Parent

$big = New-IconBitmap 1024
$big.Save((Join-Path $PSScriptRoot 'icon-1024.png'), [System.Drawing.Imaging.ImageFormat]::Png)

# Logos the Windows 11 sparse package manifest requires.
$packageAssets = Join-Path $root 'windows\ShellExtension\Assets'
New-Item -ItemType Directory -Force $packageAssets | Out-Null
foreach ($asset in @(@{ Name = 'Square44x44Logo.png'; Size = 44 }, @{ Name = 'Square150x150Logo.png'; Size = 150 }, @{ Name = 'StoreLogo.png'; Size = 50 })) {
    (New-IconBitmap $asset.Size).Save((Join-Path $packageAssets $asset.Name), [System.Drawing.Imaging.ImageFormat]::Png)
}

$sizes = 16, 24, 32, 48, 64, 128, 256
$images = foreach ($size in $sizes) { , (Get-PngBytes (New-IconBitmap $size)) }

$out = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter $out
$w.Write([UInt16]0); $w.Write([UInt16]1); $w.Write([UInt16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([UInt16]1); $w.Write([UInt16]32)
    $w.Write([UInt32]$images[$i].Length); $w.Write([UInt32]$offset)
    $offset += $images[$i].Length
}
foreach ($img in $images) { $w.Write([byte[]]$img, 0, $img.Length) }
[System.IO.File]::WriteAllBytes((Join-Path $root 'windows\TransformTo\app.ico'), $out.ToArray())
Write-Host "Icons written."
