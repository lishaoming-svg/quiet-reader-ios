Add-Type -AssemblyName System.Drawing

$size = 1024
$bitmap = [System.Drawing.Bitmap]::new(
    $size,
    $size,
    [System.Drawing.Imaging.PixelFormat]::Format24bppRgb
)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

$paper = [System.Drawing.Color]::FromArgb(255, 246, 238, 216)
$ink = [System.Drawing.Color]::FromArgb(255, 21, 42, 50)
$paperLight = [System.Drawing.Color]::FromArgb(255, 255, 251, 238)
$vermilion = [System.Drawing.Color]::FromArgb(255, 178, 46, 31)
$graphics.Clear($paper)

$inkBrush = New-Object System.Drawing.SolidBrush($ink)
$paperBrush = New-Object System.Drawing.SolidBrush($paperLight)
$redBrush = New-Object System.Drawing.SolidBrush($vermilion)

$graphics.FillRectangle($inkBrush, 116, 116, 792, 792)
$graphics.FillPolygon($paperBrush, [System.Drawing.Point[]]@(
    (New-Object System.Drawing.Point(245, 260)),
    (New-Object System.Drawing.Point(500, 325)),
    (New-Object System.Drawing.Point(500, 760)),
    (New-Object System.Drawing.Point(245, 690))
))
$graphics.FillPolygon($paperBrush, [System.Drawing.Point[]]@(
    (New-Object System.Drawing.Point(524, 325)),
    (New-Object System.Drawing.Point(779, 260)),
    (New-Object System.Drawing.Point(779, 690)),
    (New-Object System.Drawing.Point(524, 760))
))
$graphics.FillRectangle($redBrush, 690, 670, 142, 142)

$font = New-Object System.Drawing.Font('Microsoft YaHei', 86, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$format = New-Object System.Drawing.StringFormat
$format.Alignment = [System.Drawing.StringAlignment]::Center
$format.LineAlignment = [System.Drawing.StringAlignment]::Center
$glyph = [string][char]0x58A8
$graphics.DrawString($glyph, $font, $paperBrush, (New-Object System.Drawing.RectangleF(690, 670, 142, 142)), $format)

$output = Join-Path $PSScriptRoot '..\App\Resources\Assets.xcassets\AppIcon.appiconset\AppIcon.png'
$bitmap.Save($output, [System.Drawing.Imaging.ImageFormat]::Png)

$format.Dispose()
$font.Dispose()
$redBrush.Dispose()
$paperBrush.Dispose()
$inkBrush.Dispose()
$graphics.Dispose()
$bitmap.Dispose()
