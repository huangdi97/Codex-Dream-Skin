[CmdletBinding()]
param(
  [int]$Port = 9335
)

$ErrorActionPreference = 'Stop'
$Host.UI.RawUI.WindowTitle = 'Codex Dream Skin'
$PortExplicit = $PSBoundParameters.ContainsKey('Port')

$AppRoot = Split-Path -Parent $PSCommandPath
$PackageRoot = Split-Path -Parent $AppRoot
$WindowsRoot = Join-Path $AppRoot 'windows'
$ScriptsRoot = Join-Path $WindowsRoot 'scripts'
$OutputsRoot = Join-Path $PackageRoot 'outputs'
$InstallScript = Join-Path $ScriptsRoot 'install-dream-skin.ps1'
$StartScript = Join-Path $ScriptsRoot 'start-dream-skin.ps1'
$RestoreScript = Join-Path $ScriptsRoot 'restore-dream-skin.ps1'
$VerifyScript = Join-Path $ScriptsRoot 'verify-dream-skin.ps1'
$ThemeScript = Join-Path $ScriptsRoot 'theme-windows.ps1'

. (Join-Path $ScriptsRoot 'common-windows.ps1')
. $ThemeScript

function Write-Header {
  Clear-Host
  Write-Host ''
  Write-Host '  Codex Dream Skin - One Click Manager' -ForegroundColor Magenta
  Write-Host '  Third-party theme helper. Not an OpenAI official product.' -ForegroundColor DarkGray
  Write-Host ''
}

function Assert-PackageReady {
  foreach ($path in @($InstallScript, $StartScript, $RestoreScript, $VerifyScript, $ThemeScript)) {
    if (-not (Test-Path -LiteralPath $path)) {
      throw "Missing required script: $path"
    }
  }
}

function Pause-Menu {
  Write-Host ''
  [void](Read-Host 'Press Enter to return to the menu')
}

function Invoke-Step {
  param(
    [Parameter(Mandatory = $true)][string]$Title,
    [Parameter(Mandatory = $true)][scriptblock]$Action
  )

  Write-Header
  Write-Host "== $Title ==" -ForegroundColor Cyan
  Write-Host ''
  try {
    & $Action
    Write-Host ''
    Write-Host 'Done.' -ForegroundColor Green
  } catch {
    Write-Host ''
    Write-Host 'Failed:' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
  }
  Pause-Menu
}

function Confirm-Yes {
  param([Parameter(Mandatory = $true)][string]$Message)
  $answer = (Read-Host "$Message [y/N]").Trim()
  return $answer -match '^(y|yes)$'
}

function Get-PortArguments {
  if ($PortExplicit) { return @('-Port', "$Port") }
  return @()
}

function Invoke-Install {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $InstallScript @(Get-PortArguments)
}

function Invoke-Start {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $StartScript @((Get-PortArguments) + @('-PromptRestart'))
}

function Invoke-RestartStart {
  if (-not (Confirm-Yes 'Codex may be restarted. Unsaved text in Codex can be lost. Continue?')) {
    Write-Host 'Cancelled.'
    return
  }
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $StartScript @((Get-PortArguments) + @('-RestartExisting'))
}

function Invoke-Restore {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RestoreScript @((Get-PortArguments) + @('-RestoreBaseTheme', '-PromptRestart'))
}

function Invoke-Uninstall {
  if (-not (Confirm-Yes 'This removes Dream Skin shortcuts and restores the base theme. Continue?')) {
    Write-Host 'Cancelled.'
    return
  }
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RestoreScript @((Get-PortArguments) + @('-Uninstall', '-RestoreBaseTheme', '-PromptRestart'))
}

function Invoke-Verify {
  New-Item -ItemType Directory -Force -Path $OutputsRoot | Out-Null
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $screenshot = Join-Path $OutputsRoot "verify-$stamp.png"
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $VerifyScript @((Get-PortArguments) + @('-ScreenshotPath', $screenshot))
  if (Test-Path -LiteralPath $screenshot) {
    Write-Host "Screenshot saved: $screenshot" -ForegroundColor Green
  }
}

function ConvertTo-SafeThemeId {
  param([Parameter(Mandatory = $true)][string]$Name)
  $lower = $Name.ToLowerInvariant()
  $safe = [regex]::Replace($lower, '[^a-z0-9]+', '-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'custom-theme' }
  return $safe
}

function Get-ImageAccentHex {
  param([Parameter(Mandatory = $true)][string]$ImagePath)

  Add-Type -AssemblyName System.Drawing
  $image = $null
  try {
    $image = [System.Drawing.Bitmap]::FromFile($ImagePath)
    $step = [Math]::Max(1, [int][Math]::Floor([Math]::Max($image.Width, $image.Height) / 120))
    $bestColor = [System.Drawing.Color]::FromArgb(216, 107, 141)
    $bestScore = -1.0
    for ($y = 0; $y -lt $image.Height; $y += $step) {
      for ($x = 0; $x -lt $image.Width; $x += $step) {
        $pixel = $image.GetPixel($x, $y)
        if ($pixel.A -lt 220) { continue }
        $sat = [double]$pixel.GetSaturation()
        $light = [double]$pixel.GetBrightness()
        if ($sat -lt 0.22 -or $light -lt 0.18 -or $light -gt 0.86) { continue }
        $score = $sat * (1.0 - [Math]::Abs($light - 0.55))
        if ($score -gt $bestScore) {
          $bestScore = $score
          $bestColor = $pixel
        }
      }
    }
    return ('#{0:x2}{1:x2}{2:x2}' -f $bestColor.R, $bestColor.G, $bestColor.B)
  } finally {
    if ($image) { $image.Dispose() }
  }
}

function Save-ThemeImage {
  param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$DestinationPath
  )

  Add-Type -AssemblyName System.Drawing
  $source = $null
  $canvas = $null
  $graphics = $null
  $encoderParams = $null
  try {
    $source = [System.Drawing.Image]::FromFile($SourcePath)
    $maxEdge = 1920.0
    $scale = [Math]::Min(1.0, $maxEdge / [Math]::Max($source.Width, $source.Height))
    $width = [Math]::Max(1, [int][Math]::Round($source.Width * $scale))
    $height = [Math]::Max(1, [int][Math]::Round($source.Height * $scale))
    $canvas = New-Object System.Drawing.Bitmap $width, $height
    $canvas.SetResolution(96, 96)
    $graphics = [System.Drawing.Graphics]::FromImage($canvas)
    $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.Clear([System.Drawing.Color]::White)
    $graphics.DrawImage($source, 0, 0, $width, $height)
    $jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
      Where-Object { $_.MimeType -eq 'image/jpeg' } |
      Select-Object -First 1
    if ($null -eq $jpegCodec) { throw 'JPEG image encoder is not available on this Windows system.' }
    $encoderParams = New-Object System.Drawing.Imaging.EncoderParameters 1
    $encoderParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter `
      -ArgumentList ([System.Drawing.Imaging.Encoder]::Quality), ([int64]86)
    $canvas.Save($DestinationPath, $jpegCodec, $encoderParams)
  } finally {
    if ($encoderParams) { $encoderParams.Dispose() }
    if ($graphics) { $graphics.Dispose() }
    if ($canvas) { $canvas.Dispose() }
    if ($source) { $source.Dispose() }
  }
}

function Invoke-StartAfterThemeChange {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $StartScript @((Get-PortArguments) + @('-RestartExisting'))
}

function Read-ThemeChoice {
  param(
    [Parameter(Mandatory = $true)][string]$Title,
    [Parameter(Mandatory = $true)][object[]]$Options,
    [int]$DefaultIndex = 1
  )
  Write-Host ''
  Write-Host $Title -ForegroundColor Cyan
  for ($index = 0; $index -lt $Options.Count; $index++) {
    Write-Host ("  {0}. {1}" -f ($index + 1), $Options[$index].Label)
  }
  $raw = (Read-Host "Choose [$DefaultIndex]").Trim()
  if (-not $raw) { return $Options[$DefaultIndex - 1] }
  if ($raw -match '^\d+$') {
    $number = [int]$raw
    if ($number -ge 1 -and $number -le $Options.Count) { return $Options[$number - 1] }
  }
  Write-Host 'Using default.' -ForegroundColor Yellow
  return $Options[$DefaultIndex - 1]
}

function New-OneClickTheme {
  $name = (Read-Host 'Theme name').Trim()
  if (-not $name) {
    Write-Host 'Cancelled.'
    return
  }
  Write-Host 'Paste a PNG, JPG, JPEG, or WEBP image path. Leave empty to cancel.'
  $raw = Read-Host 'Image path'
  $inputPath = $raw.Trim().Trim('"')
  if (-not $inputPath) {
    Write-Host 'Cancelled.'
    return
  }
  if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
    throw "Image file not found: $inputPath"
  }

  $style = Read-ThemeChoice -Title 'Control color style' -Options @(
    [pscustomobject]@{ Label = 'Auto from image'; Accent = $null },
    [pscustomobject]@{ Label = 'Rose pink'; Accent = '#d86b8d' },
    [pscustomobject]@{ Label = 'Fresh blue'; Accent = '#4f8cff' },
    [pscustomobject]@{ Label = 'Dream purple'; Accent = '#8b5cf6' },
    [pscustomobject]@{ Label = 'Premium gold'; Accent = '#c8922e' },
    [pscustomobject]@{ Label = 'Warm red'; Accent = '#e5484d' }
  )
  $appearance = Read-ThemeChoice -Title 'Appearance' -Options @(
    [pscustomobject]@{ Label = 'Auto'; Value = 'auto' },
    [pscustomobject]@{ Label = 'Light controls'; Value = 'light' },
    [pscustomobject]@{ Label = 'Dark controls'; Value = 'dark' }
  )
  $safeArea = Read-ThemeChoice -Title 'Home text mask' -Options @(
    [pscustomobject]@{ Label = 'Auto'; Value = 'auto' },
    [pscustomobject]@{ Label = 'Left mask'; Value = 'left' },
    [pscustomobject]@{ Label = 'Right mask'; Value = 'right' },
    [pscustomobject]@{ Label = 'Center mask'; Value = 'center' },
    [pscustomobject]@{ Label = 'No mask'; Value = 'none' }
  )
  $taskMode = Read-ThemeChoice -Title 'Task page mask' -Options @(
    [pscustomobject]@{ Label = 'Auto'; Value = 'auto' },
    [pscustomobject]@{ Label = 'Soft background mask'; Value = 'ambient' },
    [pscustomobject]@{ Label = 'Top banner mask'; Value = 'banner' },
    [pscustomobject]@{ Label = 'Hide background image'; Value = 'off' }
  )

  $paths = Initialize-OneClickThemeStore
  Assert-DreamSkinImageFile -Path $inputPath
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $baseId = ConvertTo-SafeThemeId -Name $name
  $themeId = "$baseId-$stamp"
  $exportRoot = Join-Path $OutputsRoot 'themes'
  $themeDir = Join-Path $exportRoot $themeId
  New-Item -ItemType Directory -Force -Path $themeDir | Out-Null

  $imageName = 'art.jpg'
  $imagePath = Join-Path $themeDir $imageName
  Save-ThemeImage -SourcePath $inputPath -DestinationPath $imagePath
  $accent = if ($style.Accent) { $style.Accent } else { Get-ImageAccentHex -ImagePath $imagePath }
  $theme = [ordered]@{
    schemaVersion = 1
    id = $themeId
    name = $name
    image = $imageName
    appearance = $appearance.Value
    brandSubtitle = 'CODEX DREAM SKIN'
    tagline = "$name is ready."
    statusText = 'CUSTOM THEME ONLINE'
    quote = 'MAKE SOMETHING WONDERFUL'
    art = [ordered]@{ focusX = 0.5; focusY = 0.42; safeArea = $safeArea.Value; taskMode = $taskMode.Value }
    palette = [ordered]@{ accent = $accent }
  }
  Write-DreamSkinTheme -ThemeDirectory $themeDir -Theme ([pscustomobject]$theme)
  $loaded = Read-DreamSkinTheme -ThemeDirectory $themeDir
  $activeTheme = $loaded.Theme | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  $active = Set-DreamSkinActiveTheme -ImagePath $loaded.ImagePath -Theme $activeTheme -StateRoot $paths.Root
  $null = Save-DreamSkinCurrentTheme -Name $name -StateRoot $paths.Root
  Write-Host "Theme created and applied: $($active.Theme.name)" -ForegroundColor Green
  Write-Host "Theme folder: $themeDir" -ForegroundColor Green
  Write-Host "Accent: $accent" -ForegroundColor Green
  Invoke-StartAfterThemeChange
}

function Set-CustomImage {
  Write-Host 'Paste a PNG, JPG, JPEG, or WEBP image path. Leave empty to cancel.'
  $raw = Read-Host 'Image path'
  $inputPath = $raw.Trim().Trim('"')
  if (-not $inputPath) {
    Write-Host 'Cancelled.'
    return
  }
  if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
    throw "Image file not found: $inputPath"
  }
  $paths = Initialize-OneClickThemeStore
  $active = Set-DreamSkinActiveTheme -ImagePath $inputPath -Theme $null -Name 'Custom image' -StateRoot $paths.Root
  Write-Host "Custom adaptive theme applied: $($active.Theme.name). If Codex is running, it will update shortly; otherwise start Dream Skin." -ForegroundColor Green
}

function Restore-DefaultImage {
  Set-DefaultDreamTheme
}

function Initialize-OneClickThemeStore {
  return Initialize-DreamSkinThemeStore -SkillRoot $WindowsRoot -StateRoot (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin')
}

function Set-DefaultDreamTheme {
  $paths = Initialize-OneClickThemeStore
  $theme = (Read-DreamSkinUtf8File -Path (Join-Path $WindowsRoot 'assets\theme.json')) | ConvertFrom-Json -ErrorAction Stop
  $image = Join-Path $WindowsRoot 'assets\dream-reference.jpg'
  $active = Set-DreamSkinActiveTheme -ImagePath $image -Theme $theme -StateRoot $paths.Root
  Write-Host "Default adaptive theme restored: $($active.Theme.name). If Codex is running, it will update shortly; otherwise start Dream Skin." -ForegroundColor Green
}

function Import-ExplicitTheme {
  param([Parameter(Mandatory = $true)][string]$ThemeDir)
  $paths = Initialize-OneClickThemeStore
  $loaded = Read-DreamSkinTheme -ThemeDirectory $ThemeDir
  $theme = $loaded.Theme | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  $active = Set-DreamSkinActiveTheme -ImagePath $loaded.ImagePath -Theme $theme -StateRoot $paths.Root
  Write-Host "Theme applied: $($active.Theme.name). If Codex is running, it will update shortly; otherwise start Dream Skin." -ForegroundColor Green
}

function Select-ThemePackage {
  $paths = Initialize-OneClickThemeStore
  $packages = @(Get-DreamSkinSavedThemes -StateRoot $paths.Root -SkipImageMetadata)
  if ($packages.Count -gt 0) {
    Write-Host 'Saved themes:'
    for ($index = 0; $index -lt $packages.Count; $index++) {
      Write-Host ("  {0}. {1}" -f ($index + 1), $packages[$index].Name)
    }
    Write-Host '  C. Custom folder path'
    Write-Host ''
    $choice = (Read-Host 'Choose theme').Trim()
    if ($choice -match '^\d+$') {
      $number = [int]$choice
      if ($number -ge 1 -and $number -le $packages.Count) {
        $active = Use-DreamSkinSavedTheme -ThemeDirectory $packages[$number - 1].Path -StateRoot $paths.Root
        Write-Host "Theme applied: $($active.Theme.name). If Codex is running, it will update shortly; otherwise start Dream Skin." -ForegroundColor Green
        return
      }
    }
  }

  Write-Host 'Paste a theme folder path containing theme.json and its image. Leave empty to cancel.'
  $raw = Read-Host 'Theme folder'
  $themePath = $raw.Trim().Trim('"')
  if (-not $themePath) {
    Write-Host 'Cancelled.'
    return
  }
  Import-ExplicitTheme -ThemeDir $themePath
}

function Open-LocalData {
  $stateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
  New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
  Start-Process explorer.exe $stateRoot
}

Assert-PackageReady

while ($true) {
  Write-Header
  Write-Host '  1. Install / repair Dream Skin'
  Write-Host '  2. Start Codex with Dream Skin'
  Write-Host '  3. Restart Codex and start Dream Skin'
  Write-Host '  4. Verify and save screenshot'
  Write-Host '  5. Use my own theme image'
  Write-Host '  6. Apply saved/imported theme'
  Write-Host '  7. Restore default adaptive theme'
  Write-Host '  M. Make a theme from one image'
  Write-Host '  8. Restore official Codex appearance'
  Write-Host '  9. Uninstall Dream Skin shortcuts'
  Write-Host '  L. Open logs / local data folder'
  Write-Host '  0. Exit'
  Write-Host ''
  $choice = (Read-Host 'Choose').Trim()

  switch ($choice) {
    '1' { Invoke-Step 'Install / repair Dream Skin' { Invoke-Install } }
    '2' { Invoke-Step 'Start Codex with Dream Skin' { Invoke-Start } }
    '3' { Invoke-Step 'Restart Codex and start Dream Skin' { Invoke-RestartStart } }
    '4' { Invoke-Step 'Verify and save screenshot' { Invoke-Verify } }
    '5' { Invoke-Step 'Use my own theme image' { Set-CustomImage } }
    '6' { Invoke-Step 'Apply saved/imported theme' { Select-ThemePackage } }
    '7' { Invoke-Step 'Restore default adaptive theme' { Restore-DefaultImage } }
    'M' { Invoke-Step 'Make a theme from one image' { New-OneClickTheme } }
    'm' { Invoke-Step 'Make a theme from one image' { New-OneClickTheme } }
    '8' { Invoke-Step 'Restore official Codex appearance' { Invoke-Restore } }
    '9' { Invoke-Step 'Uninstall Dream Skin shortcuts' { Invoke-Uninstall } }
    'L' { Invoke-Step 'Open logs / local data folder' { Open-LocalData } }
    'l' { Invoke-Step 'Open logs / local data folder' { Open-LocalData } }
    '0' { break }
    default {
      Write-Host 'Unknown option.' -ForegroundColor Yellow
      Start-Sleep -Seconds 1
    }
  }
}
