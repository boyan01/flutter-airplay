# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$iconPath = Join-Path $PSScriptRoot '../runner/resources/app_icon.ico'
$icon = New-Object Drawing.Icon($iconPath, 256, 256)
$mark = $icon.ToBitmap()
$bitmap = New-Object Drawing.Bitmap(656, 1256)
$graphics = [Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$gradient = New-Object Drawing.Drawing2D.LinearGradientBrush(
    (New-Object Drawing.Rectangle(0, 0, 656, 1256)),
    [Drawing.ColorTranslator]::FromHtml('#32958A'),
    [Drawing.ColorTranslator]::FromHtml('#124B46'), 70.0)
$pen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(28, 255, 255, 255), 2)
$brush = New-Object Drawing.SolidBrush([Drawing.ColorTranslator]::FromHtml('#FFFDF7'))
$font = New-Object Drawing.Font('Segoe UI', 33, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
$small = $null
$smallGraphics = $null
try {
    $graphics.FillRectangle($gradient, 0, 0, 656, 1256)
    foreach ($diameter in @(430, 640, 850)) {
        $graphics.DrawEllipse($pen, (656 - $diameter) / 2, 365 - $diameter / 2, $diameter, $diameter)
    }
    $graphics.DrawImage($mark, 184, 221, 288, 288)
    $graphics.DrawString('Flutter AirPlay', $font, $brush, 85, 666)
    $graphics.DrawLine($pen, 85, 740, 571, 740)
    $bitmap.Save((Join-Path $OutputDirectory 'wizard.png'), [Drawing.Imaging.ImageFormat]::Png)
    $small = New-Object Drawing.Bitmap(128, 128)
    $smallGraphics = [Drawing.Graphics]::FromImage($small)
    $smallGraphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $smallGraphics.DrawImage($mark, 0, 0, 128, 128)
    $small.Save((Join-Path $OutputDirectory 'wizard-small.png'), [Drawing.Imaging.ImageFormat]::Png)
} finally {
    if ($smallGraphics) { $smallGraphics.Dispose() }
    if ($small) { $small.Dispose() }
    $font.Dispose(); $brush.Dispose(); $pen.Dispose(); $gradient.Dispose()
    $graphics.Dispose(); $bitmap.Dispose(); $mark.Dispose(); $icon.Dispose()
}
