param(
    [string]$PackageAssetRoot,
    [string]$DesktopAssetRoot
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class PassportWindowsNativeMethods
{
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool DestroyIcon(IntPtr handle);
}
"@

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

if (-not $PackageAssetRoot) {
    $PackageAssetRoot = Join-Path $repoRoot "src\ArchrealmsPassport.Windows.Package\Assets"
}

if (-not $DesktopAssetRoot) {
    $DesktopAssetRoot = Join-Path $repoRoot "src\ArchrealmsPassport.Windows\Assets"
}

New-Item -ItemType Directory -Force $PackageAssetRoot | Out-Null
New-Item -ItemType Directory -Force $DesktopAssetRoot | Out-Null

$midnightBlue = [System.Drawing.Color]::FromArgb(21, 37, 59)
$archGold = [System.Drawing.Color]::FromArgb(200, 160, 74)
$parchment = [System.Drawing.Color]::FromArgb(244, 233, 210)
$warmParchment = [System.Drawing.Color]::FromArgb(255, 249, 241)
$transparent = [System.Drawing.Color]::FromArgb(0, 0, 0, 0)

function New-Font {
    param(
        [string]$Family,
        [float]$Size,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular
    )

    return [System.Drawing.Font]::new($Family, $Size, $Style, [System.Drawing.GraphicsUnit]::Pixel)
}

function New-Canvas {
    param(
        [int]$Width,
        [int]$Height
    )

    return New-Object System.Drawing.Bitmap $Width, $Height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
}

function Draw-OrderEmblem {
    param(
        [System.Drawing.Graphics]$Graphics,
        [double]$CenterX,
        [double]$CenterY,
        [double]$Diameter,
        [bool]$DrawField = $true,
        [double]$FieldScale = 1.0
    )

    $fieldDiameter = $Diameter * $FieldScale
    $fieldRadius = $fieldDiameter / 2.0
    $fieldX = $CenterX - $fieldRadius
    $fieldY = $CenterY - $fieldRadius

    if ($DrawField) {
        $fieldBrush = New-Object System.Drawing.SolidBrush $midnightBlue
        $Graphics.FillEllipse($fieldBrush, $fieldX, $fieldY, $fieldDiameter, $fieldDiameter)
        $fieldBrush.Dispose()
    }

    $ringPen = New-Object System.Drawing.Pen $archGold, ([float][Math]::Max($Diameter * 0.08, 2.0))
    $ringPen.Alignment = [System.Drawing.Drawing2D.PenAlignment]::Center
    $Graphics.DrawEllipse($ringPen,
        $CenterX - ($Diameter * 0.43),
        $CenterY - ($Diameter * 0.43),
        $Diameter * 0.86,
        $Diameter * 0.86)
    $ringPen.Dispose()

    $archPen = New-Object System.Drawing.Pen $archGold, ([float][Math]::Max($Diameter * 0.085, 2.0))
    $archPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $archPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $archPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round

    $innerArchPen = New-Object System.Drawing.Pen $archGold, ([float][Math]::Max($Diameter * 0.038, 1.0))
    $innerArchPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $innerArchPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $innerArchPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round

    $leftBaseX = $CenterX - ($Diameter * 0.18)
    $rightBaseX = $CenterX + ($Diameter * 0.18)
    $outerBaseY = $CenterY + ($Diameter * 0.25)
    $outerTopY = $CenterY - ($Diameter * 0.18)
    $outerArcRect = New-Object System.Drawing.RectangleF(
        [float]($CenterX - ($Diameter * 0.18)),
        [float]($CenterY - ($Diameter * 0.54)),
        [float]($Diameter * 0.36),
        [float]($Diameter * 0.72))
    $Graphics.DrawLine($archPen, [float]$leftBaseX, [float]$outerBaseY, [float]$leftBaseX, [float]$outerTopY)
    $Graphics.DrawLine($archPen, [float]$rightBaseX, [float]$outerBaseY, [float]$rightBaseX, [float]$outerTopY)
    $Graphics.DrawArc($archPen, $outerArcRect, 180, 180)

    $innerLeftBaseX = $CenterX - ($Diameter * 0.095)
    $innerRightBaseX = $CenterX + ($Diameter * 0.095)
    $innerBaseY = $CenterY + ($Diameter * 0.25)
    $innerTopY = $CenterY - ($Diameter * 0.08)
    $innerArcRect = New-Object System.Drawing.RectangleF(
        [float]($CenterX - ($Diameter * 0.095)),
        [float]($CenterY - ($Diameter * 0.35)),
        [float]($Diameter * 0.19),
        [float]($Diameter * 0.54))
    $Graphics.DrawLine($innerArchPen, [float]$innerLeftBaseX, [float]$innerBaseY, [float]$innerLeftBaseX, [float]$innerTopY)
    $Graphics.DrawLine($innerArchPen, [float]$innerRightBaseX, [float]$innerBaseY, [float]$innerRightBaseX, [float]$innerTopY)
    $Graphics.DrawArc($innerArchPen, $innerArcRect, 180, 180)

    $archPen.Dispose()
    $innerArchPen.Dispose()

    $starBrush = New-Object System.Drawing.SolidBrush $parchment
    $starPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $starRadius = $Diameter * 0.22
    $armWidth = $Diameter * 0.045
    $starPath.StartFigure()
    $starPath.AddPolygon(@(
        [System.Drawing.PointF]::new([float]$CenterX, [float]($CenterY - $starRadius)),
        [System.Drawing.PointF]::new([float]($CenterX + $armWidth), [float]($CenterY - $armWidth)),
        [System.Drawing.PointF]::new([float]($CenterX + $starRadius), [float]$CenterY),
        [System.Drawing.PointF]::new([float]($CenterX + $armWidth), [float]($CenterY + $armWidth)),
        [System.Drawing.PointF]::new([float]$CenterX, [float]($CenterY + $starRadius)),
        [System.Drawing.PointF]::new([float]($CenterX - $armWidth), [float]($CenterY + $armWidth)),
        [System.Drawing.PointF]::new([float]($CenterX - $starRadius), [float]$CenterY),
        [System.Drawing.PointF]::new([float]($CenterX - $armWidth), [float]($CenterY - $armWidth))
    ))
    $Graphics.FillPath($starBrush, $starPath)
    $starPath.Dispose()
    $starBrush.Dispose()
}

function New-OrderBitmap {
    param(
        [int]$Width,
        [int]$Height,
        [bool]$Wide,
        [bool]$TransparentBackground = $false
    )

    $bitmap = New-Canvas -Width $Width -Height $Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)

    try {
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $graphics.Clear($(if ($TransparentBackground) { $transparent } else { $midnightBlue }))

        if ($Wide) {
            $margin = [Math]::Max([int]($Height * 0.12), 14)
            $emblemSize = [Math]::Min([int]($Height * 0.72), [int]($Width * 0.27))
            $emblemCenterX = $margin + ($emblemSize / 2.0)
            $emblemCenterY = $Height / 2.0
            Draw-OrderEmblem -Graphics $graphics -CenterX $emblemCenterX -CenterY $emblemCenterY -Diameter $emblemSize -DrawField $true

            $titleX = [int]($margin + $emblemSize + ($Width * 0.06))
            $titleY = [int]($Height * 0.26)
            $titleFont = New-Font -Family "Segoe UI" -Size ([float][Math]::Max($Height * 0.17, 14)) -Style ([System.Drawing.FontStyle]::Bold)
            $subtitleFont = New-Font -Family "Segoe UI" -Size ([float][Math]::Max($Height * 0.078, 10))
            $titleBrush = New-Object System.Drawing.SolidBrush $parchment
            $subtitleBrush = New-Object System.Drawing.SolidBrush $warmParchment

            $graphics.DrawString("Archrealms Passport", $titleFont, $titleBrush, $titleX, $titleY)
            $graphics.DrawString("The Order of the Archrealms", $subtitleFont, $subtitleBrush, $titleX, ($titleY + $titleFont.Height - 2))

            $titleBrush.Dispose()
            $subtitleBrush.Dispose()
            $titleFont.Dispose()
            $subtitleFont.Dispose()
        }
        else {
            $diameter = [Math]::Min($Width, $Height) * $(if ($TransparentBackground) { 0.9 } else { 0.78 })
            Draw-OrderEmblem -Graphics $graphics -CenterX ($Width / 2.0) -CenterY ($Height / 2.0) -Diameter $diameter -DrawField $true
        }

        return $bitmap
    }
    finally {
        $graphics.Dispose()
    }
}

function Save-Bitmap {
    param(
        [System.Drawing.Bitmap]$Bitmap,
        [string]$Path
    )

    try {
        $Bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $Bitmap.Dispose()
    }
}

function Save-IconFromBitmap {
    param(
        [System.Drawing.Bitmap]$Bitmap,
        [string]$Path
    )

    $handle = [IntPtr]::Zero
    $icon = $null

    try {
        $handle = $Bitmap.GetHicon()
        $icon = [System.Drawing.Icon]::FromHandle($handle)
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
        try {
            $icon.Save($stream)
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        if ($icon) {
            $icon.Dispose()
        }

        if ($handle -ne [IntPtr]::Zero) {
            [PassportWindowsNativeMethods]::DestroyIcon($handle) | Out-Null
        }

        $Bitmap.Dispose()
    }
}

Save-Bitmap -Bitmap (New-OrderBitmap -Width 50 -Height 50 -Wide:$false) -Path (Join-Path $PackageAssetRoot "StoreLogo.png")
Save-Bitmap -Bitmap (New-OrderBitmap -Width 44 -Height 44 -Wide:$false) -Path (Join-Path $PackageAssetRoot "Square44x44Logo.png")
Save-Bitmap -Bitmap (New-OrderBitmap -Width 71 -Height 71 -Wide:$false) -Path (Join-Path $PackageAssetRoot "Square71x71Logo.png")
Save-Bitmap -Bitmap (New-OrderBitmap -Width 150 -Height 150 -Wide:$false) -Path (Join-Path $PackageAssetRoot "Square150x150Logo.png")
Save-Bitmap -Bitmap (New-OrderBitmap -Width 310 -Height 150 -Wide:$true) -Path (Join-Path $PackageAssetRoot "Wide310x150Logo.png")
Save-Bitmap -Bitmap (New-OrderBitmap -Width 620 -Height 300 -Wide:$true) -Path (Join-Path $PackageAssetRoot "SplashScreen.png")

Save-Bitmap -Bitmap (New-OrderBitmap -Width 256 -Height 256 -Wide:$false) -Path (Join-Path $DesktopAssetRoot "OrderEmblem.png")
Save-IconFromBitmap -Bitmap (New-OrderBitmap -Width 256 -Height 256 -Wide:$false) -Path (Join-Path $DesktopAssetRoot "AppIcon.ico")
