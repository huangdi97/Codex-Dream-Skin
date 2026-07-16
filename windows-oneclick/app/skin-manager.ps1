[CmdletBinding()]
param(
  [int]$Port = 9335
)

$ErrorActionPreference = 'Stop'
$Host.UI.RawUI.WindowTitle = 'Codex Dream Skin'

$AppRoot = Split-Path -Parent $PSCommandPath
$PackageRoot = Split-Path -Parent $AppRoot
$WindowsRoot = Join-Path $AppRoot 'windows'
$ScriptsRoot = Join-Path $WindowsRoot 'scripts'
$OutputsRoot = Join-Path $PackageRoot 'outputs'
$InstallScript = Join-Path $ScriptsRoot 'install-dream-skin.ps1'
$StartScript = Join-Path $ScriptsRoot 'start-dream-skin.ps1'
$RestoreScript = Join-Path $ScriptsRoot 'restore-dream-skin.ps1'
$VerifyScript = Join-Path $ScriptsRoot 'verify-dream-skin.ps1'
$ArtPath = Join-Path $WindowsRoot 'assets\dream-reference.png'
$ArtBackupPath = Join-Path $WindowsRoot 'assets\dream-reference.original.png'
$BackgroundArtPath = Join-Path $WindowsRoot 'assets\dream-background.png'
$BackgroundArtBackupPath = Join-Path $WindowsRoot 'assets\dream-background.original.png'
$PalettePath = Join-Path $WindowsRoot 'assets\dream-palette.css'
$PaletteBackupPath = Join-Path $WindowsRoot 'assets\dream-palette.original.css'
$ControlsPath = Join-Path $WindowsRoot 'assets\dream-controls.css'
$ControlsBackupPath = Join-Path $WindowsRoot 'assets\dream-controls.original.css'
$ThemesRoot = Join-Path $AppRoot 'themes'

function Write-Header {
  Clear-Host
  Write-Host ''
  Write-Host '  Codex Dream Skin - One Click Manager' -ForegroundColor Magenta
  Write-Host '  Third-party theme helper. Not an OpenAI official product.' -ForegroundColor DarkGray
  Write-Host ''
}

function Assert-PackageReady {
  foreach ($path in @($InstallScript, $StartScript, $RestoreScript, $VerifyScript)) {
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

function Invoke-Install {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $InstallScript -Port $Port
}

function Invoke-Start {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $StartScript -Port $Port -PromptRestart
}

function Invoke-RestartStart {
  if (-not (Confirm-Yes 'Codex may be restarted. Unsaved text in Codex can be lost. Continue?')) {
    Write-Host 'Cancelled.'
    return
  }
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $StartScript -Port $Port -RestartExisting
}

function Invoke-Restore {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RestoreScript -Port $Port -RestoreBaseTheme -PromptRestart
}

function Invoke-Uninstall {
  if (-not (Confirm-Yes 'This removes Dream Skin shortcuts and restores the base theme. Continue?')) {
    Write-Host 'Cancelled.'
    return
  }
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RestoreScript -Port $Port -Uninstall -RestoreBaseTheme -PromptRestart
}

function Invoke-Verify {
  New-Item -ItemType Directory -Force -Path $OutputsRoot | Out-Null
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $screenshot = Join-Path $OutputsRoot "verify-$stamp.png"
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $VerifyScript -Port $Port -ScreenshotPath $screenshot
  if (Test-Path -LiteralPath $screenshot) {
    Write-Host "Screenshot saved: $screenshot" -ForegroundColor Green
  }
}

function Set-CustomImage {
  Write-Host 'Paste a PNG or JPG image path. Leave empty to cancel.'
  $raw = Read-Host 'Image path'
  $inputPath = $raw.Trim().Trim('"')
  if (-not $inputPath) {
    Write-Host 'Cancelled.'
    return
  }
  if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
    throw "Image file not found: $inputPath"
  }
  $extension = [System.IO.Path]::GetExtension($inputPath).ToLowerInvariant()
  if ($extension -notin @('.png', '.jpg', '.jpeg')) {
    throw 'Only PNG, JPG, and JPEG images are supported.'
  }
  if (-not (Test-Path -LiteralPath $ArtBackupPath) -and (Test-Path -LiteralPath $ArtPath)) {
    Copy-Item -LiteralPath $ArtPath -Destination $ArtBackupPath -Force
  }
  Copy-Item -LiteralPath $inputPath -Destination $ArtPath -Force
  Write-Host 'Custom image applied. Start or restart Dream Skin to see it.' -ForegroundColor Green
}

function Restore-DefaultImage {
  if (-not (Test-Path -LiteralPath $ArtBackupPath)) {
    Write-Host 'No original image backup was found.'
    return
  }
  Copy-Item -LiteralPath $ArtBackupPath -Destination $ArtPath -Force
  Write-Host 'Default image restored. Start or restart Dream Skin to see it.' -ForegroundColor Green
}

function Read-ThemeManifest {
  param([Parameter(Mandatory = $true)][string]$ThemeDir)
  $manifestPath = Join-Path $ThemeDir 'theme.json'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $null }
  $json = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8)
  return $json | ConvertFrom-Json
}

function Get-ThemeManifestValue {
  param(
    [object]$Manifest,
    [Parameter(Mandatory = $true)][string]$PropertyName,
    [Parameter(Mandatory = $true)][string]$DefaultValue
  )
  if ($null -eq $Manifest) { return $DefaultValue }
  $property = $Manifest.PSObject.Properties | Where-Object { $_.Name -eq $PropertyName } | Select-Object -First 1
  if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) { return $DefaultValue }
  return [string]$property.Value
}

function Resolve-ThemeFile {
  param(
    [Parameter(Mandatory = $true)][string]$ThemeDir,
    [object]$Manifest,
    [Parameter(Mandatory = $true)][string]$PropertyName,
    [Parameter(Mandatory = $true)][string]$DefaultFile
  )
  $relative = Get-ThemeManifestValue -Manifest $Manifest -PropertyName $PropertyName -DefaultValue $DefaultFile
  $candidate = Join-Path $ThemeDir $relative
  if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
  return $null
}

function Backup-ThemeTarget {
  param(
    [Parameter(Mandatory = $true)][string]$TargetPath,
    [Parameter(Mandatory = $true)][string]$BackupPath
  )
  if (-not (Test-Path -LiteralPath $BackupPath) -and (Test-Path -LiteralPath $TargetPath -PathType Leaf)) {
    Copy-Item -LiteralPath $TargetPath -Destination $BackupPath -Force
  }
}

function Copy-ThemePart {
  param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$TargetPath,
    [Parameter(Mandatory = $true)][string]$BackupPath
  )
  Backup-ThemeTarget -TargetPath $TargetPath -BackupPath $BackupPath
  Copy-Item -LiteralPath $SourcePath -Destination $TargetPath -Force
}

function Get-ThemePackages {
  if (-not (Test-Path -LiteralPath $ThemesRoot -PathType Container)) { return @() }
  $packages = @()
  foreach ($dir in @(Get-ChildItem -LiteralPath $ThemesRoot -Directory | Sort-Object Name)) {
    $manifest = $null
    try { $manifest = Read-ThemeManifest -ThemeDir $dir.FullName } catch { $manifest = $null }
    $recognized = @(
      (Resolve-ThemeFile -ThemeDir $dir.FullName -Manifest $manifest -PropertyName 'controls' -DefaultFile 'dream-controls.css'),
      (Resolve-ThemeFile -ThemeDir $dir.FullName -Manifest $manifest -PropertyName 'homeImage' -DefaultFile 'dream-reference.png'),
      (Resolve-ThemeFile -ThemeDir $dir.FullName -Manifest $manifest -PropertyName 'backgroundImage' -DefaultFile 'dream-background.png'),
      (Resolve-ThemeFile -ThemeDir $dir.FullName -Manifest $manifest -PropertyName 'palette' -DefaultFile 'dream-palette.css')
    ) | Where-Object { $_ }
    if ($recognized.Count -gt 0) {
      $packages += [PSCustomObject]@{
        Name = Get-ThemeManifestValue -Manifest $manifest -PropertyName 'name' -DefaultValue $dir.Name
        Path = $dir.FullName
      }
    }
  }
  return $packages
}

function Apply-ThemePackage {
  param([Parameter(Mandatory = $true)][string]$ThemeDir)
  if (-not (Test-Path -LiteralPath $ThemeDir -PathType Container)) {
    throw "Theme folder not found: $ThemeDir"
  }

  $manifest = Read-ThemeManifest -ThemeDir $ThemeDir
  $homeImage = Resolve-ThemeFile -ThemeDir $ThemeDir -Manifest $manifest -PropertyName 'homeImage' -DefaultFile 'dream-reference.png'
  $backgroundImage = Resolve-ThemeFile -ThemeDir $ThemeDir -Manifest $manifest -PropertyName 'backgroundImage' -DefaultFile 'dream-background.png'
  $palette = Resolve-ThemeFile -ThemeDir $ThemeDir -Manifest $manifest -PropertyName 'palette' -DefaultFile 'dream-palette.css'
  $controls = Resolve-ThemeFile -ThemeDir $ThemeDir -Manifest $manifest -PropertyName 'controls' -DefaultFile 'dream-controls.css'

  $applied = 0
  if ($homeImage) {
    Copy-ThemePart -SourcePath $homeImage -TargetPath $ArtPath -BackupPath $ArtBackupPath
    $applied += 1
  }
  if ($backgroundImage) {
    Copy-ThemePart -SourcePath $backgroundImage -TargetPath $BackgroundArtPath -BackupPath $BackgroundArtBackupPath
    $applied += 1
  }
  if ($palette) {
    Copy-ThemePart -SourcePath $palette -TargetPath $PalettePath -BackupPath $PaletteBackupPath
    $applied += 1
  }
  if ($controls) {
    Copy-ThemePart -SourcePath $controls -TargetPath $ControlsPath -BackupPath $ControlsBackupPath
    $applied += 1
  }
  if ($applied -eq 0) {
    throw 'This folder is not a Dream Skin theme package.'
  }
  $name = Get-ThemeManifestValue -Manifest $manifest -PropertyName 'name' -DefaultValue ([System.IO.Path]::GetFileName($ThemeDir))
  Write-Host "Theme applied: $name. Start or restart Dream Skin to see it." -ForegroundColor Green
}

function Select-ThemePackage {
  $packages = @(Get-ThemePackages)
  if ($packages.Count -gt 0) {
    Write-Host 'Built-in themes:'
    for ($index = 0; $index -lt $packages.Count; $index++) {
      Write-Host ("  {0}. {1}" -f ($index + 1), $packages[$index].Name)
    }
    Write-Host '  C. Custom folder path'
    Write-Host ''
    $choice = (Read-Host 'Choose theme').Trim()
    if ($choice -match '^\d+$') {
      $number = [int]$choice
      if ($number -ge 1 -and $number -le $packages.Count) {
        Apply-ThemePackage -ThemeDir $packages[$number - 1].Path
        return
      }
    }
  }

  Write-Host 'Paste a theme folder path. Leave empty to cancel.'
  $raw = Read-Host 'Theme folder'
  $themePath = $raw.Trim().Trim('"')
  if (-not $themePath) {
    Write-Host 'Cancelled.'
    return
  }
  Apply-ThemePackage -ThemeDir $themePath
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
  Write-Host '  6. Apply theme package / controls'
  Write-Host '  7. Restore default theme image'
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
    '6' { Invoke-Step 'Apply theme package / controls' { Select-ThemePackage } }
    '7' { Invoke-Step 'Restore default theme image' { Restore-DefaultImage } }
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
