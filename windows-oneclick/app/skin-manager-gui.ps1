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
  $message = "Theme applied: $($active.Theme.name). If Codex is running, it will update shortly; otherwise start Dream Skin."
  $petSource = Get-DreamSkinPetSourceFromPackage -PackageDir $ThemeDir
  if ($petSource) {
    $petResult = Import-DreamSkinPetPackage -PetDir $petSource
    $message += "`r`n`r`n$petResult"
  }
  return $message
}

function ConvertTo-SafeThemeId {
  param([Parameter(Mandatory = $true)][string]$Name)
  $lower = $Name.ToLowerInvariant()
  $safe = [regex]::Replace($lower, '[^a-z0-9]+', '-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'custom-theme' }
  return $safe
}

function Get-DreamSkinPetSourceFromPackage {
  param([Parameter(Mandatory = $true)][string]$PackageDir)

  $candidates = @(
    $PackageDir,
    (Join-Path $PackageDir 'pet')
  )
  $petsDir = Join-Path $PackageDir 'pets'
  if (Test-Path -LiteralPath $petsDir -PathType Container) {
    $candidates += @(Get-ChildItem -LiteralPath $petsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
  }

  foreach ($candidate in $candidates) {
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }
    if (Test-Path -LiteralPath (Join-Path $candidate 'pet.json') -PathType Leaf) { return $candidate }
  }
  return $null
}

function Get-DreamSkinPetStoreRoot {
  $profile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
  if ([string]::IsNullOrWhiteSpace($profile)) { $profile = $env:USERPROFILE }
  if ([string]::IsNullOrWhiteSpace($profile)) { throw 'Cannot find the current user profile folder.' }
  return (Join-Path $profile '.codex\pets')
}

function Assert-DreamSkinRelativePetPath {
  param(
    [Parameter(Mandatory = $true)][string]$Value,
    [Parameter(Mandatory = $true)][string]$Field
  )

  if ([string]::IsNullOrWhiteSpace($Value)) { throw "Pet $Field is empty." }
  if ([System.IO.Path]::IsPathRooted($Value)) { throw "Pet $Field must be a relative file name." }
  $parts = $Value -split '[\\/]'
  if ($parts | Where-Object { $_ -eq '..' -or [string]::IsNullOrWhiteSpace($_) }) {
    throw "Pet $Field cannot contain parent directory references."
  }
}

function Get-DreamSkinImageDimensions {
  param([Parameter(Mandatory = $true)][string]$Path)

  $bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -ge 24 -and
    $bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 -and $bytes[2] -eq 0x4e -and $bytes[3] -eq 0x47 -and
    [System.Text.Encoding]::ASCII.GetString($bytes, 12, 4) -eq 'IHDR') {
    $width = ([int]$bytes[16] * 16777216) + ([int]$bytes[17] * 65536) + ([int]$bytes[18] * 256) + [int]$bytes[19]
    $height = ([int]$bytes[20] * 16777216) + ([int]$bytes[21] * 65536) + ([int]$bytes[22] * 256) + [int]$bytes[23]
    return [pscustomobject]@{ Width = $width; Height = $height }
  }

  if ($bytes.Length -ge 30 -and
    [System.Text.Encoding]::ASCII.GetString($bytes, 0, 4) -eq 'RIFF' -and
    [System.Text.Encoding]::ASCII.GetString($bytes, 8, 4) -eq 'WEBP') {
    $offset = 12
    while ($offset + 8 -le $bytes.Length) {
      $chunk = [System.Text.Encoding]::ASCII.GetString($bytes, $offset, 4)
      $size = [BitConverter]::ToUInt32($bytes, $offset + 4)
      $data = $offset + 8
      if ($data + $size -gt $bytes.Length) { break }
      if ($chunk -eq 'VP8X' -and $size -ge 10) {
        $width = 1 + $bytes[$data + 4] + ($bytes[$data + 5] -shl 8) + ($bytes[$data + 6] -shl 16)
        $height = 1 + $bytes[$data + 7] + ($bytes[$data + 8] -shl 8) + ($bytes[$data + 9] -shl 16)
        return [pscustomobject]@{ Width = $width; Height = $height }
      }
      if ($chunk -eq 'VP8 ' -and $size -ge 10 -and
        $bytes[$data + 3] -eq 0x9d -and $bytes[$data + 4] -eq 0x01 -and $bytes[$data + 5] -eq 0x2a) {
        $width = [BitConverter]::ToUInt16($bytes, $data + 6) -band 0x3fff
        $height = [BitConverter]::ToUInt16($bytes, $data + 8) -band 0x3fff
        return [pscustomobject]@{ Width = $width; Height = $height }
      }
      if ($chunk -eq 'VP8L' -and $size -ge 5 -and $bytes[$data] -eq 0x2f) {
        $b1 = $bytes[$data + 1]
        $b2 = $bytes[$data + 2]
        $b3 = $bytes[$data + 3]
        $b4 = $bytes[$data + 4]
        $width = 1 + (($b2 -band 0x3f) -shl 8) + $b1
        $height = 1 + (($b4 -band 0x0f) -shl 10) + ($b3 -shl 2) + (($b2 -band 0xc0) -shr 6)
        return [pscustomobject]@{ Width = $width; Height = $height }
      }
      $offset += 8 + $size + ($size % 2)
    }
  }

  throw '无法读取桌宠 sprite sheet 尺寸，请使用透明 PNG 或 WebP。'
}

function Get-DreamSkinPetPackageInfo {
  param([Parameter(Mandatory = $true)][string]$PetDir)

  if (-not (Test-Path -LiteralPath $PetDir -PathType Container)) { throw "Pet folder not found: $PetDir" }
  $petJsonPath = Join-Path $PetDir 'pet.json'
  if (-not (Test-Path -LiteralPath $petJsonPath -PathType Leaf)) { throw "Pet package must contain pet.json: $PetDir" }

  $pet = (Read-DreamSkinUtf8File -Path $petJsonPath) | ConvertFrom-Json -ErrorAction Stop
  $rawId = if ($pet.id) { [string]$pet.id } elseif ($pet.displayName) { [string]$pet.displayName } else { Split-Path -Leaf $PetDir }
  $petId = ConvertTo-SafeThemeId -Name $rawId
  $displayName = if ($pet.displayName) { [string]$pet.displayName } else { $petId }
  $description = if ($pet.description) { [string]$pet.description } else { 'Imported by Codex Dream Skin.' }
  $spriteRel = if ($pet.spritesheetPath) { [string]$pet.spritesheetPath } else { 'spritesheet.webp' }
  Assert-DreamSkinRelativePetPath -Value $spriteRel -Field 'spritesheetPath'

  $spriteSource = Join-Path $PetDir $spriteRel
  if (-not (Test-Path -LiteralPath $spriteSource -PathType Leaf)) { throw "Pet spritesheet not found: $spriteSource" }
  $extension = [System.IO.Path]::GetExtension($spriteSource).ToLowerInvariant()
  if (@('.png', '.webp') -notcontains $extension) { throw 'Pet spritesheet must be a transparent PNG or WebP file.' }
  $spriteItem = Get-Item -LiteralPath $spriteSource
  if ($spriteItem.Length -gt 20MB) { throw 'Pet spritesheet must be 20 MB or smaller.' }
  $dimensions = Get-DreamSkinImageDimensions -Path $spriteSource
  if ($dimensions.Width -ne 1536 -or $dimensions.Height -ne 1872) {
    throw "桌宠 sprite sheet 尺寸必须是 1536 x 1872；当前是 $($dimensions.Width) x $($dimensions.Height)。"
  }

  return [pscustomobject]@{
    SourceDir = $PetDir
    PetJsonPath = $petJsonPath
    Id = $petId
    DisplayName = $displayName
    Description = $description
    SpriteSource = $spriteSource
    SpriteExtension = $extension
    SpriteLength = $spriteItem.Length
    Width = $dimensions.Width
    Height = $dimensions.Height
  }
}

function Import-DreamSkinPetPackage {
  param([Parameter(Mandatory = $true)][string]$PetDir)

  $petInfo = Get-DreamSkinPetPackageInfo -PetDir $PetDir

  $storeRoot = Get-DreamSkinPetStoreRoot
  $targetDir = Join-Path $storeRoot $petInfo.Id
  if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $targetDir -Force
  }

  $spriteName = 'spritesheet' + $petInfo.SpriteExtension
  Copy-Item -LiteralPath $petInfo.SpriteSource -Destination (Join-Path $targetDir $spriteName) -Force

  $normalized = [ordered]@{
    id = $petInfo.Id
    displayName = $petInfo.DisplayName
    description = $petInfo.Description
    spritesheetPath = $spriteName
  }
  $petJson = ($normalized | ConvertTo-Json -Depth 6) + [Environment]::NewLine
  $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
  [System.IO.File]::WriteAllText((Join-Path $targetDir 'pet.json'), $petJson, $utf8NoBom)

  try { Start-Process 'codex://settings' | Out-Null } catch {}
  return "桌宠已导入：$($petInfo.DisplayName)`r`n位置：$targetDir`r`n请在 Codex 设置 > Pets 里点击 Refresh，然后选择这个桌宠；需要显示/隐藏时输入 /pet。"
}

function Open-DreamSkinPetsSettings {
  try {
    Start-Process 'codex://settings' | Out-Null
    return '已打开 Codex 设置。请进入 Pets，选择 Create your own pet 或 Refresh。'
  } catch {
    return '请手动打开 Codex 设置 > Pets。'
  }
}

function New-DreamSkinPetPrompt {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Description
  )

  return @"
请使用 `$hatch-pet 为 Codex/ChatGPT 桌面端制作一个自定义桌宠。

桌宠名字：$Name
角色/风格描述：$Description

要求：
- 做成 Codex-compatible animated pet。
- 保持角色身份一致、轮廓清楚、适合小尺寸显示。
- 包含 9 个状态：idle、running-right、running-left、waving、jumping、failed、waiting、running、review。
- 最终输出 pet.json 和 spritesheet.webp。
- spritesheet 必须是透明 WebP 或 PNG，尺寸 1536 x 1872，大小 20 MB 以内。
- 完成后请告诉我最终桌宠文件夹路径，并给出预览和验证结果。
"@
}

function Install-DreamSkinPetFromUrl {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$ImageUrl
  )

  $uri = $null
  if (-not [System.Uri]::TryCreate($ImageUrl, [System.UriKind]::Absolute, [ref]$uri) -or
    $uri.Scheme -cne 'https') {
    throw '在线安装需要一个 HTTPS 图片或 sprite sheet 链接。'
  }
  if ([string]::IsNullOrWhiteSpace($Name)) { throw '请先填写桌宠名字。' }
  $link = 'codex://pets/install?name={0}&imageUrl={1}' -f
    [System.Uri]::EscapeDataString($Name.Trim()),
    [System.Uri]::EscapeDataString($ImageUrl.Trim())
  Start-Process $link | Out-Null
  return '已打开 Codex 桌宠安装流程。如果没有反应，请确认当前 Codex 版本和账号已支持 Pets。'
}

function Test-DreamSkinPetPackageInteractive {
  $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
  $dialog.Description = '选择包含 pet.json 和 spritesheet.png/webp 的桌宠文件夹'
  try {
    if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return $Text.cancelled }
    $petSource = Get-DreamSkinPetSourceFromPackage -PackageDir $dialog.SelectedPath
    if (-not $petSource) { throw '没有找到 pet.json。请选择桌宠文件夹，或包含 pet 子文件夹的角色套装。' }
    $petInfo = Get-DreamSkinPetPackageInfo -PetDir $petSource
    $sizeMb = [Math]::Round($petInfo.SpriteLength / 1MB, 2)
    return "桌宠体检通过。`r`n`r`n名称：$($petInfo.DisplayName)`r`nID：$($petInfo.Id)`r`n尺寸：$($petInfo.Width) x $($petInfo.Height)`r`n大小：$sizeMb MB`r`n文件：$($petInfo.SpriteSource)"
  } finally {
    $dialog.Dispose()
  }
}

function Show-PetMakerWizard {
  $dialog = New-Object System.Windows.Forms.Form
  $dialog.Text = '桌宠制作向导'
  $dialog.StartPosition = 'CenterParent'
  $dialog.ClientSize = New-Object System.Drawing.Size(560, 482)
  $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
  $dialog.MaximizeBox = $false
  $dialog.MinimizeBox = $false
  $dialog.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

  $title = New-Object System.Windows.Forms.Label
  $title.Text = '小白流程：写名字和描述，复制提示词到 Codex 生成；已有套装可直接导入。'
  $title.Location = New-Object System.Drawing.Point(18, 16)
  $title.Size = New-Object System.Drawing.Size(520, 34)
  $dialog.Controls.Add($title)

  $nameLabel = New-Object System.Windows.Forms.Label
  $nameLabel.Text = '桌宠名字'
  $nameLabel.Location = New-Object System.Drawing.Point(18, 62)
  $nameLabel.Size = New-Object System.Drawing.Size(90, 24)
  $dialog.Controls.Add($nameLabel)

  $nameBox = New-Object System.Windows.Forms.TextBox
  $nameBox.Text = '我的桌宠'
  $nameBox.Location = New-Object System.Drawing.Point(112, 60)
  $nameBox.Size = New-Object System.Drawing.Size(410, 24)
  $dialog.Controls.Add($nameBox)

  $descriptionLabel = New-Object System.Windows.Forms.Label
  $descriptionLabel.Text = '角色描述'
  $descriptionLabel.Location = New-Object System.Drawing.Point(18, 98)
  $descriptionLabel.Size = New-Object System.Drawing.Size(90, 24)
  $dialog.Controls.Add($descriptionLabel)

  $descriptionBox = New-Object System.Windows.Forms.TextBox
  $descriptionBox.Multiline = $true
  $descriptionBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
  $descriptionBox.Text = '一个适合 Codex 的可爱桌宠，风格干净，动作清楚，状态反馈明显。'
  $descriptionBox.Location = New-Object System.Drawing.Point(112, 96)
  $descriptionBox.Size = New-Object System.Drawing.Size(410, 96)
  $dialog.Controls.Add($descriptionBox)

  $urlLabel = New-Object System.Windows.Forms.Label
  $urlLabel.Text = 'HTTPS 链接'
  $urlLabel.Location = New-Object System.Drawing.Point(18, 210)
  $urlLabel.Size = New-Object System.Drawing.Size(90, 24)
  $dialog.Controls.Add($urlLabel)

  $urlBox = New-Object System.Windows.Forms.TextBox
  $urlBox.Location = New-Object System.Drawing.Point(112, 208)
  $urlBox.Size = New-Object System.Drawing.Size(410, 24)
  $dialog.Controls.Add($urlBox)

  $hint = New-Object System.Windows.Forms.Label
  $hint.Text = '如果已经有在线 sprite sheet 链接，可以直接安装；本地文件/整套文件夹用下面的导入按钮。'
  $hint.Location = New-Object System.Drawing.Point(112, 238)
  $hint.Size = New-Object System.Drawing.Size(410, 34)
  $dialog.Controls.Add($hint)

  $copyPrompt = New-Object System.Windows.Forms.Button
  $copyPrompt.Text = '复制 AI 制作提示词'
  $copyPrompt.Location = New-Object System.Drawing.Point(22, 292)
  $copyPrompt.Size = New-Object System.Drawing.Size(160, 36)
  $dialog.Controls.Add($copyPrompt)

  $openPets = New-Object System.Windows.Forms.Button
  $openPets.Text = '打开 Pets 设置'
  $openPets.Location = New-Object System.Drawing.Point(196, 292)
  $openPets.Size = New-Object System.Drawing.Size(150, 36)
  $dialog.Controls.Add($openPets)

  $installUrl = New-Object System.Windows.Forms.Button
  $installUrl.Text = '安装在线桌宠'
  $installUrl.Location = New-Object System.Drawing.Point(360, 292)
  $installUrl.Size = New-Object System.Drawing.Size(150, 36)
  $dialog.Controls.Add($installUrl)

  $importSuite = New-Object System.Windows.Forms.Button
  $importSuite.Text = '导入角色套装/本地桌宠'
  $importSuite.Location = New-Object System.Drawing.Point(22, 344)
  $importSuite.Size = New-Object System.Drawing.Size(202, 36)
  $dialog.Controls.Add($importSuite)

  $testPet = New-Object System.Windows.Forms.Button
  $testPet.Text = '桌宠体检'
  $testPet.Location = New-Object System.Drawing.Point(238, 344)
  $testPet.Size = New-Object System.Drawing.Size(128, 36)
  $dialog.Controls.Add($testPet)

  $openFolder = New-Object System.Windows.Forms.Button
  $openFolder.Text = '打开本地桌宠文件夹'
  $openFolder.Location = New-Object System.Drawing.Point(380, 344)
  $openFolder.Size = New-Object System.Drawing.Size(130, 36)
  $dialog.Controls.Add($openFolder)

  $close = New-Object System.Windows.Forms.Button
  $close.Text = '关闭'
  $close.Location = New-Object System.Drawing.Point(424, 400)
  $close.Size = New-Object System.Drawing.Size(86, 36)
  $dialog.Controls.Add($close)

  $script:PetWizardResult = $Text.cancelled
  $copyPrompt.Add_Click({
    try {
      $name = $nameBox.Text.Trim()
      if ([string]::IsNullOrWhiteSpace($name)) { $name = '我的桌宠' }
      $description = $descriptionBox.Text.Trim()
      if ([string]::IsNullOrWhiteSpace($description)) { $description = '一个适合 Codex 的可爱桌宠。' }
      [System.Windows.Forms.Clipboard]::SetText((New-DreamSkinPetPrompt -Name $name -Description $description))
      $script:PetWizardResult = "AI 制作提示词已复制。`r`n请在 Codex 里粘贴发送；如果 Pets 里有 Create your own pet，也可以先打开官方创建流程。"
      $dialog.Close()
    } catch {
      Show-Message $_.Exception.Message $Text.failedTitle ([System.Windows.Forms.MessageBoxIcon]::Error)
    }
  })
  $openPets.Add_Click({
    try {
      $script:PetWizardResult = Open-DreamSkinPetsSettings
      $dialog.Close()
    } catch {
      Show-Message $_.Exception.Message $Text.failedTitle ([System.Windows.Forms.MessageBoxIcon]::Error)
    }
  })
  $installUrl.Add_Click({
    try {
      $script:PetWizardResult = Install-DreamSkinPetFromUrl -Name $nameBox.Text -ImageUrl $urlBox.Text
      $dialog.Close()
    } catch {
      Show-Message $_.Exception.Message $Text.failedTitle ([System.Windows.Forms.MessageBoxIcon]::Error)
    }
  })
  $importSuite.Add_Click({
    try {
      $script:PetWizardResult = Select-PetPackage
      $dialog.Close()
    } catch {
      Show-Message $_.Exception.Message $Text.failedTitle ([System.Windows.Forms.MessageBoxIcon]::Error)
    }
  })
  $testPet.Add_Click({
    try {
      $script:PetWizardResult = Test-DreamSkinPetPackageInteractive
      $dialog.Close()
    } catch {
      Show-Message $_.Exception.Message $Text.failedTitle ([System.Windows.Forms.MessageBoxIcon]::Error)
    }
  })
  $openFolder.Add_Click({
    try {
      $root = Get-DreamSkinPetStoreRoot
      if (-not (Test-Path -LiteralPath $root -PathType Container)) { $null = New-Item -ItemType Directory -Path $root -Force }
      Start-Process -FilePath $root | Out-Null
      $script:PetWizardResult = "已打开本地桌宠文件夹：$root"
      $dialog.Close()
    } catch {
      Show-Message $_.Exception.Message $Text.failedTitle ([System.Windows.Forms.MessageBoxIcon]::Error)
    }
  })
  $close.Add_Click({ $dialog.Close() })

  [void]$dialog.ShowDialog($form)
  $dialog.Dispose()
  return $script:PetWizardResult
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

function Copy-DreamSkinPetToRoleSuite {
  param(
    [Parameter(Mandatory = $true)][string]$PetDir,
    [Parameter(Mandatory = $true)][string]$SuiteDir
  )

  $petInfo = Get-DreamSkinPetPackageInfo -PetDir $PetDir
  $targetDir = Join-Path $SuiteDir 'pet'
  New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
  $spriteName = 'spritesheet' + $petInfo.SpriteExtension
  Copy-Item -LiteralPath $petInfo.SpriteSource -Destination (Join-Path $targetDir $spriteName) -Force

  $normalized = [ordered]@{
    id = $petInfo.Id
    displayName = $petInfo.DisplayName
    description = $petInfo.Description
    spritesheetPath = $spriteName
  }
  $petJson = ($normalized | ConvertTo-Json -Depth 6) + [Environment]::NewLine
  $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
  [System.IO.File]::WriteAllText((Join-Path $targetDir 'pet.json'), $petJson, $utf8NoBom)
  return $petInfo
}

function New-RoleSuitePackage {
  $options = Show-ThemeOptionsDialog
  if (-not $options) { return $Text.cancelled }
  $name = $options.Name

  $imageDialog = New-Object System.Windows.Forms.OpenFileDialog
  $imageDialog.Title = '选择角色套装背景图'
  $imageDialog.Filter = 'Image files (*.png;*.jpg;*.jpeg;*.webp)|*.png;*.jpg;*.jpeg;*.webp'
  $imageDialog.Multiselect = $false
  try {
    if ($imageDialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return $Text.cancelled }
    if (-not (Show-ThemeImagePreview -ImagePath $imageDialog.FileName -ThemeName $name)) { return $Text.cancelled }
    Assert-DreamSkinImageFile -Path $imageDialog.FileName

    $fontSourcePath = $null
    if ($options.FontFileRequested) {
      $fontDialog = New-Object System.Windows.Forms.OpenFileDialog
      $fontDialog.Title = '选择角色套装字体文件'
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

    $petSourcePath = $null
    $petChoice = [System.Windows.Forms.MessageBox]::Show(
      '这个角色套装要包含桌宠吗？',
      '角色套装打包器',
      [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
      [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($petChoice -eq [System.Windows.Forms.DialogResult]::Cancel) { return $Text.cancelled }
    if ($petChoice -eq [System.Windows.Forms.DialogResult]::Yes) {
      $petDialog = New-Object System.Windows.Forms.FolderBrowserDialog
      $petDialog.Description = '选择包含 pet.json 和 spritesheet.png/webp 的桌宠文件夹'
      try {
        if ($petDialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return $Text.cancelled }
        $petSourcePath = Get-DreamSkinPetSourceFromPackage -PackageDir $petDialog.SelectedPath
        if (-not $petSourcePath) { throw '没有找到 pet.json。请选择桌宠文件夹，或包含 pet 子文件夹的角色套装。' }
        $null = Get-DreamSkinPetPackageInfo -PetDir $petSourcePath
      } finally {
        $petDialog.Dispose()
      }
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $baseId = ConvertTo-SafeThemeId -Name $name
    $suiteId = "$baseId-$stamp"
    $exportRoot = Join-Path $OutputsRoot 'role-suites'
    $suiteDir = Join-Path $exportRoot $suiteId
    $zipPath = Join-Path $exportRoot "$suiteId.zip"
    if (Test-Path -LiteralPath $suiteDir) { Remove-Item -LiteralPath $suiteDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $suiteDir | Out-Null

    $imageName = 'background.jpg'
    $imagePath = Join-Path $suiteDir $imageName
    Save-ThemeImage -SourcePath $imageDialog.FileName -DestinationPath $imagePath

    $fontFileName = $null
    if ($fontSourcePath) {
      $fontFileName = 'font' + [System.IO.Path]::GetExtension($fontSourcePath).ToLowerInvariant()
      $fontPath = Join-Path $suiteDir $fontFileName
      Copy-Item -LiteralPath $fontSourcePath -Destination $fontPath -Force
      Assert-DreamSkinFontFile -Path $fontPath
    }

    $accent = if ($options.Accent) { $options.Accent } else { Get-ImageAccentHex -ImagePath $imagePath }
    $theme = [ordered]@{
      schemaVersion = 1
      id = $suiteId
      name = $name
      image = $imageName
      appearance = $options.Appearance
      brandSubtitle = 'CODEX DREAM SKIN ROLE SUITE'
      tagline = "$name 角色套装已就绪。"
      statusText = 'ROLE SUITE ONLINE'
      quote = 'CUSTOM CODEX SPACE'
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
    Write-DreamSkinTheme -ThemeDirectory $suiteDir -Theme ([pscustomobject]$theme)

    $petSummary = '未包含桌宠'
    if ($petSourcePath) {
      $petInfo = Copy-DreamSkinPetToRoleSuite -PetDir $petSourcePath -SuiteDir $suiteDir
      $petSummary = "$($petInfo.DisplayName) ($($petInfo.Width) x $($petInfo.Height))"
    }

    $readme = @(
      "Codex Dream Skin 角色套装：$name"
      ''
      '买家使用方法：'
      '1. 打开 Codex Dream Skin GUI。'
      '2. 点击“桌宠制作向导”或“主题库 / 导入主题”。'
      '3. 选择本文件夹；主题会自动应用，pet 子文件夹会自动导入桌宠。'
      '4. 如果包含桌宠，导入后到 Codex 设置 > Pets 点击 Refresh 并选择它。'
      ''
      "主题 ID：$suiteId"
      "强调色：$accent"
      "桌宠：$petSummary"
      ''
      '说明：这是第三方角色套装，不是 OpenAI 官方资源。'
    ) -join [Environment]::NewLine
    $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText((Join-Path $suiteDir 'README.txt'), $readme + [Environment]::NewLine, $utf8NoBom)

    New-Item -ItemType Directory -Force -Path $exportRoot | Out-Null
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Compress-Archive -LiteralPath $suiteDir -DestinationPath $zipPath -Force
    Start-Process explorer.exe $exportRoot
    return "角色套装已生成。`r`n`r`n文件夹：$suiteDir`r`n压缩包：$zipPath`r`n桌宠：$petSummary`r`n`r`n把这个 zip 或文件夹发给买家即可。"
  } finally {
    $imageDialog.Dispose()
  }
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

function Select-PetPackage {
  $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
  $dialog.Description = '选择角色套装文件夹，或选择单独桌宠文件夹'
  $defaultThemes = Join-Path $OutputsRoot 'themes'
  if (Test-Path -LiteralPath $defaultThemes -PathType Container) { $dialog.SelectedPath = $defaultThemes }
  try {
    if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return $Text.cancelled }
    $selected = $dialog.SelectedPath
  } finally {
    $dialog.Dispose()
  }

  if (Test-Path -LiteralPath (Join-Path $selected 'theme.json') -PathType Leaf) {
    $result = Import-ExplicitTheme -ThemeDir $selected
    $restart = Restart-DreamSkinAfterThemeChange
    return "角色套装已导入。`r`n`r`n$result`r`n`r`n$restart"
  }

  $petSource = Get-DreamSkinPetSourceFromPackage -PackageDir $selected
  if (-not $petSource) { throw "没有找到角色套装或桌宠文件。请选择包含 theme.json 的角色套装文件夹，或包含 pet.json 和 spritesheet.png/webp 的桌宠文件夹。" }
  return Import-DreamSkinPetPackage -PetDir $petSource
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

function Read-SharedTextFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  $deadline = (Get-Date).AddSeconds(3)
  $lastError = $null
  do {
    try {
      $stream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
      )
      try {
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
        try { return $reader.ReadToEnd().Trim() } finally { $reader.Dispose() }
      } finally {
        if ($stream) { $stream.Dispose() }
      }
    } catch {
      $lastError = $_
      Start-Sleep -Milliseconds 120
      [System.Windows.Forms.Application]::DoEvents()
    }
  } while ((Get-Date) -lt $deadline)
  throw $lastError
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

  $stdout = Read-SharedTextFile -Path $stdoutPath
  $stderr = Read-SharedTextFile -Path $stderrPath
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

function Copy-DreamSkinDiagnosticFile {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$DestinationDirectory
  )

  if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return $false }
  New-Item -ItemType Directory -Force -Path $DestinationDirectory | Out-Null
  Copy-Item -LiteralPath $Source -Destination (Join-Path $DestinationDirectory ([System.IO.Path]::GetFileName($Source))) -Force
  return $true
}

function Get-DreamSkinDiagnosticSummary {
  $stateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
  $themePaths = Get-DreamSkinThemePaths -StateRoot $stateRoot
  $node = $null
  $nodeError = $null
  try { $node = Get-DreamSkinNodeRuntime } catch { $nodeError = $_.Exception.Message }

  $codexInstalls = @()
  $codexError = $null
  try { $codexInstalls = @(Get-DreamSkinRegisteredCodexInstalls) } catch { $codexError = $_.Exception.Message }

  $officialProcesses = @(Get-OfficialCodexProcesses)
  $activeTheme = $null
  $activeThemeError = $null
  try {
    if (Test-Path -LiteralPath $themePaths.Active -PathType Container) {
      $loaded = Read-DreamSkinTheme -ThemeDirectory $themePaths.Active -SkipImageMetadata
      $activeTheme = [pscustomobject]@{
        id = "$($loaded.Theme.id)"
        name = "$($loaded.Theme.name)"
        image = "$($loaded.Theme.image)"
        appearance = "$($loaded.Theme.appearance)"
        taskMode = "$($loaded.Theme.art.taskMode)"
        taskChrome = "$($loaded.Theme.art.taskChrome)"
        fontFile = "$($loaded.Theme.typography.fontFile)"
      }
    }
  } catch {
    $activeThemeError = $_.Exception.Message
  }

  $savedThemeCount = 0
  $savedThemeError = $null
  try { $savedThemeCount = @(Get-DreamSkinSavedThemes -StateRoot $stateRoot -SkipImageMetadata).Count } catch { $savedThemeError = $_.Exception.Message }

  $petRoot = Get-DreamSkinPetStoreRoot
  $petCount = 0
  if (Test-Path -LiteralPath $petRoot -PathType Container) {
    $petCount = @(Get-ChildItem -LiteralPath $petRoot -Directory -ErrorAction SilentlyContinue).Count
  }

  $cdp = $null
  $cdpError = $null
  try {
    if ($codexInstalls.Count -gt 0) {
      $identity = Get-DreamSkinVerifiedCdpIdentity -Port $Port -Codex $codexInstalls[0]
      $cdp = [pscustomobject]@{
        port = $Port
        available = $null -ne $identity
        browser = if ($identity) { "$($identity.Browser)" } else { $null }
        targetCount = if ($identity) { [int]$identity.TargetCount } else { 0 }
      }
    }
  } catch {
    $cdpError = $_.Exception.Message
  }

  return [pscustomobject]@{
    generatedAt = (Get-Date).ToString('o')
    packageRoot = $PackageRoot
    appRoot = $AppRoot
    windowsRoot = $WindowsRoot
    outputsRoot = $OutputsRoot
    stateRoot = $stateRoot
    port = $Port
    node = if ($node) { [pscustomobject]@{ version = $node.Version; path = $node.Path } } else { $null }
    nodeError = $nodeError
    codexInstalls = @($codexInstalls | ForEach-Object {
      [pscustomobject]@{
        version = "$($_.Version)"
        packageFullName = "$($_.PackageFullName)"
        executable = "$($_.Executable)"
        appUserModelId = "$($_.AppUserModelId)"
      }
    })
    codexError = $codexError
    codexProcessCount = $officialProcesses.Count
    activeTheme = $activeTheme
    activeThemeError = $activeThemeError
    savedThemeCount = $savedThemeCount
    savedThemeError = $savedThemeError
    petRoot = $petRoot
    petCount = $petCount
    cdp = $cdp
    cdpError = $cdpError
    files = [pscustomobject]@{
      installScript = Test-Path -LiteralPath $InstallScript -PathType Leaf
      startScript = Test-Path -LiteralPath $StartScript -PathType Leaf
      restoreScript = Test-Path -LiteralPath $RestoreScript -PathType Leaf
      verifyScript = Test-Path -LiteralPath $VerifyScript -PathType Leaf
      themeScript = Test-Path -LiteralPath $ThemeScript -PathType Leaf
      activeTheme = Test-Path -LiteralPath (Join-Path $themePaths.Active 'theme.json') -PathType Leaf
      state = Test-Path -LiteralPath $themePaths.State -PathType Leaf
      lastActionLog = Test-Path -LiteralPath $LogPath -PathType Leaf
      guiCrashLog = Test-Path -LiteralPath $CrashLogPath -PathType Leaf
    }
  }
}

function New-DreamSkinSupportPackage {
  New-Item -ItemType Directory -Force -Path $OutputsRoot | Out-Null
  $stateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
  New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
  $themePaths = Get-DreamSkinThemePaths -StateRoot $stateRoot

  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $supportRoot = Join-Path $OutputsRoot "support-$stamp"
  $zipPath = Join-Path $OutputsRoot "support-$stamp.zip"
  if (Test-Path -LiteralPath $supportRoot) { Remove-Item -LiteralPath $supportRoot -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $supportRoot | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $supportRoot 'logs') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $supportRoot 'state') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $supportRoot 'theme') | Out-Null

  $summary = Get-DreamSkinDiagnosticSummary
  $summaryJson = $summary | ConvertTo-Json -Depth 8
  [System.IO.File]::WriteAllText((Join-Path $supportRoot 'environment.json'), $summaryJson + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding -ArgumentList $false))

  $report = @(
    '# Codex Dream Skin support package'
    ''
    "Generated: $($summary.generatedAt)"
    "Codex installed: $($summary.codexInstalls.Count -gt 0)"
    "Codex version: $(if ($summary.codexInstalls.Count -gt 0) { $summary.codexInstalls[0].version } else { 'not found' })"
    "Codex running processes: $($summary.codexProcessCount)"
    "Node: $(if ($summary.node) { $summary.node.version } else { 'not found' })"
    "Active theme: $(if ($summary.activeTheme) { $summary.activeTheme.name } else { 'not readable' })"
    "Saved themes: $($summary.savedThemeCount)"
    "Local pets: $($summary.petCount)"
    "CDP on port ${Port}: $(if ($summary.cdp -and $summary.cdp.available) { 'ok' } else { 'not verified' })"
    ''
    'Send this zip to the seller when install, start, theme import, or pet import fails.'
  ) -join [Environment]::NewLine
  [System.IO.File]::WriteAllText((Join-Path $supportRoot 'README.txt'), $report + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding -ArgumentList $false))

  $null = Copy-DreamSkinDiagnosticFile -Source $LogPath -DestinationDirectory (Join-Path $supportRoot 'logs')
  $null = Copy-DreamSkinDiagnosticFile -Source $CrashLogPath -DestinationDirectory (Join-Path $supportRoot 'logs')
  $null = Copy-DreamSkinDiagnosticFile -Source $themePaths.State -DestinationDirectory (Join-Path $supportRoot 'state')
  $null = Copy-DreamSkinDiagnosticFile -Source (Join-Path $themePaths.Active 'theme.json') -DestinationDirectory (Join-Path $supportRoot 'theme')

  $latestScreenshots = @(Get-ChildItem -LiteralPath $OutputsRoot -Filter 'verify-*.png' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 2)
  if ($latestScreenshots.Count -gt 0) {
    $screenshotsDir = Join-Path $supportRoot 'screenshots'
    New-Item -ItemType Directory -Force -Path $screenshotsDir | Out-Null
    foreach ($shot in $latestScreenshots) { Copy-Item -LiteralPath $shot.FullName -Destination $screenshotsDir -Force }
  }

  if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
  Compress-Archive -LiteralPath $supportRoot -DestinationPath $zipPath -Force
  return [pscustomobject]@{ Folder = $supportRoot; Zip = $zipPath; Summary = $summary }
}

function Open-Logs {
  $support = New-DreamSkinSupportPackage
  $stateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
  Start-Process explorer.exe $OutputsRoot
  Start-Process explorer.exe $stateRoot
  return "售后诊断包已生成：$($support.Zip)`r`n`r`n把这个 zip 发给卖家即可排查。"
}

Assert-PackageReady
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = $Text.windowTitle
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(860, 724)
$form.MinimumSize = New-Object System.Drawing.Size(860, 724)
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.BackColor = [System.Drawing.Color]::FromArgb(250, 247, 252)

$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Location = New-Object System.Drawing.Point(0, 0)
$headerPanel.Size = New-Object System.Drawing.Size(860, 108)
$headerPanel.BackColor = [System.Drawing.Color]::FromArgb(66, 39, 90)
$form.Controls.Add($headerPanel)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = $Text.title
$titleLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 24, [System.Drawing.FontStyle]::Bold)
$titleLabel.ForeColor = [System.Drawing.Color]::White
$titleLabel.Location = New-Object System.Drawing.Point(32, 20)
$titleLabel.Size = New-Object System.Drawing.Size(420, 42)
$headerPanel.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = '一键安装、主题制作、角色套装、桌宠向导、更新售后诊断'
$subtitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(238, 224, 246)
$subtitleLabel.Location = New-Object System.Drawing.Point(36, 64)
$subtitleLabel.Size = New-Object System.Drawing.Size(620, 24)
$headerPanel.Controls.Add($subtitleLabel)

$brandPill = New-Object System.Windows.Forms.Label
$brandPill.Text = '非官方第三方美化工具'
$brandPill.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$brandPill.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$brandPill.ForeColor = [System.Drawing.Color]::White
$brandPill.BackColor = [System.Drawing.Color]::FromArgb(128, 82, 154)
$brandPill.Location = New-Object System.Drawing.Point(646, 30)
$brandPill.Size = New-Object System.Drawing.Size(174, 36)
$headerPanel.Controls.Add($brandPill)

$statusPanel = New-Object System.Windows.Forms.Panel
$statusPanel.Location = New-Object System.Drawing.Point(30, 128)
$statusPanel.Size = New-Object System.Drawing.Size(800, 62)
$statusPanel.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 255)
$statusPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$form.Controls.Add($statusPanel)

$statusTitle = New-Object System.Windows.Forms.Label
$statusTitle.Text = '当前状态'
$statusTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$statusTitle.ForeColor = [System.Drawing.Color]::FromArgb(92, 42, 115)
$statusTitle.Location = New-Object System.Drawing.Point(16, 8)
$statusTitle.Size = New-Object System.Drawing.Size(110, 20)
$statusPanel.Controls.Add($statusTitle)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = $Text.readyStatus
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(77, 37, 103)
$statusLabel.Location = New-Object System.Drawing.Point(16, 30)
$statusLabel.Size = New-Object System.Drawing.Size(760, 24)
$statusPanel.Controls.Add($statusLabel)

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.AutoPopDelay = 9000
$toolTip.InitialDelay = 350
$toolTip.ReshowDelay = 120

function New-ActionGroup {
  param(
    [Parameter(Mandatory = $true)][string]$Title,
    [Parameter(Mandatory = $true)][string]$Caption,
    [Parameter(Mandatory = $true)][System.Drawing.Point]$Location
  )
  $panel = New-Object System.Windows.Forms.Panel
  $panel.Location = $Location
  $panel.Size = New-Object System.Drawing.Size(252, 398)
  $panel.BackColor = [System.Drawing.Color]::White
  $panel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $form.Controls.Add($panel)

  $groupTitleLabel = New-Object System.Windows.Forms.Label
  $groupTitleLabel.Text = $Title
  $groupTitleLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
  $groupTitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(76, 42, 102)
  $groupTitleLabel.Location = New-Object System.Drawing.Point(16, 14)
  $groupTitleLabel.Size = New-Object System.Drawing.Size(214, 24)
  $panel.Controls.Add($groupTitleLabel)

  $groupCaptionLabel = New-Object System.Windows.Forms.Label
  $groupCaptionLabel.Text = $Caption
  $groupCaptionLabel.ForeColor = [System.Drawing.Color]::FromArgb(132, 102, 145)
  $groupCaptionLabel.Location = New-Object System.Drawing.Point(16, 42)
  $groupCaptionLabel.Size = New-Object System.Drawing.Size(214, 38)
  $panel.Controls.Add($groupCaptionLabel)

  $layout = New-Object System.Windows.Forms.TableLayoutPanel
  $layout.Location = New-Object System.Drawing.Point(10, 88)
  $layout.Size = New-Object System.Drawing.Size(230, 296)
  $layout.ColumnCount = 1
  $layout.RowCount = 5
  $layout.BackColor = $panel.BackColor
  for ($i = 0; $i -lt 5; $i++) {
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 20)))
  }
  $panel.Controls.Add($layout)
  return $layout
}

$quickGroup = New-ActionGroup -Title '快速开始' -Caption '首次安装、启动、验证效果都放在这里。' `
  -Location (New-Object System.Drawing.Point(30, 216))
$createGroup = New-ActionGroup -Title '个性创作' -Caption '让买家自己做主题、字体和桌宠。' `
  -Location (New-Object System.Drawing.Point(304, 216))
$supportGroup = New-ActionGroup -Title '恢复售后' -Caption '更新后修复、恢复官方外观和诊断。' `
  -Location (New-Object System.Drawing.Point(578, 216))

function New-ActionButton {
  param(
    [Parameter(Mandatory = $true)][string]$Body,
    [Parameter(Mandatory = $true)][scriptblock]$Click,
    [string]$Description = '',
    [string]$Tone = 'default'
  )
  $button = New-Object System.Windows.Forms.Button
  $button.Text = $Body
  $button.Dock = [System.Windows.Forms.DockStyle]::Fill
  $button.Margin = New-Object System.Windows.Forms.Padding(8, 6, 8, 6)
  $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $button.FlatAppearance.BorderSize = 1
  $button.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
  $button.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5, [System.Drawing.FontStyle]::Bold)
  if ($Tone -eq 'primary') {
    $button.BackColor = [System.Drawing.Color]::FromArgb(104, 58, 140)
    $button.ForeColor = [System.Drawing.Color]::White
    $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(104, 58, 140)
    $button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(126, 73, 162)
  } elseif ($Tone -eq 'danger') {
    $button.BackColor = [System.Drawing.Color]::FromArgb(255, 250, 250)
    $button.ForeColor = [System.Drawing.Color]::FromArgb(146, 57, 74)
    $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(232, 174, 184)
    $button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(255, 238, 242)
  } else {
    $button.BackColor = [System.Drawing.Color]::FromArgb(253, 251, 255)
    $button.ForeColor = [System.Drawing.Color]::FromArgb(83, 37, 110)
    $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(216, 196, 228)
    $button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(246, 237, 252)
  }
  if ($Description) { $toolTip.SetToolTip($button, $Description) }
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
  @{ Group = $quickGroup; Text = '安装 / 修复'; Tone = 'primary'; Description = '首次使用、Codex 更新后、皮肤失效后点这里。'; Action = { Install-Skin } },
  @{ Group = $quickGroup; Text = '启动皮肤版 Codex'; Description = '手动打开已经安装好的皮肤版 Codex。'; Action = { Start-Skin } },
  @{ Group = $quickGroup; Text = '重启并启动'; Description = 'Codex 已打开但皮肤没有生效时使用。'; Action = { Restart-Start-Skin } },
  @{ Group = $quickGroup; Text = '验证并截图'; Description = '生成效果截图，方便确认主题是否生效。'; Action = { Verify-Skin } },

  @{ Group = $createGroup; Text = '换自己的图片'; Description = '选择一张本地图片，自动套成全窗口主题。'; Action = { Invoke-GuiAction $Text.busyImage $Text.doneImage { Select-CustomImage } } },
  @{ Group = $createGroup; Text = '一键制作主题'; Tone = 'primary'; Description = '选择图片、配色、字体、遮罩，自动生成可导入主题。'; Action = { Invoke-GuiAction '正在制作主题...' '主题制作完成。' { New-OneClickTheme } } },
  @{ Group = $createGroup; Text = '主题库 / 导入主题'; Description = '选择本地主题库或卖家发来的主题文件夹。'; Action = { Invoke-GuiAction 'Applying theme...' 'Theme applied.' { Select-ThemePackage } } },
  @{ Group = $createGroup; Text = '桌宠制作向导'; Description = '复制 AI 桌宠提示词、打开 Pets、安装在线桌宠或导入本地桌宠。'; Action = { Invoke-GuiAction '正在处理桌宠...' '桌宠操作完成。' { Show-PetMakerWizard } } },
  @{ Group = $createGroup; Text = '角色套装打包器'; Tone = 'primary'; Description = '卖家用：把主题、字体和桌宠打成买家可一键导入的角色套装。'; Action = { Invoke-GuiAction '正在打包角色套装...' '角色套装打包完成。' { New-RoleSuitePackage } } },

  @{ Group = $supportGroup; Text = '恢复默认主题'; Description = '恢复包内默认主题并刷新皮肤。'; Action = { Invoke-GuiAction $Text.busyDefaultImage $Text.doneDefaultImage { Restore-DefaultImage } } },
  @{ Group = $supportGroup; Text = '恢复官方外观'; Description = '撤销皮肤效果，回到 Codex 原始外观。'; Action = { Restore-Official } },
  @{ Group = $supportGroup; Text = '卸载快捷方式'; Tone = 'danger'; Description = '删除 Dream Skin 创建的快捷方式，同时恢复官方外观。'; Action = { Uninstall-Skin } },
  @{ Group = $supportGroup; Text = '日志 / 售后诊断'; Tone = 'primary'; Description = '生成 support zip，Codex 更新或故障时发给卖家排查。'; Action = { Invoke-GuiAction '正在生成售后诊断包...' '售后诊断包已生成。' { Open-Logs } } }
)

for ($index = 0; $index -lt $buttonSpecs.Count; $index++) {
  $button = New-ActionButton -Body $buttonSpecs[$index].Text -Click $buttonSpecs[$index].Action `
    -Description $buttonSpecs[$index].Description -Tone $buttonSpecs[$index].Tone
  $script:ActionButtons += $button
  $buttonSpecs[$index].Group.Controls.Add($button, 0, $buttonSpecs[$index].Group.Controls.Count)
}

$noteLabel = New-Object System.Windows.Forms.Label
$noteLabel.Text = $Text.safetyNote
$noteLabel.ForeColor = [System.Drawing.Color]::FromArgb(120, 85, 125)
$noteLabel.Location = New-Object System.Drawing.Point(34, 634)
$noteLabel.Size = New-Object System.Drawing.Size(792, 34)
$form.Controls.Add($noteLabel)

$fallbackLabel = New-Object System.Windows.Forms.Label
$fallbackLabel.Text = $Text.fallbackNote
$fallbackLabel.ForeColor = [System.Drawing.Color]::FromArgb(150, 110, 150)
$fallbackLabel.Location = New-Object System.Drawing.Point(34, 672)
$fallbackLabel.Size = New-Object System.Drawing.Size(792, 24)
$form.Controls.Add($fallbackLabel)

[void]$form.ShowDialog()
$form.Dispose()
[System.Windows.Forms.Application]::Exit()
exit 0


