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
