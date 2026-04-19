param(
    [string]$OutputRoot
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing

if (-not $OutputRoot) {
    $OutputRoot = Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..\..\src\ArchrealmsPassport.Windows.Package")).Path "Assets"
}

New-Item -ItemType Directory -Force $OutputRoot | Out-Null

$background = [System.Drawing.Color]::FromArgb(11, 19, 43)
$accent = [System.Drawing.Color]::FromArgb(243, 244, 246)
$banner = [System.Drawing.Color]::FromArgb(59, 130, 246)

function New-PassportLogo {
    param(
        [string]$Path,
        [int]$Width,
        [int]$Height,
        [bool]$Wide
    )

    $bitmap = New-Object System.Drawing.Bitmap $Width, $Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)

    try {
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.Clear($background)

        $bannerHeight = [Math]::Max([int]($Height * 0.18), 8)
        $bannerRect = New-Object System.Drawing.Rectangle(0, 0, $Width, $bannerHeight)
        $bannerBrush = New-Object System.Drawing.SolidBrush $banner
        $graphics.FillRectangle($bannerBrush, $bannerRect)
        $bannerBrush.Dispose()

        $inset = [Math]::Max([int]($Width * 0.14), 6)
        $shieldWidth = if ($Wide) { [Math]::Min([int]($Height * 0.7), [int]($Width * 0.28)) } else { [Math]::Min([int]($Width * 0.62), [int]($Height * 0.62)) }
        $shieldHeight = [Math]::Min([int]($Height * 0.58), [int]($Width * 0.72))
        $shieldX = if ($Wide) { $inset } else { [int](($Width - $shieldWidth) / 2) }
        $shieldY = if ($Wide) { [Math]::Max([int](($Height - $shieldHeight) / 2), $bannerHeight + 4) } else { [int](($Height - $shieldHeight) / 2) }
        $radius = [Math]::Max([int]($shieldWidth * 0.16), 6)

        $shieldPath = New-Object System.Drawing.Drawing2D.GraphicsPath
        $shieldPath.AddArc($shieldX, $shieldY, $radius, $radius, 180, 90)
        $shieldPath.AddArc($shieldX + $shieldWidth - $radius, $shieldY, $radius, $radius, 270, 90)
        $shieldPath.AddArc($shieldX + $shieldWidth - $radius, $shieldY + $shieldHeight - $radius, $radius, $radius, 0, 90)
        $shieldPath.AddArc($shieldX, $shieldY + $shieldHeight - $radius, $radius, $radius, 90, 90)
        $shieldPath.CloseFigure()

        $shieldBrush = New-Object System.Drawing.SolidBrush $accent
        $graphics.FillPath($shieldBrush, $shieldPath)
        $shieldBrush.Dispose()

        $monogramFontSize = if ($Wide) { [Math]::Max([int]($shieldHeight * 0.28), 12) } else { [Math]::Max([int]($shieldWidth * 0.24), 10) }
        $monogramFont = [System.Drawing.Font]::new("Segoe UI", $monogramFontSize, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $monogramBrush = New-Object System.Drawing.SolidBrush $background
        $text = "AR"
        $textSize = $graphics.MeasureString($text, $monogramFont)
        $textX = [int]($shieldX + (($shieldWidth - $textSize.Width) / 2))
        $textY = [int]($shieldY + (($shieldHeight - $textSize.Height) / 2))
        $graphics.DrawString($text, $monogramFont, $monogramBrush, $textX, $textY)
        $monogramBrush.Dispose()
        $monogramFont.Dispose()

        if ($Wide) {
            $titleFontSize = [Math]::Max([int]($Height * 0.18), 14)
            $titleFont = [System.Drawing.Font]::new("Segoe UI", $titleFontSize, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
            $titleBrush = New-Object System.Drawing.SolidBrush $accent
            $subtitleFont = [System.Drawing.Font]::new("Segoe UI", [Math]::Max([int]($Height * 0.1), 10), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
            $subtitleBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(204, $accent))

            $titleX = $shieldX + $shieldWidth + $inset
            $titleY = [Math]::Max([int]($Height * 0.27), $bannerHeight + 6)
            $graphics.DrawString("Passport", $titleFont, $titleBrush, $titleX, $titleY)
            $graphics.DrawString("Archrealms", $subtitleFont, $subtitleBrush, $titleX, $titleY + $titleFont.Height - 4)

            $subtitleBrush.Dispose()
            $subtitleFont.Dispose()
            $titleBrush.Dispose()
            $titleFont.Dispose()
        }

        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

New-PassportLogo -Path (Join-Path $OutputRoot "StoreLogo.png") -Width 50 -Height 50 -Wide:$false
New-PassportLogo -Path (Join-Path $OutputRoot "Square44x44Logo.png") -Width 44 -Height 44 -Wide:$false
New-PassportLogo -Path (Join-Path $OutputRoot "Square71x71Logo.png") -Width 71 -Height 71 -Wide:$false
New-PassportLogo -Path (Join-Path $OutputRoot "Square150x150Logo.png") -Width 150 -Height 150 -Wide:$false
New-PassportLogo -Path (Join-Path $OutputRoot "Wide310x150Logo.png") -Width 310 -Height 150 -Wide:$true
New-PassportLogo -Path (Join-Path $OutputRoot "SplashScreen.png") -Width 620 -Height 300 -Wide:$true
