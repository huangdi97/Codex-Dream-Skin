[CmdletBinding()]
param(
  [int]$Port = 9335
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$AppRoot = Split-Path -Parent $PSCommandPath
$PackageRoot = Split-Path -Parent $AppRoot
$WindowsRoot = Join-Path $AppRoot 'windows'
$ScriptsRoot = Join-Path $WindowsRoot 'scripts'
$OutputsRoot = Join-Path $PackageRoot 'outputs'
$TextPath = Join-Path $AppRoot 'gui-text.zh-CN.json'
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
$LogPath = Join-Path $OutputsRoot 'last-action.log'
$CrashLogPath = Join-Path $OutputsRoot 'gui-crash.log'

function Read-TextMap {
  if (-not (Test-Path -LiteralPath $TextPath)) { throw "Missing UI text file: $TextPath" }
  $json = [System.IO.File]::ReadAllText($TextPath, [System.Text.Encoding]::UTF8)
  return $json | ConvertFrom-Json
}

$Text = Read-TextMap

function Get-TextValue {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Default
  )
  $property = $Text.PSObject.Properties[$Name]
  if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) { return $Default }
  return [string]$property.Value
}

function Show-Message {
  param(
    [Parameter(Mandatory = $true)][string]$Body,
    [string]$Title = $Text.windowTitle,
    [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information
  )
  [void][System.Windows.Forms.MessageBox]::Show($Body, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, $Icon)
}

function Write-GuiCrashLog {
  param([Parameter(Mandatory = $true)][object]$ErrorObject)
  try {
    New-Item -ItemType Directory -Force -Path $OutputsRoot | Out-Null
    $content = @(
      "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
      "Error:",
      ($ErrorObject | Out-String),
      "Invocation:",
      ($ErrorObject.InvocationInfo | Out-String),
      "ScriptStackTrace:",
      "$($ErrorObject.ScriptStackTrace)"
    ) -join "`r`n"
    Set-Content -LiteralPath $CrashLogPath -Value $content -Encoding UTF8
  } catch {}
}

function Confirm-Action {
  param([Parameter(Mandatory = $true)][string]$Body)
  $result = [System.Windows.Forms.MessageBox]::Show(
    $Body,
    $Text.windowTitle,
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question
  )
  return $result -eq [System.Windows.Forms.DialogResult]::Yes
}

function Choose-ImageScope {
  $first = [System.Windows.Forms.MessageBox]::Show(
    $Text.imageScopeAll,
    $Text.windowTitle,
    [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
    [System.Windows.Forms.MessageBoxIcon]::Question
  )
  if ($first -eq [System.Windows.Forms.DialogResult]::Cancel) { return 'cancel' }
  if ($first -eq [System.Windows.Forms.DialogResult]::Yes) { return 'all' }

  $second = [System.Windows.Forms.MessageBox]::Show(
    $Text.imageScopeSingle,
    $Text.windowTitle,
    [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
    [System.Windows.Forms.MessageBoxIcon]::Question
  )
  if ($second -eq [System.Windows.Forms.DialogResult]::Cancel) { return 'cancel' }
  if ($second -eq [System.Windows.Forms.DialogResult]::Yes) { return 'home' }
  return 'background'
}

function Save-ThemeImage {
  param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$DestinationPath
  )

  $source = $null
  $canvas = $null
  $graphics = $null
  $encoderParams = $null
  try {
    $source = [System.Drawing.Image]::FromFile($SourcePath)
    $maxEdge = 2560.0
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
    $qualityEncoder = [System.Drawing.Imaging.Encoder]::Quality
    $qualityValue = [int64]88
    $encoderParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter -ArgumentList $qualityEncoder, $qualityValue
    $canvas.Save($DestinationPath, $jpegCodec, $encoderParams)
  } finally {
    if ($encoderParams) { $encoderParams.Dispose() }
    if ($graphics) { $graphics.Dispose() }
    if ($canvas) { $canvas.Dispose() }
    if ($source) { $source.Dispose() }
  }
}

function ConvertTo-CssHex {
  param([Parameter(Mandatory = $true)][System.Drawing.Color]$Color)
  return ('#{0:x2}{1:x2}{2:x2}' -f $Color.R, $Color.G, $Color.B)
}

function ConvertTo-CssRgb {
  param([Parameter(Mandatory = $true)][System.Drawing.Color]$Color)
  return ('{0}, {1}, {2}' -f $Color.R, $Color.G, $Color.B)
}

function Blend-Color {
  param(
    [Parameter(Mandatory = $true)][System.Drawing.Color]$From,
    [Parameter(Mandatory = $true)][System.Drawing.Color]$To,
    [double]$Amount
  )
  $Amount = [Math]::Max(0.0, [Math]::Min(1.0, $Amount))
  $r = [int][Math]::Round($From.R + (($To.R - $From.R) * $Amount))
  $g = [int][Math]::Round($From.G + (($To.G - $From.G) * $Amount))
  $b = [int][Math]::Round($From.B + (($To.B - $From.B) * $Amount))
  return [System.Drawing.Color]::FromArgb(255, $r, $g, $b)
}

function Get-HueDistance {
  param([double]$Left, [double]$Right)
  $distance = [Math]::Abs($Left - $Right)
  return [Math]::Min($distance, 360 - $distance)
}

function Update-ThemePalette {
  param([Parameter(Mandatory = $true)][string]$ImagePath)

  $image = $null
  try {
    $image = [System.Drawing.Bitmap]::FromFile($ImagePath)
    $step = [Math]::Max(1, [int][Math]::Floor([Math]::Max($image.Width, $image.Height) / 180))
    $buckets = @{}

    for ($y = 0; $y -lt $image.Height; $y += $step) {
      for ($x = 0; $x -lt $image.Width; $x += $step) {
        $pixel = $image.GetPixel($x, $y)
        if ($pixel.A -lt 200) { continue }
        $sat = [double]$pixel.GetSaturation()
        $light = [double]$pixel.GetBrightness()
        if ($sat -lt 0.20 -or $light -lt 0.14 -or $light -gt 0.90) { continue }

        $qr = [int]([Math]::Round($pixel.R / 32) * 32)
        $qg = [int]([Math]::Round($pixel.G / 32) * 32)
        $qb = [int]([Math]::Round($pixel.B / 32) * 32)
        $qr = [Math]::Min(255, $qr)
        $qg = [Math]::Min(255, $qg)
        $qb = [Math]::Min(255, $qb)
        $key = "$qr,$qg,$qb"

        $balance = 1 - ([Math]::Abs($light - 0.54) * 1.35)
        $weight = [Math]::Pow($sat, 1.55) * [Math]::Max(0.18, $balance)
        if (-not $buckets.ContainsKey($key)) {
          $bucketColor = [System.Drawing.Color]::FromArgb(255, $qr, $qg, $qb)
          $buckets[$key] = [PSCustomObject]@{
            Color = $bucketColor
            Score = 0.0
            Count = 0
            Hue = [double]$bucketColor.GetHue()
          }
        }
        $buckets[$key].Score += $weight
        $buckets[$key].Count += 1
      }
    }

    $ranked = @($buckets.Values | Sort-Object @{ Expression = { $_.Score * [Math]::Log(1 + $_.Count) }; Descending = $true })
    if ($ranked.Count -eq 0) {
      $primary = [System.Drawing.Color]::FromArgb(255, 170, 118, 58)
      $secondary = [System.Drawing.Color]::FromArgb(255, 76, 171, 190)
      $accent = [System.Drawing.Color]::FromArgb(255, 207, 122, 71)
    } else {
      $primary = $ranked[0].Color
      $secondary = $null
      foreach ($entry in $ranked) {
        if ((Get-HueDistance -Left ([double]$primary.GetHue()) -Right ([double]$entry.Hue)) -ge 42) {
          $secondary = $entry.Color
          break
        }
      }
      if ($null -eq $secondary) { $secondary = Blend-Color $primary ([System.Drawing.Color]::White) 0.28 }
      $accent = if ($ranked.Count -gt 1) { $ranked[([Math]::Min(1, $ranked.Count - 1))].Color } else { $secondary }
    }

    $ink = Blend-Color $primary ([System.Drawing.Color]::Black) 0.58
    $panel = Blend-Color $primary ([System.Drawing.Color]::White) 0.88
    $soft = Blend-Color $secondary ([System.Drawing.Color]::White) 0.78

    $css = @(
      ':root.codex-dream-skin {',
      "  --dream-ink: $(ConvertTo-CssHex $ink);",
      "  --dream-purple: $(ConvertTo-CssHex $primary);",
      "  --dream-violet: $(ConvertTo-CssHex $secondary);",
      "  --dream-pink: $(ConvertTo-CssHex $accent);",
      "  --dream-blush: $(ConvertTo-CssHex $panel);",
      "  --dream-primary: $(ConvertTo-CssHex $primary);",
      "  --dream-secondary: $(ConvertTo-CssHex $secondary);",
      "  --dream-accent: $(ConvertTo-CssHex $accent);",
      "  --dream-primary-rgb: $(ConvertTo-CssRgb $primary);",
      "  --dream-secondary-rgb: $(ConvertTo-CssRgb $secondary);",
      "  --dream-accent-rgb: $(ConvertTo-CssRgb $accent);",
      "  --dream-ink-rgb: $(ConvertTo-CssRgb $ink);",
      "  --dream-panel-rgb: $(ConvertTo-CssRgb $panel);",
      "  --dream-soft-rgb: $(ConvertTo-CssRgb $soft);",
      '  --dream-line: rgba(var(--dream-primary-rgb), .42);',
      '}'
    ) -join "`r`n"
    Set-Content -LiteralPath $PalettePath -Value $css -Encoding UTF8
  } finally {
    if ($image) { $image.Dispose() }
  }
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

function Get-ThemeDisplayName {
  param([Parameter(Mandatory = $true)][string]$ThemeDir)
  try {
    $manifest = Read-ThemeManifest -ThemeDir $ThemeDir
    return Get-ThemeManifestValue -Manifest $manifest -PropertyName 'name' -DefaultValue ([System.IO.Path]::GetFileName($ThemeDir))
  } catch {
    return [System.IO.Path]::GetFileName($ThemeDir)
  }
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
    throw 'This folder is not a Dream Skin theme package. Add theme.json, dream-controls.css, images, or dream-palette.css.'
  }
  if ($homeImage -and -not $palette) {
    Update-ThemePalette -ImagePath $ArtPath
  }

  $themeName = Get-ThemeDisplayName -ThemeDir $ThemeDir
  return "Theme applied: $themeName. Click restart/start to apply it in Codex."
}

function Select-ThemePackage {
  $packages = @(Get-ThemePackages)
  $picker = New-Object System.Windows.Forms.Form
  $picker.Text = 'Choose Dream Skin theme'
  $picker.StartPosition = 'CenterParent'
  $picker.ClientSize = New-Object System.Drawing.Size(440, 330)
  $picker.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
  $picker.MaximizeBox = $false
  $picker.MinimizeBox = $false
  $picker.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

  $label = New-Object System.Windows.Forms.Label
  $label.Text = 'Choose a built-in theme, or browse to a custom theme folder.'
  $label.Location = New-Object System.Drawing.Point(18, 16)
  $label.Size = New-Object System.Drawing.Size(398, 24)
  $picker.Controls.Add($label)

  $list = New-Object System.Windows.Forms.ListBox
  $list.DisplayMember = 'Name'
  $list.Location = New-Object System.Drawing.Point(18, 50)
  $list.Size = New-Object System.Drawing.Size(398, 190)
  foreach ($package in $packages) { [void]$list.Items.Add($package) }
  if ($list.Items.Count -gt 0) { $list.SelectedIndex = 0 }
  $picker.Controls.Add($list)

  $ok = New-Object System.Windows.Forms.Button
  $ok.Text = 'Apply'
  $ok.Location = New-Object System.Drawing.Point(176, 262)
  $ok.Size = New-Object System.Drawing.Size(76, 34)
  $picker.Controls.Add($ok)

  $browse = New-Object System.Windows.Forms.Button
  $browse.Text = 'Browse...'
  $browse.Location = New-Object System.Drawing.Point(258, 262)
  $browse.Size = New-Object System.Drawing.Size(76, 34)
  $picker.Controls.Add($browse)

  $cancel = New-Object System.Windows.Forms.Button
  $cancel.Text = 'Cancel'
  $cancel.Location = New-Object System.Drawing.Point(340, 262)
  $cancel.Size = New-Object System.Drawing.Size(76, 34)
  $picker.Controls.Add($cancel)

  $script:SelectedThemePath = $null
  $ok.Add_Click({
    if ($list.SelectedItem) {
      $script:SelectedThemePath = $list.SelectedItem.Path
      $picker.Close()
    }
  })
  $browse.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select a Dream Skin theme folder'
    if (Test-Path -LiteralPath $ThemesRoot -PathType Container) { $dialog.SelectedPath = $ThemesRoot }
    if ($dialog.ShowDialog($picker) -eq [System.Windows.Forms.DialogResult]::OK) {
      $script:SelectedThemePath = $dialog.SelectedPath
      $picker.Close()
    }
    $dialog.Dispose()
  })
  $cancel.Add_Click({ $picker.Close() })
  $list.Add_DoubleClick({
    if ($list.SelectedItem) {
      $script:SelectedThemePath = $list.SelectedItem.Path
      $picker.Close()
    }
  })

  [void]$picker.ShowDialog($form)
  $picker.Dispose()
  if (-not $script:SelectedThemePath) { return $Text.cancelled }
  return Apply-ThemePackage -ThemeDir $script:SelectedThemePath
}

function Assert-PackageReady {
  foreach ($path in @($InstallScript, $StartScript, $RestoreScript, $VerifyScript)) {
    if (-not (Test-Path -LiteralPath $path)) { throw ($Text.missingFile + $path) }
  }
}

function Set-UiBusy {
  param([bool]$Busy, [string]$Body)
  $form.UseWaitCursor = $Busy
  foreach ($button in $script:ActionButtons) { $button.Enabled = -not $Busy }
  $statusLabel.Text = $Body
  [System.Windows.Forms.Application]::DoEvents()
}

function ConvertTo-ProcessArgument {
  param([AllowNull()][string]$Value)
  if ($null -eq $Value) { return '""' }
  if ($Value.Contains('"')) { throw 'Process arguments containing a double quote are not supported.' }
  if ($Value -notmatch '\s') { return $Value }
  $escaped = [regex]::Replace($Value, '(\\+)$', '$1$1')
  return '"' + $escaped + '"'
}

function Start-ScriptProcess {
  param(
    [Parameter(Mandatory = $true)][string]$BusyText,
    [Parameter(Mandatory = $true)][string]$DoneText,
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [string[]]$Arguments = @(),
    [string]$ExtraDoneText = ''
  )

  try {
    New-Item -ItemType Directory -Force -Path $OutputsRoot | Out-Null
    Set-UiBusy -Busy $true -Body $BusyText

    $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $Arguments
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $stdoutPath = Join-Path $OutputsRoot "action-$stamp.out.log"
    $stderrPath = Join-Path $OutputsRoot "action-$stamp.err.log"

    $process = Start-Process -FilePath 'powershell.exe' `
      -ArgumentList (($argumentList | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' ') `
      -WindowStyle Hidden `
      -RedirectStandardOutput $stdoutPath `
      -RedirectStandardError $stderrPath `
      -PassThru
    if ($null -eq $process) { throw $Text.scriptStartFailed }

    $content = @(
      "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
      "Script: $ScriptPath",
      "StartedProcessId: $($process.Id)",
      "Status: started",
      "StdoutLog: $stdoutPath",
      "StderrLog: $stderrPath",
      '',
      $Text.backgroundOperationNote
    ) -join "`r`n"
    Set-Content -LiteralPath $LogPath -Value $content -Encoding UTF8
    Set-UiBusy -Busy $false -Body $DoneText
    Show-Message ($DoneText + $ExtraDoneText + "`r`n`r`n" + $Text.backgroundOperationNote)
  } catch {
    Write-GuiCrashLog $_
    Set-UiBusy -Busy $false -Body $Text.failedStatus
    Show-Message $_.Exception.Message $Text.failedTitle ([System.Windows.Forms.MessageBoxIcon]::Error)
  }
}

function Invoke-GuiAction {
  param(
    [Parameter(Mandatory = $true)][string]$BusyText,
    [Parameter(Mandatory = $true)][string]$DoneText,
    [Parameter(Mandatory = $true)][scriptblock]$Action
  )

  try {
    Set-UiBusy -Busy $true -Body $BusyText
    $result = & $Action
    Set-UiBusy -Busy $false -Body $DoneText
    if ($result) {
      Show-Message ($DoneText + "`r`n`r`n" + $result)
    } else {
      Show-Message $DoneText
    }
  } catch {
    Set-UiBusy -Busy $false -Body $Text.failedStatus
    Show-Message $_.Exception.Message $Text.failedTitle ([System.Windows.Forms.MessageBoxIcon]::Error)
  }
}

function Get-OfficialCodexProcesses {
  try {
    $packages = @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop)
  } catch {
    return @()
  }
  $roots = @($packages | Where-Object { $_.InstallLocation } | ForEach-Object {
    [System.IO.Path]::GetFullPath("$($_.InstallLocation)").TrimEnd('\') + '\'
  })
  if ($roots.Count -eq 0) { return @() }

  $items = @()
  $processInfos = @()
  try {
    $processInfos = @(Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe'" -ErrorAction Stop)
  } catch {
    return @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue | ForEach-Object {
      [pscustomobject]@{ ProcessId = [int]$_.Id; Path = "$($_.Path)" }
    })
  }

  foreach ($processInfo in $processInfos) {
    $path = "$($processInfo.ExecutablePath)"
    if (-not $path) {
      try { $path = "$((Get-Process -Id ([int]$processInfo.ProcessId) -ErrorAction Stop).Path)" } catch { $path = '' }
    }
    if (-not $path) { continue }
    $fullPath = [System.IO.Path]::GetFullPath($path)
    foreach ($root in $roots) {
      if ($fullPath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        $items += [pscustomobject]@{ ProcessId = [int]$processInfo.ProcessId; Path = $fullPath }
        break
      }
    }
  }
  return $items
}

function Close-CodexForInstall {
  $processes = @(Get-OfficialCodexProcesses)
  if ($processes.Count -eq 0) { return $true }
  if (-not (Confirm-Action $Text.installCloseConfirm)) { return $false }

  foreach ($item in $processes) {
    try { [void](Get-Process -Id $item.ProcessId -ErrorAction Stop).CloseMainWindow() } catch {}
  }

  $deadline = (Get-Date).AddSeconds(10)
  do {
    Start-Sleep -Milliseconds 250
    $remaining = @(Get-OfficialCodexProcesses)
  } while ($remaining.Count -gt 0 -and (Get-Date) -lt $deadline)

  foreach ($item in @(Get-OfficialCodexProcesses)) {
    try { Stop-Process -Id $item.ProcessId -Force -ErrorAction Stop } catch {}
  }
  Start-Sleep -Milliseconds 500
  if (@(Get-OfficialCodexProcesses).Count -gt 0) { throw $Text.installCloseFailed }
  return $true
}

function Install-Skin {
  if (-not (Close-CodexForInstall)) { return $Text.cancelled }
  Start-ScriptProcess -BusyText $Text.busyInstall -DoneText $Text.doneInstall `
    -ScriptPath $InstallScript -Arguments @('-Port', "$Port")
}

function Start-Skin {
  if (-not (Confirm-Action $Text.startConfirm)) { return $Text.cancelled }
  Start-ScriptProcess -BusyText $Text.busyStart -DoneText $Text.doneStart `
    -ScriptPath $StartScript -Arguments @('-Port', "$Port", '-RestartExisting')
}

function Restart-Start-Skin {
  if (-not (Confirm-Action $Text.restartConfirm)) { return $Text.cancelled }
  Start-ScriptProcess -BusyText $Text.busyRestart -DoneText $Text.doneRestart `
    -ScriptPath $StartScript -Arguments @('-Port', "$Port", '-RestartExisting')
}

function Verify-Skin {
  New-Item -ItemType Directory -Force -Path $OutputsRoot | Out-Null
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $screenshot = Join-Path $OutputsRoot "verify-$stamp.png"
  Start-ScriptProcess -BusyText $Text.busyVerify -DoneText $Text.doneVerify `
    -ScriptPath $VerifyScript -Arguments @('-Port', "$Port", '-ScreenshotPath', $screenshot) `
    -ExtraDoneText ("`r`n`r`n" + $Text.screenshotSaved + $screenshot)
}

function Select-CustomImage {
  $dialog = New-Object System.Windows.Forms.OpenFileDialog
  $dialog.Title = $Text.chooseImageTitle
  $dialog.Filter = $Text.imageFilter
  $dialog.Multiselect = $false
  if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return $Text.cancelled }
  $scope = Choose-ImageScope
  if ($scope -eq 'cancel') { return $Text.cancelled }

  if (($scope -eq 'all' -or $scope -eq 'home') -and -not (Test-Path -LiteralPath $ArtBackupPath) -and (Test-Path -LiteralPath $ArtPath)) {
    Copy-Item -LiteralPath $ArtPath -Destination $ArtBackupPath -Force
  }
  if (($scope -eq 'all' -or $scope -eq 'background') -and -not (Test-Path -LiteralPath $BackgroundArtBackupPath) -and (Test-Path -LiteralPath $BackgroundArtPath)) {
    Copy-Item -LiteralPath $BackgroundArtPath -Destination $BackgroundArtBackupPath -Force
  }

  if ($scope -eq 'all' -or $scope -eq 'home') {
    Save-ThemeImage -SourcePath $dialog.FileName -DestinationPath $ArtPath
  }
  if ($scope -eq 'all' -or $scope -eq 'background') {
    Save-ThemeImage -SourcePath $dialog.FileName -DestinationPath $BackgroundArtPath
  }
  Update-ThemePalette -ImagePath $dialog.FileName
  return ($Text.customImageDone + $Text.restartToApply)
}

function Restore-DefaultImage {
  $restored = $false
  if (Test-Path -LiteralPath $ArtBackupPath) {
    Copy-Item -LiteralPath $ArtBackupPath -Destination $ArtPath -Force
    $restored = $true
  }
  if (Test-Path -LiteralPath $BackgroundArtBackupPath) {
    Copy-Item -LiteralPath $BackgroundArtBackupPath -Destination $BackgroundArtPath -Force
    $restored = $true
  }
  if (-not $restored) { return $Text.noDefaultBackup }
  if (Test-Path -LiteralPath $ArtPath) {
    Update-ThemePalette -ImagePath $ArtPath
  }
  return ($Text.defaultImageDone + $Text.restartToApply)
}

function Restore-Official {
  Start-ScriptProcess -BusyText $Text.busyRestore -DoneText $Text.doneRestore `
    -ScriptPath $RestoreScript -Arguments @('-Port', "$Port", '-RestoreBaseTheme', '-PromptRestart')
}

function Uninstall-Skin {
  if (-not (Confirm-Action $Text.uninstallConfirm)) { return $Text.cancelled }
  Start-ScriptProcess -BusyText $Text.busyUninstall -DoneText $Text.doneUninstall `
    -ScriptPath $RestoreScript -Arguments @('-Port', "$Port", '-Uninstall', '-RestoreBaseTheme', '-PromptRestart')
}

function Open-Logs {
  New-Item -ItemType Directory -Force -Path $OutputsRoot | Out-Null
  $stateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
  New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
  Start-Process explorer.exe $OutputsRoot
  Start-Process explorer.exe $stateRoot
}

Assert-PackageReady
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = $Text.windowTitle
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(760, 590)
$form.MinimumSize = New-Object System.Drawing.Size(760, 590)
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.BackColor = [System.Drawing.Color]::FromArgb(255, 248, 252)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = $Text.title
$titleLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 22, [System.Drawing.FontStyle]::Bold)
$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(92, 42, 115)
$titleLabel.Location = New-Object System.Drawing.Point(30, 24)
$titleLabel.Size = New-Object System.Drawing.Size(420, 42)
$form.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = $Text.subtitle
$subtitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(118, 83, 132)
$subtitleLabel.Location = New-Object System.Drawing.Point(34, 72)
$subtitleLabel.Size = New-Object System.Drawing.Size(680, 24)
$form.Controls.Add($subtitleLabel)

$statusPanel = New-Object System.Windows.Forms.Panel
$statusPanel.Location = New-Object System.Drawing.Point(30, 112)
$statusPanel.Size = New-Object System.Drawing.Size(700, 58)
$statusPanel.BackColor = [System.Drawing.Color]::White
$statusPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$form.Controls.Add($statusPanel)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = $Text.readyStatus
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(77, 37, 103)
$statusLabel.Location = New-Object System.Drawing.Point(16, 17)
$statusLabel.Size = New-Object System.Drawing.Size(660, 24)
$statusPanel.Controls.Add($statusLabel)

$buttonPanel = New-Object System.Windows.Forms.TableLayoutPanel
$buttonPanel.Location = New-Object System.Drawing.Point(30, 194)
$buttonPanel.Size = New-Object System.Drawing.Size(700, 280)
$buttonPanel.ColumnCount = 3
$buttonPanel.RowCount = 4
$buttonPanel.BackColor = $form.BackColor
for ($i = 0; $i -lt 3; $i++) {
  [void]$buttonPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 33.33)))
}
for ($i = 0; $i -lt 4; $i++) {
  [void]$buttonPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 25)))
}
$form.Controls.Add($buttonPanel)

function New-ActionButton {
  param(
    [Parameter(Mandatory = $true)][string]$Body,
    [Parameter(Mandatory = $true)][scriptblock]$Click
  )
  $button = New-Object System.Windows.Forms.Button
  $button.Text = $Body
  $button.Dock = [System.Windows.Forms.DockStyle]::Fill
  $button.Margin = New-Object System.Windows.Forms.Padding(8)
  $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(222, 151, 198)
  $button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(255, 232, 246)
  $button.BackColor = [System.Drawing.Color]::White
  $button.ForeColor = [System.Drawing.Color]::FromArgb(83, 37, 110)
  $button.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
  $button.Add_Click({
    try {
      & $Click
    } catch {
      Write-GuiCrashLog $_
      Set-UiBusy -Busy $false -Body $Text.failedStatus
      Show-Message $_.Exception.Message $Text.failedTitle ([System.Windows.Forms.MessageBoxIcon]::Error)
    }
  }.GetNewClosure())
  return $button
}

$script:ActionButtons = @()
$buttonSpecs = @(
  @{ Text = $Text.buttonInstall; Action = { Install-Skin } },
  @{ Text = $Text.buttonStart; Action = { Start-Skin } },
  @{ Text = $Text.buttonRestart; Action = { Restart-Start-Skin } },
  @{ Text = $Text.buttonVerify; Action = { Verify-Skin } },
  @{ Text = $Text.buttonImage; Action = { Invoke-GuiAction $Text.busyImage $Text.doneImage { Select-CustomImage } } },
  @{ Text = (Get-TextValue -Name 'buttonTheme' -Default '主题包 / 控件风格'); Action = { Invoke-GuiAction 'Applying theme package...' 'Theme package applied.' { Select-ThemePackage } } },
  @{ Text = $Text.buttonDefaultImage; Action = { Invoke-GuiAction $Text.busyDefaultImage $Text.doneDefaultImage { Restore-DefaultImage } } },
  @{ Text = $Text.buttonRestore; Action = { Restore-Official } },
  @{ Text = $Text.buttonUninstall; Action = { Uninstall-Skin } },
  @{ Text = $Text.buttonLogs; Action = { Open-Logs } }
)

for ($index = 0; $index -lt $buttonSpecs.Count; $index++) {
  $button = New-ActionButton -Body $buttonSpecs[$index].Text -Click $buttonSpecs[$index].Action
  $script:ActionButtons += $button
  $buttonPanel.Controls.Add($button, $index % 3, [math]::Floor($index / 3))
}

$noteLabel = New-Object System.Windows.Forms.Label
$noteLabel.Text = $Text.safetyNote
$noteLabel.ForeColor = [System.Drawing.Color]::FromArgb(120, 85, 125)
$noteLabel.Location = New-Object System.Drawing.Point(34, 498)
$noteLabel.Size = New-Object System.Drawing.Size(690, 34)
$form.Controls.Add($noteLabel)

$fallbackLabel = New-Object System.Windows.Forms.Label
$fallbackLabel.Text = $Text.fallbackNote
$fallbackLabel.ForeColor = [System.Drawing.Color]::FromArgb(150, 110, 150)
$fallbackLabel.Location = New-Object System.Drawing.Point(34, 532)
$fallbackLabel.Size = New-Object System.Drawing.Size(690, 24)
$form.Controls.Add($fallbackLabel)

[void]$form.ShowDialog()
$form.Dispose()
[System.Windows.Forms.Application]::Exit()
exit 0


