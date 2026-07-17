[CmdletBinding()]
param(
  [int]$Port = 9335
)

$ErrorActionPreference = 'Stop'
$PortExplicit = $PSBoundParameters.ContainsKey('Port')

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
$ThemeScript = Join-Path $ScriptsRoot 'theme-windows.ps1'
$LogPath = Join-Path $OutputsRoot 'last-action.log'
$CrashLogPath = Join-Path $OutputsRoot 'gui-crash.log'

function Read-TextMap {
  if (-not (Test-Path -LiteralPath $TextPath)) { throw "Missing UI text file: $TextPath" }
  $json = [System.IO.File]::ReadAllText($TextPath, [System.Text.Encoding]::UTF8)
  return $json | ConvertFrom-Json
}

$Text = Read-TextMap

. (Join-Path $ScriptsRoot 'common-windows.ps1')
. $ThemeScript

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

function Initialize-OneClickThemeStore {
  return Initialize-DreamSkinThemeStore -SkillRoot $WindowsRoot -StateRoot (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin')
}

function Set-DefaultDreamTheme {
  $paths = Initialize-OneClickThemeStore
  $theme = (Read-DreamSkinUtf8File -Path (Join-Path $WindowsRoot 'assets\theme.json')) | ConvertFrom-Json -ErrorAction Stop
  $image = Join-Path $WindowsRoot 'assets\dream-reference.jpg'
  $null = Set-DreamSkinActiveTheme -ImagePath $image -Theme $theme -StateRoot $paths.Root
  return 'Default adaptive theme restored. If Codex is running, the watcher will update it shortly; otherwise start Dream Skin.'
}

function Import-ExplicitTheme {
  param([Parameter(Mandatory = $true)][string]$ThemeDir)
  $paths = Initialize-OneClickThemeStore
  $loaded = Read-DreamSkinTheme -ThemeDirectory $ThemeDir
  $theme = $loaded.Theme | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  $active = Set-DreamSkinActiveTheme -ImagePath $loaded.ImagePath -Theme $theme -FontPath $loaded.FontPath -StateRoot $paths.Root
  return "Theme applied: $($active.Theme.name). If Codex is running, it will update shortly; otherwise start Dream Skin."
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

function Show-ThemeImagePreview {
  param(
    [Parameter(Mandatory = $true)][string]$ImagePath,
    [Parameter(Mandatory = $true)][string]$ThemeName
  )

  $preview = New-Object System.Windows.Forms.Form
  $preview.Text = '确认主题预览'
  $preview.StartPosition = 'CenterParent'
  $preview.ClientSize = New-Object System.Drawing.Size(620, 470)
  $preview.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
  $preview.MaximizeBox = $false
  $preview.MinimizeBox = $false
  $preview.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

  $label = New-Object System.Windows.Forms.Label
  $label.Text = "主题：$ThemeName"
  $label.Location = New-Object System.Drawing.Point(18, 14)
  $label.Size = New-Object System.Drawing.Size(580, 24)
  $preview.Controls.Add($label)

  $box = New-Object System.Windows.Forms.PictureBox
  $box.Location = New-Object System.Drawing.Point(18, 46)
  $box.Size = New-Object System.Drawing.Size(580, 340)
  $box.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
  $box.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $box.Image = [System.Drawing.Image]::FromFile($ImagePath)
  $preview.Controls.Add($box)

  $ok = New-Object System.Windows.Forms.Button
  $ok.Text = '生成并应用'
  $ok.Location = New-Object System.Drawing.Point(408, 410)
  $ok.Size = New-Object System.Drawing.Size(92, 34)
  $preview.AcceptButton = $ok
  $preview.Controls.Add($ok)

  $cancel = New-Object System.Windows.Forms.Button
  $cancel.Text = '取消'
  $cancel.Location = New-Object System.Drawing.Point(506, 410)
  $cancel.Size = New-Object System.Drawing.Size(92, 34)
  $preview.CancelButton = $cancel
  $preview.Controls.Add($cancel)

  $script:ThemePreviewConfirmed = $false
  $ok.Add_Click({ $script:ThemePreviewConfirmed = $true; $preview.Close() })
  $cancel.Add_Click({ $preview.Close() })

  [void]$preview.ShowDialog($form)
  if ($box.Image) { $box.Image.Dispose() }
  $preview.Dispose()
  return $script:ThemePreviewConfirmed
}

function Show-ThemeOptionsDialog {
  $dialog = New-Object System.Windows.Forms.Form
  $dialog.Text = '制作主题'
  $dialog.StartPosition = 'CenterParent'
  $dialog.ClientSize = New-Object System.Drawing.Size(460, 510)
  $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
  $dialog.MaximizeBox = $false
  $dialog.MinimizeBox = $false
  $dialog.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

  $nameLabel = New-Object System.Windows.Forms.Label
  $nameLabel.Text = '主题名称'
  $nameLabel.Location = New-Object System.Drawing.Point(18, 18)
  $nameLabel.Size = New-Object System.Drawing.Size(110, 24)
  $dialog.Controls.Add($nameLabel)

  $textBox = New-Object System.Windows.Forms.TextBox
  $textBox.Location = New-Object System.Drawing.Point(140, 16)
  $textBox.Size = New-Object System.Drawing.Size(292, 24)
  $textBox.Text = '我的 Dream Skin 主题'
  $dialog.Controls.Add($textBox)

  $styleLabel = New-Object System.Windows.Forms.Label
  $styleLabel.Text = '控件配色'
  $styleLabel.Location = New-Object System.Drawing.Point(18, 58)
  $styleLabel.Size = New-Object System.Drawing.Size(110, 24)
  $dialog.Controls.Add($styleLabel)

  $styleBox = New-Object System.Windows.Forms.ComboBox
  $styleBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
  $styleBox.Location = New-Object System.Drawing.Point(140, 56)
  $styleBox.Size = New-Object System.Drawing.Size(292, 24)
  $styleOptions = @(
    [pscustomobject]@{ Label = '自动从图片取色'; Accent = $null },
    [pscustomobject]@{ Label = '玫瑰粉'; Accent = '#d86b8d' },
    [pscustomobject]@{ Label = '清爽蓝'; Accent = '#4f8cff' },
    [pscustomobject]@{ Label = '梦幻紫'; Accent = '#8b5cf6' },
    [pscustomobject]@{ Label = '高级金'; Accent = '#c8922e' },
    [pscustomobject]@{ Label = '热烈红'; Accent = '#e5484d' }
  )
  $styleBox.DisplayMember = 'Label'
  foreach ($option in $styleOptions) { [void]$styleBox.Items.Add($option) }
  $styleBox.SelectedIndex = 0
  $dialog.Controls.Add($styleBox)

  $appearanceLabel = New-Object System.Windows.Forms.Label
  $appearanceLabel.Text = '明暗模式'
  $appearanceLabel.Location = New-Object System.Drawing.Point(18, 98)
  $appearanceLabel.Size = New-Object System.Drawing.Size(110, 24)
  $dialog.Controls.Add($appearanceLabel)

  $appearanceBox = New-Object System.Windows.Forms.ComboBox
  $appearanceBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
  $appearanceBox.Location = New-Object System.Drawing.Point(140, 96)
  $appearanceBox.Size = New-Object System.Drawing.Size(292, 24)
  foreach ($option in @(
    [pscustomobject]@{ Label = '跟随 Codex / 系统'; Value = 'auto' },
    [pscustomobject]@{ Label = '浅色控件'; Value = 'light' },
    [pscustomobject]@{ Label = '深色控件'; Value = 'dark' }
  )) { [void]$appearanceBox.Items.Add($option) }
  $appearanceBox.DisplayMember = 'Label'
  $appearanceBox.SelectedIndex = 0
  $dialog.Controls.Add($appearanceBox)

  $safeLabel = New-Object System.Windows.Forms.Label
  $safeLabel.Text = '首页文字遮罩'
  $safeLabel.Location = New-Object System.Drawing.Point(18, 138)
  $safeLabel.Size = New-Object System.Drawing.Size(110, 24)
  $dialog.Controls.Add($safeLabel)

  $safeBox = New-Object System.Windows.Forms.ComboBox
  $safeBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
  $safeBox.Location = New-Object System.Drawing.Point(140, 136)
  $safeBox.Size = New-Object System.Drawing.Size(292, 24)
  foreach ($option in @(
    [pscustomobject]@{ Label = '智能判断'; Value = 'auto' },
    [pscustomobject]@{ Label = '左侧遮罩'; Value = 'left' },
    [pscustomobject]@{ Label = '右侧遮罩'; Value = 'right' },
    [pscustomobject]@{ Label = '居中遮罩'; Value = 'center' },
    [pscustomobject]@{ Label = '不加遮罩'; Value = 'none' }
  )) { [void]$safeBox.Items.Add($option) }
  $safeBox.DisplayMember = 'Label'
  $safeBox.SelectedIndex = 0
  $dialog.Controls.Add($safeBox)

  $taskLabel = New-Object System.Windows.Forms.Label
  $taskLabel.Text = '任务背景'
  $taskLabel.Location = New-Object System.Drawing.Point(18, 178)
  $taskLabel.Size = New-Object System.Drawing.Size(110, 24)
  $dialog.Controls.Add($taskLabel)

  $taskBox = New-Object System.Windows.Forms.ComboBox
  $taskBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
  $taskBox.Location = New-Object System.Drawing.Point(140, 176)
  $taskBox.Size = New-Object System.Drawing.Size(292, 24)
  foreach ($option in @(
    [pscustomobject]@{ Label = '智能遮罩'; Value = 'auto' },
    [pscustomobject]@{ Label = '柔和背景遮罩'; Value = 'ambient' },
    [pscustomobject]@{ Label = '顶部横幅遮罩'; Value = 'banner' },
    [pscustomobject]@{ Label = '不显示背景图'; Value = 'off' }
  )) { [void]$taskBox.Items.Add($option) }
  $taskBox.DisplayMember = 'Label'
  $taskBox.SelectedIndex = 0
  $dialog.Controls.Add($taskBox)

  $taskChromeLabel = New-Object System.Windows.Forms.Label
  $taskChromeLabel.Text = '任务控件遮罩'
  $taskChromeLabel.Location = New-Object System.Drawing.Point(18, 218)
  $taskChromeLabel.Size = New-Object System.Drawing.Size(110, 24)
  $dialog.Controls.Add($taskChromeLabel)

  $taskChromeBox = New-Object System.Windows.Forms.ComboBox
  $taskChromeBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
  $taskChromeBox.Location = New-Object System.Drawing.Point(140, 216)
  $taskChromeBox.Size = New-Object System.Drawing.Size(292, 24)
  foreach ($option in @(
    [pscustomobject]@{ Label = '智能默认'; Value = 'auto' },
    [pscustomobject]@{ Label = '顶部 + 内容 + 输入区'; Value = 'all' },
    [pscustomobject]@{ Label = '只保留内容遮罩'; Value = 'content' },
    [pscustomobject]@{ Label = '只保留顶部栏遮罩'; Value = 'top' },
    [pscustomobject]@{ Label = '只保留输入区遮罩'; Value = 'bottom' },
    [pscustomobject]@{ Label = '尽量透明'; Value = 'none' }
  )) { [void]$taskChromeBox.Items.Add($option) }
  $taskChromeBox.DisplayMember = 'Label'
  $taskChromeBox.SelectedIndex = 0
  $dialog.Controls.Add($taskChromeBox)

  $fontLabel = New-Object System.Windows.Forms.Label
  $fontLabel.Text = '字体'
  $fontLabel.Location = New-Object System.Drawing.Point(18, 258)
  $fontLabel.Size = New-Object System.Drawing.Size(110, 24)
  $dialog.Controls.Add($fontLabel)

  $fontBox = New-Object System.Windows.Forms.ComboBox
  $fontBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
  $fontBox.Location = New-Object System.Drawing.Point(140, 256)
  $fontBox.Size = New-Object System.Drawing.Size(292, 24)
  foreach ($option in @(
    [pscustomobject]@{ Label = '默认现代字体'; Value = '"Segoe UI Variable Text", "Segoe UI", "Microsoft YaHei UI", system-ui, sans-serif'; CustomFile = $false },
    [pscustomobject]@{ Label = '微软雅黑'; Value = '"Microsoft YaHei UI", "Microsoft YaHei", sans-serif'; CustomFile = $false },
    [pscustomobject]@{ Label = '等线 / 简洁'; Value = 'DengXian, "Microsoft YaHei UI", sans-serif'; CustomFile = $false },
    [pscustomobject]@{ Label = '代码感'; Value = '"Cascadia Code", "Microsoft YaHei UI", monospace'; CustomFile = $false },
    [pscustomobject]@{ Label = '选择字体文件 TTF/OTF/WOFF'; Value = '"Codex Dream Theme Font", "Microsoft YaHei UI", system-ui, sans-serif'; CustomFile = $true }
  )) { [void]$fontBox.Items.Add($option) }
  $fontBox.DisplayMember = 'Label'
  $fontBox.SelectedIndex = 0
  $dialog.Controls.Add($fontBox)

  $textColorLabel = New-Object System.Windows.Forms.Label
  $textColorLabel.Text = '字体颜色'
  $textColorLabel.Location = New-Object System.Drawing.Point(18, 298)
  $textColorLabel.Size = New-Object System.Drawing.Size(110, 24)
  $dialog.Controls.Add($textColorLabel)

  $textColorBox = New-Object System.Windows.Forms.ComboBox
  $textColorBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
  $textColorBox.Location = New-Object System.Drawing.Point(140, 296)
  $textColorBox.Size = New-Object System.Drawing.Size(292, 24)
  foreach ($option in @(
    [pscustomobject]@{ Label = '自动'; Text = $null; Muted = $null },
    [pscustomobject]@{ Label = '深墨色'; Text = '#241f27'; Muted = '#665b6b' },
    [pscustomobject]@{ Label = '柔白色'; Text = '#f8f4ff'; Muted = '#d8ccdf' },
    [pscustomobject]@{ Label = '暖棕色'; Text = '#3a2a1f'; Muted = '#7a6253' },
    [pscustomobject]@{ Label = '冷灰蓝'; Text = '#dce8f2'; Muted = '#aebdca' }
  )) { [void]$textColorBox.Items.Add($option) }
  $textColorBox.DisplayMember = 'Label'
  $textColorBox.SelectedIndex = 0
  $dialog.Controls.Add($textColorBox)

  $note = New-Object System.Windows.Forms.Label
  $note.Text = '提示：任务背景控制是否显示背景图；任务控件遮罩控制顶部栏、内容区和输入区的半透明底色。'
  $note.Location = New-Object System.Drawing.Point(18, 340)
  $note.Size = New-Object System.Drawing.Size(414, 58)
  $dialog.Controls.Add($note)

  $ok = New-Object System.Windows.Forms.Button
  $ok.Text = '下一步'
  $ok.Location = New-Object System.Drawing.Point(270, 458)
  $ok.Size = New-Object System.Drawing.Size(78, 32)
  $dialog.AcceptButton = $ok
  $dialog.Controls.Add($ok)

  $cancel = New-Object System.Windows.Forms.Button
  $cancel.Text = '取消'
  $cancel.Location = New-Object System.Drawing.Point(354, 458)
  $cancel.Size = New-Object System.Drawing.Size(78, 32)
  $dialog.CancelButton = $cancel
  $dialog.Controls.Add($cancel)

  $script:ThemeOptionsDialogValue = $null
  $ok.Add_Click({
    $value = $textBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
      [void][System.Windows.Forms.MessageBox]::Show('主题名称不能为空。', '制作主题')
      return
    }
    $script:ThemeOptionsDialogValue = [pscustomobject]@{
      Name = $value
      Accent = $styleBox.SelectedItem.Accent
      Appearance = $appearanceBox.SelectedItem.Value
      SafeArea = $safeBox.SelectedItem.Value
      TaskMode = $taskBox.SelectedItem.Value
      TaskChrome = $taskChromeBox.SelectedItem.Value
      FontFamily = $fontBox.SelectedItem.Value
      FontFileRequested = [bool]$fontBox.SelectedItem.CustomFile
      TextColor = $textColorBox.SelectedItem.Text
      MutedTextColor = $textColorBox.SelectedItem.Muted
    }
    $dialog.Close()
  })
  $cancel.Add_Click({ $dialog.Close() })

  [void]$dialog.ShowDialog($form)
  $dialog.Dispose()
  return $script:ThemeOptionsDialogValue
}

function New-OneClickTheme {
  $options = Show-ThemeOptionsDialog
  if (-not $options) { return $Text.cancelled }
  $name = $options.Name

  $dialog = New-Object System.Windows.Forms.OpenFileDialog
  $dialog.Title = '选择主题图片'
  $dialog.Filter = 'Image files (*.png;*.jpg;*.jpeg;*.webp)|*.png;*.jpg;*.jpeg;*.webp'
  $dialog.Multiselect = $false
  if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return $Text.cancelled }
  if (-not (Show-ThemeImagePreview -ImagePath $dialog.FileName -ThemeName $name)) { return $Text.cancelled }

  $fontSourcePath = $null
  if ($options.FontFileRequested) {
    $fontDialog = New-Object System.Windows.Forms.OpenFileDialog
    $fontDialog.Title = '选择字体文件'
    $fontDialog.Filter = 'Font files (*.ttf;*.otf;*.woff;*.woff2)|*.ttf;*.otf;*.woff;*.woff2'
    $fontDialog.Multiselect = $false
    try {
      if ($fontDialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return $Text.cancelled }
      Assert-DreamSkinFontFile -Path $fontDialog.FileName
      $fontSourcePath = $fontDialog.FileName
    } finally {
      $fontDialog.Dispose()
    }
  }

  $paths = Initialize-OneClickThemeStore
  Assert-DreamSkinImageFile -Path $dialog.FileName

  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $baseId = ConvertTo-SafeThemeId -Name $name
  $themeId = "$baseId-$stamp"
  $exportRoot = Join-Path $OutputsRoot 'themes'
  $themeDir = Join-Path $exportRoot $themeId
  New-Item -ItemType Directory -Force -Path $themeDir | Out-Null

  $imageName = 'art.jpg'
  $imagePath = Join-Path $themeDir $imageName
  Save-ThemeImage -SourcePath $dialog.FileName -DestinationPath $imagePath

  $fontFileName = $null
  $fontPath = $null
  if ($fontSourcePath) {
    $fontFileName = 'font' + [System.IO.Path]::GetExtension($fontSourcePath).ToLowerInvariant()
    $fontPath = Join-Path $themeDir $fontFileName
    Copy-Item -LiteralPath $fontSourcePath -Destination $fontPath -Force
    Assert-DreamSkinFontFile -Path $fontPath
  }

  $accent = if ($options.Accent) { $options.Accent } else { Get-ImageAccentHex -ImagePath $imagePath }
  $theme = [ordered]@{
    schemaVersion = 1
    id = $themeId
    name = $name
    image = $imageName
    appearance = $options.Appearance
    brandSubtitle = 'CODEX DREAM SKIN'
    tagline = "$name 已就绪。"
    statusText = 'CUSTOM THEME ONLINE'
    quote = 'MAKE SOMETHING WONDERFUL'
    art = [ordered]@{
      focusX = 0.5
      focusY = 0.42
      safeArea = $options.SafeArea
      taskMode = $options.TaskMode
      taskChrome = $options.TaskChrome
    }
    palette = [ordered]@{
      accent = $accent
    }
    typography = [ordered]@{
      fontFamily = $options.FontFamily
    }
  }
  if ($fontFileName) { $theme.typography.fontFile = $fontFileName }
  if ($options.TextColor) { $theme.palette.text = $options.TextColor }
  if ($options.MutedTextColor) { $theme.palette.textMuted = $options.MutedTextColor }
  Write-DreamSkinTheme -ThemeDirectory $themeDir -Theme ([pscustomobject]$theme)
  $loaded = Read-DreamSkinTheme -ThemeDirectory $themeDir
  $activeTheme = $loaded.Theme | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  $active = Set-DreamSkinActiveTheme -ImagePath $loaded.ImagePath -Theme $activeTheme -FontPath $loaded.FontPath -StateRoot $paths.Root
  $null = Save-DreamSkinCurrentTheme -Name $name -StateRoot $paths.Root
  $restart = Restart-DreamSkinAfterThemeChange
  $previewPath = Join-Path $OutputsRoot ("theme-preview-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".png")
  $verifyMessage = ''
  try {
    $null = Invoke-ScriptProcess -ScriptPath $VerifyScript `
      -Arguments ((Get-PortArguments) + @('-ScreenshotPath', $previewPath)) -TimeoutSeconds 90
    if (Test-Path -LiteralPath $previewPath) {
      Start-Process -FilePath $previewPath | Out-Null
      $verifyMessage = "`r`n效果截图：$previewPath"
    }
  } catch {
    $verifyMessage = "`r`n主题已生成，但自动截图失败：$($_.Exception.Message)"
  }

  return "主题已制作并应用：$($active.Theme.name)`r`n主题文件夹：$themeDir`r`n强调色：$accent$verifyMessage`r`n`r`n$restart"
}

function Select-ThemePackage {
  $paths = Initialize-OneClickThemeStore
  $packages = @(Get-DreamSkinSavedThemes -StateRoot $paths.Root -SkipImageMetadata)
  $picker = New-Object System.Windows.Forms.Form
  $picker.Text = 'Choose Dream Skin theme'
  $picker.StartPosition = 'CenterParent'
  $picker.ClientSize = New-Object System.Drawing.Size(440, 330)
  $picker.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
  $picker.MaximizeBox = $false
  $picker.MinimizeBox = $false
  $picker.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

  $label = New-Object System.Windows.Forms.Label
  $label.Text = 'Choose a saved theme, or browse to a theme.json folder.'
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
    if (Test-Path -LiteralPath $paths.Saved -PathType Container) { $dialog.SelectedPath = $paths.Saved }
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
  if (Test-DreamSkinThemePathWithin -Path $script:SelectedThemePath -Root $paths.Saved) {
    $active = Use-DreamSkinSavedTheme -ThemeDirectory $script:SelectedThemePath -StateRoot $paths.Root
    $restart = Restart-DreamSkinAfterThemeChange
    return "主题已应用：$($active.Theme.name)`r`n`r`n$restart"
  }
  $result = Import-ExplicitTheme -ThemeDir $script:SelectedThemePath
  $restart = Restart-DreamSkinAfterThemeChange
  return "$result`r`n`r`n$restart"
}

function Assert-PackageReady {
  foreach ($path in @($InstallScript, $StartScript, $RestoreScript, $VerifyScript, $ThemeScript)) {
    if (-not (Test-Path -LiteralPath $path)) { throw ($Text.missingFile + $path) }
  }
}

function Get-PortArguments {
  if ($PortExplicit) { return @('-Port', "$Port") }
  return @()
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

function Invoke-ScriptProcess {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [string[]]$Arguments = @(),
    [int]$TimeoutSeconds = 120
  )

  New-Item -ItemType Directory -Force -Path $OutputsRoot | Out-Null

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

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while (-not $process.HasExited) {
    if ((Get-Date) -ge $deadline) {
      try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
      throw "操作超时，已停止脚本。日志：$stdoutPath / $stderrPath"
    }
    Start-Sleep -Milliseconds 250
    [System.Windows.Forms.Application]::DoEvents()
  }
  [void]$process.WaitForExit(1000)
  $process.Refresh()

  $stdout = if (Test-Path -LiteralPath $stdoutPath) { [System.IO.File]::ReadAllText($stdoutPath, [System.Text.Encoding]::UTF8).Trim() } else { '' }
  $stderr = if (Test-Path -LiteralPath $stderrPath) { [System.IO.File]::ReadAllText($stderrPath, [System.Text.Encoding]::UTF8).Trim() } else { '' }
  $exitCode = if ($null -ne $process.ExitCode) { [int]$process.ExitCode } elseif ($stderr) { 1 } else { 0 }
  $content = @(
    "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "Script: $ScriptPath",
    "ProcessId: $($process.Id)",
    "ExitCode: $exitCode",
    "StdoutLog: $stdoutPath",
    "StderrLog: $stderrPath",
    '',
    'STDOUT:',
    $stdout,
    '',
    'STDERR:',
    $stderr
  ) -join "`r`n"
  Set-Content -LiteralPath $LogPath -Value $content -Encoding UTF8

  if ($exitCode -ne 0) {
    $detail = (($stderr, $stdout) | Where-Object { $_ } | Select-Object -First 1)
    if (-not $detail) { $detail = "脚本退出码：$exitCode" }
    throw ($detail + "`r`n`r`n日志：$LogPath")
  }

  return (($stdout, $stderr) | Where-Object { $_ }) -join "`r`n"
}

function Start-ScriptProcess {
  param(
    [Parameter(Mandatory = $true)][string]$BusyText,
    [Parameter(Mandatory = $true)][string]$DoneText,
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [string[]]$Arguments = @(),
    [string]$ExtraDoneText = '',
    [int]$TimeoutSeconds = 120
  )

  try {
    Set-UiBusy -Busy $true -Body $BusyText
    $output = Invoke-ScriptProcess -ScriptPath $ScriptPath -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
    Set-UiBusy -Busy $false -Body $DoneText
    $body = $DoneText + $ExtraDoneText
    if ($output) { $body += "`r`n`r`n" + $output }
    Show-Message $body
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
  try {
    Set-UiBusy -Busy $true -Body $Text.busyInstall
    $installOutput = Invoke-ScriptProcess -ScriptPath $InstallScript -Arguments (Get-PortArguments) -TimeoutSeconds 90
    Set-UiBusy -Busy $true -Body $Text.busyStart
    $startOutput = Invoke-ScriptProcess -ScriptPath $StartScript -Arguments ((Get-PortArguments) + @('-RestartExisting')) -TimeoutSeconds 120
    Set-UiBusy -Busy $false -Body $Text.doneStart
    $details = (($installOutput, $startOutput) | Where-Object { $_ }) -join "`r`n`r`n"
    $body = "安装 / 修复完成，皮肤版 Codex 已启动。"
    if ($details) { $body += "`r`n`r`n" + $details }
    Show-Message $body
  } catch {
    Write-GuiCrashLog $_
    Set-UiBusy -Busy $false -Body $Text.failedStatus
    Show-Message $_.Exception.Message $Text.failedTitle ([System.Windows.Forms.MessageBoxIcon]::Error)
  }
}

function Start-Skin {
  if (-not (Confirm-Action $Text.startConfirm)) { return $Text.cancelled }
  Start-ScriptProcess -BusyText $Text.busyStart -DoneText $Text.doneStart `
    -ScriptPath $StartScript -Arguments ((Get-PortArguments) + @('-RestartExisting'))
}

function Restart-Start-Skin {
  if (-not (Confirm-Action $Text.restartConfirm)) { return $Text.cancelled }
  Start-ScriptProcess -BusyText $Text.busyRestart -DoneText $Text.doneRestart `
    -ScriptPath $StartScript -Arguments ((Get-PortArguments) + @('-RestartExisting'))
}

function Verify-Skin {
  New-Item -ItemType Directory -Force -Path $OutputsRoot | Out-Null
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $screenshot = Join-Path $OutputsRoot "verify-$stamp.png"
  Start-ScriptProcess -BusyText $Text.busyVerify -DoneText $Text.doneVerify `
    -ScriptPath $VerifyScript -Arguments ((Get-PortArguments) + @('-ScreenshotPath', $screenshot)) `
    -ExtraDoneText ("`r`n`r`n" + $Text.screenshotSaved + $screenshot) -TimeoutSeconds 90
}

function Restart-DreamSkinAfterThemeChange {
  $output = Invoke-ScriptProcess -ScriptPath $StartScript -Arguments ((Get-PortArguments) + @('-RestartExisting')) -TimeoutSeconds 120
  if ($output) { return $output }
  return 'Dream Skin 已重新启动，主题应已生效。'
}

function Select-CustomImage {
  $dialog = New-Object System.Windows.Forms.OpenFileDialog
  $dialog.Title = $Text.chooseImageTitle
  $dialog.Filter = 'Image files (*.png;*.jpg;*.jpeg;*.webp)|*.png;*.jpg;*.jpeg;*.webp'
  $dialog.Multiselect = $false
  if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return $Text.cancelled }
  $paths = Initialize-OneClickThemeStore
  $active = Set-DreamSkinActiveTheme -ImagePath $dialog.FileName -Theme $null -Name 'Custom image' -StateRoot $paths.Root
  $restart = Restart-DreamSkinAfterThemeChange
  return "主题已应用：$($active.Theme.name)`r`n`r`n$restart"
}

function Restore-DefaultImage {
  $result = Set-DefaultDreamTheme
  $restart = Restart-DreamSkinAfterThemeChange
  return "$result`r`n`r`n$restart"
}

function Restore-Official {
  Start-ScriptProcess -BusyText $Text.busyRestore -DoneText $Text.doneRestore `
    -ScriptPath $RestoreScript -Arguments ((Get-PortArguments) + @('-RestoreBaseTheme', '-PromptRestart'))
}

function Uninstall-Skin {
  if (-not (Confirm-Action $Text.uninstallConfirm)) { return $Text.cancelled }
  Start-ScriptProcess -BusyText $Text.busyUninstall -DoneText $Text.doneUninstall `
    -ScriptPath $RestoreScript -Arguments ((Get-PortArguments) + @('-Uninstall', '-RestoreBaseTheme', '-PromptRestart'))
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
  @{ Text = (Get-TextValue -Name 'buttonMakeTheme' -Default '一键制作主题'); Action = { Invoke-GuiAction '正在制作主题...' '主题制作完成。' { New-OneClickTheme } } },
  @{ Text = (Get-TextValue -Name 'buttonTheme' -Default '主题库 / 导入主题'); Action = { Invoke-GuiAction 'Applying theme...' 'Theme applied.' { Select-ThemePackage } } },
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


