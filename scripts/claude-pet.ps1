param(
  [string]$Workspace = (Split-Path -Parent $PSScriptRoot),
  [string]$ClaudeHome = (Join-Path $HOME '.claude'),
  [string]$PetRoot = (Join-Path $HOME '.codex\pets'),
  [string]$PetId = 'codex-chan',
  [ValidateRange(0.25, 1.5)]
  [double]$Scale = 0.48,
  [ValidateRange(0.5, 8.0)]
  [double]$SpeedScale = 2.8,
  [switch]$ReducedMotion,
  [switch]$CloseExisting
)

$ErrorActionPreference = 'Stop'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:LogPath = Join-Path $Workspace 'claude-pet.log'

function Add-PetLog([string]$Message) {
  try {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    [System.IO.File]::AppendAllText($script:LogPath, $line + [Environment]::NewLine, $script:Utf8NoBom)
  } catch {
  }
}

function S([int[]]$Codes) {
  return -join ($Codes | ForEach-Object { [char]$_ })
}

function Stop-ExistingPetProcesses {
  $scriptName = 'claude-pet.ps1'
  $exclude = @{}
  $current = Get-CimInstance Win32_Process -Filter "ProcessId = $PID" -ErrorAction SilentlyContinue
  while ($current) {
    $exclude[[int]$current.ProcessId] = $true
    if (-not $current.ParentProcessId) { break }
    $current = Get-CimInstance Win32_Process -Filter "ProcessId = $($current.ParentProcessId)" -ErrorAction SilentlyContinue
  }
  Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      -not $exclude.ContainsKey([int]$_.ProcessId) -and
      $_.CommandLine -and
      $_.CommandLine.IndexOf($scriptName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    } |
    ForEach-Object {
      try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {}
    }
}

if ($CloseExisting) {
  Add-PetLog 'close requested'
  Stop-ExistingPetProcesses
  return
}

Stop-ExistingPetProcesses
Add-PetLog "starting pet scale=$Scale speedScale=$SpeedScale reducedMotion=$([bool]$ReducedMotion)"

function Read-JsonLineTail([string]$Path, [int]$Count) {
  try {
    $lines = [System.IO.File]::ReadAllLines($Path, $script:Utf8NoBom)
    $start = [Math]::Max(0, $lines.Length - $Count)
    return $lines[$start..($lines.Length - 1)]
  } catch {
    return @()
  }
}

function Get-LatestClaudeTranscript {
  if (-not (Test-Path -LiteralPath $ClaudeHome)) { return $null }
  $projects = Join-Path $ClaudeHome 'projects'
  if (-not (Test-Path -LiteralPath $projects)) { return $null }
  return Get-ChildItem -LiteralPath $projects -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
}

function Get-ShortText([object]$Value) {
  if ($null -eq $Value) { return $null }
  if ($Value -is [string]) { return $Value }
  if ($Value -is [System.Array]) {
    $parts = @()
    foreach ($item in $Value) {
      if ($item -is [string]) {
        $parts += $item
      } elseif ($item.text) {
        $parts += [string]$item.text
      } elseif ($item.content -and ($item.type -eq 'tool_result')) {
        $parts += [string]$item.content
      }
    }
    return ($parts -join ' ')
  }
  if ($Value.text) { return [string]$Value.text }
  return ($Value | ConvertTo-Json -Compress -Depth 4)
}

function Get-ClaudeSnapshot {
  $latest = Get-LatestClaudeTranscript
  if (-not $latest) {
    return @{
      State = 'idle'
      Text = (S @(27426,31561,20027,20154,21551,21160,32,67,108,97,117,100,101,32,67,111,100,101))
      Detail = ''
    }
  }

  $age = [DateTime]::Now - $latest.LastWriteTime
  $state = 'idle'
  if ($age.TotalSeconds -lt 8) { $state = 'review' }
  elseif ($age.TotalSeconds -lt 45) { $state = 'idle' }

  $lastUser = $null
  $lastAssistant = $null
  $lastTool = $null
  foreach ($line in (Read-JsonLineTail $latest.FullName 80)) {
    if (-not $line) { continue }
    try {
      $obj = $line | ConvertFrom-Json
      if ($obj.type -eq 'user') {
        $text = Get-ShortText $obj.message.content
        if ($text) { $lastUser = $text }
        if ($obj.toolUseResult) { $lastTool = Get-ShortText $obj.toolUseResult.stdout }
      } elseif ($obj.type -eq 'assistant') {
        $content = $obj.message.content
        $text = Get-ShortText $content
        if ($text) { $lastAssistant = $text }
        if ($obj.message.stop_reason -eq 'tool_use') { $state = 'review' }
      }
    } catch {
    }
  }

  $text = $lastAssistant
  if (-not $text) { $text = $lastTool }
  if (-not $text) { $text = $lastUser }
  if (-not $text) { $text = (S @(27491,22312,30475,32,67,108,97,117,100,101,32,67,111,100,101,32,30340,36827,31243)) }
  $text = ($text -replace '\s+', ' ').Trim()
  if ($text.Length -gt 88) { $text = $text.Substring(0, 85) + '...' }

  $prefix = if ($state -eq 'review') { S @(20219,21153,26356,26032) } else { S @(24453,26426,20013) }
  return @{
    State = $state
    Text = $text
    Detail = "$prefix - $($latest.LastWriteTime.ToString('HH:mm:ss'))"
  }
}

function Ensure-SpritesheetPng {
  $petDir = Join-Path $PetRoot $PetId
  $webp = Join-Path $petDir 'spritesheet.webp'
  $cacheDir = Join-Path $Workspace "assets\pets\$PetId"
  $png = Join-Path $cacheDir 'spritesheet.png'
  $cleanPng = Join-Path $cacheDir 'spritesheet.cleaned.png'
  New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null

  if (-not (Test-Path -LiteralPath $webp)) {
    throw "Missing pet spritesheet: $webp"
  }

  $needsConvert = -not (Test-Path -LiteralPath $png)
  if (-not $needsConvert) {
    $needsConvert = (Get-Item -LiteralPath $webp).LastWriteTime -gt (Get-Item -LiteralPath $png).LastWriteTime
  }
  if ($needsConvert) {
    $ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if (-not $ffmpeg) { throw "ffmpeg is required to convert Codex WebP pet spritesheets." }
    & $ffmpeg.Source -y -hide_banner -loglevel error -i $webp $png
    if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed to convert pet spritesheet." }
  }
  $needsClean = -not (Test-Path -LiteralPath $cleanPng)
  if (-not $needsClean) {
    $needsClean = (Get-Item -LiteralPath $png).LastWriteTime -gt (Get-Item -LiteralPath $cleanPng).LastWriteTime
  }
  if ($needsClean) {
    Add-Type -AssemblyName System.Drawing
    $bmp = [System.Drawing.Bitmap]::FromFile($png)
    try {
      for ($y = 0; $y -lt $bmp.Height; $y++) {
        for ($x = 0; $x -lt $bmp.Width; $x++) {
          $c = $bmp.GetPixel($x, $y)
          $isChromaPurple = ($c.R -ge 150 -and $c.B -ge 150 -and $c.G -le 95 -and [Math]::Abs($c.R - $c.B) -le 80)
          $isNearTransparent = ($c.A -le 12)
          if ($isChromaPurple -or $isNearTransparent) {
            $bmp.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(0, $c.R, $c.G, $c.B))
          }
        }
      }
      $bmp.Save($cleanPng, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
      $bmp.Dispose()
    }
  }
  return $cleanPng
}

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$sheetPath = Ensure-SpritesheetPng
Add-PetLog "spritesheet=$sheetPath"
$cellW = 192
$cellH = 208
$states = @{
  idle = @{ Row = 0; Count = 6; Dur = @(520, 260, 260, 320, 320, 760) }
  'running-right' = @{ Row = 1; Count = 8; Dur = @(260, 260, 260, 260, 260, 260, 260, 420) }
  'running-left' = @{ Row = 2; Count = 8; Dur = @(260, 260, 260, 260, 260, 260, 260, 420) }
  waving = @{ Row = 3; Count = 4; Dur = @(320, 320, 320, 620) }
  jumping = @{ Row = 4; Count = 5; Dur = @(320, 320, 320, 320, 620) }
  failed = @{ Row = 5; Count = 8; Dur = @(320, 320, 320, 320, 320, 320, 320, 620) }
  waiting = @{ Row = 0; Count = 6; Dur = @(520, 260, 260, 320, 320, 760) }
  running = @{ Row = 7; Count = 6; Dur = @(260, 260, 260, 260, 260, 420) }
  review = @{ Row = 8; Count = 6; Dur = @(420, 420, 420, 420, 420, 780) }
}

function Get-TargetWorkingArea {
  try {
    return [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
  } catch {
    return [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  }
}

$script:state = 'idle'
$script:frame = 0
$script:lastTranscript = $null
$script:isPaused = [bool]$ReducedMotion
$script:scaleValue = $Scale

$sheet = New-Object System.Windows.Media.Imaging.BitmapImage
$sheet.BeginInit()
$sheet.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
$sheet.UriSource = [Uri]$sheetPath
$sheet.EndInit()
$sheet.Freeze()

$window = New-Object System.Windows.Window
$window.Title = 'Claude Code Pet'
$window.WindowStyle = 'None'
$window.AllowsTransparency = $true
$window.Background = [System.Windows.Media.Brushes]::Transparent
$window.Topmost = $true
$window.ShowInTaskbar = $false
$window.SizeToContent = 'Manual'
$window.Width = [double](192 * $script:scaleValue + 330)
$window.Height = [double]([Math]::Max(208 * $script:scaleValue + 28, 140))
$window.ResizeMode = 'NoResize'

$root = New-Object System.Windows.Controls.Grid
$root.Background = [System.Windows.Media.Brushes]::Transparent
$col1 = New-Object System.Windows.Controls.ColumnDefinition
$col1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
$col2 = New-Object System.Windows.Controls.ColumnDefinition
$col2.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
$root.ColumnDefinitions.Add($col1)
$root.ColumnDefinitions.Add($col2)
$window.Content = $root

$petImage = New-Object System.Windows.Controls.Image
$petImage.Stretch = 'Fill'
$petImage.SnapsToDevicePixels = $true
[System.Windows.Media.RenderOptions]::SetBitmapScalingMode($petImage, [System.Windows.Media.BitmapScalingMode]::NearestNeighbor)
[System.Windows.Controls.Grid]::SetColumn($petImage, 0)
$root.Children.Add($petImage) | Out-Null

$bubble = New-Object System.Windows.Controls.Border
$bubble.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(38, 34, 31))
$bubble.Padding = New-Object System.Windows.Thickness(14, 10, 14, 10)
$bubble.Margin = New-Object System.Windows.Thickness(8, 26, 0, 0)
$bubble.MinWidth = 245
$bubble.MaxWidth = 310
$bubble.VerticalAlignment = 'Top'
[System.Windows.Controls.Grid]::SetColumn($bubble, 1)
$root.Children.Add($bubble) | Out-Null

$stack = New-Object System.Windows.Controls.StackPanel
$bubble.Child = $stack

$title = New-Object System.Windows.Controls.TextBlock
$title.Text = 'Codex-chan for Claude'
$title.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(246, 232, 214))
$title.FontFamily = 'Microsoft YaHei UI'
$title.FontSize = 14
$title.FontWeight = 'Bold'
$stack.Children.Add($title) | Out-Null

$message = New-Object System.Windows.Controls.TextBlock
$message.Text = S @(25105,20250,25552,37266,20027,20154,20219,21153,36827,24230)
$message.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(246, 232, 214))
$message.FontFamily = 'Microsoft YaHei UI'
$message.FontSize = 13
$message.TextWrapping = 'Wrap'
$message.Margin = New-Object System.Windows.Thickness(0, 6, 0, 0)
$stack.Children.Add($message) | Out-Null

$detail = New-Object System.Windows.Controls.TextBlock
$detail.Text = ''
$detail.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(214, 139, 82))
$detail.FontFamily = 'Microsoft YaHei UI'
$detail.FontSize = 12
$detail.Margin = New-Object System.Windows.Thickness(0, 13, 0, 0)
$stack.Children.Add($detail) | Out-Null

$menu = New-Object System.Windows.Controls.ContextMenu
$openItem = New-Object System.Windows.Controls.MenuItem
$openItem.Header = S @(25171,24320,26368,26032,20250,35805)
$pauseItem = New-Object System.Windows.Controls.MenuItem
$pauseItem.Header = S @(26242,20572,21160,30011)
$smallerItem = New-Object System.Windows.Controls.MenuItem
$smallerItem.Header = S @(21464,23567,19968,28857)
$biggerItem = New-Object System.Windows.Controls.MenuItem
$biggerItem.Header = S @(21464,22823,19968,28857)
$waveItem = New-Object System.Windows.Controls.MenuItem
$waveItem.Header = S @(25171,25307,21628,21628)
$jumpItem = New-Object System.Windows.Controls.MenuItem
$jumpItem.Header = S @(36339,19968,19979)
$exitItem = New-Object System.Windows.Controls.MenuItem
$exitItem.Header = S @(20851,38381,26700,23456)
foreach ($item in @($openItem, $pauseItem, $smallerItem, $biggerItem, $waveItem, $jumpItem, $exitItem)) {
  $menu.Items.Add($item) | Out-Null
}
$root.ContextMenu = $menu

$openItem.Add_Click({
  $latest = Get-LatestClaudeTranscript
  if ($latest) { Start-Process notepad.exe -ArgumentList "`"$($latest.FullName)`"" }
})
$pauseItem.Add_Click({
  $script:isPaused = -not $script:isPaused
  $pauseItem.Header = if ($script:isPaused) { S @(24674,22797,21160,30011) } else { S @(26242,20572,21160,30011) }
})
$smallerItem.Add_Click({
  $script:scaleValue = [Math]::Max(0.25, $script:scaleValue - 0.08)
  Update-Size
})
$biggerItem.Add_Click({
  $script:scaleValue = [Math]::Min(1.5, $script:scaleValue + 0.08)
  Update-Size
})
$waveItem.Add_Click({ $script:isPaused = $false; $script:state = 'waving'; $script:frame = 0 })
$jumpItem.Add_Click({ $script:isPaused = $false; $script:state = 'jumping'; $script:frame = 0 })
$exitItem.Add_Click({ $window.Close() })

$root.Add_MouseLeftButtonDown({
  try { $window.DragMove() } catch {}
})
$root.Add_MouseWheel({
  param($sender, $e)
  if ($e.Delta -gt 0) {
    $script:scaleValue = [Math]::Min(1.5, $script:scaleValue + 0.05)
  } else {
    $script:scaleValue = [Math]::Max(0.25, $script:scaleValue - 0.05)
  }
  Update-Size
})

function Update-Size {
  $petImage.Width = [double]($cellW * $script:scaleValue)
  $petImage.Height = [double]($cellH * $script:scaleValue)
  $window.Width = [double]($petImage.Width + 330)
  $window.Height = [double]([Math]::Max($petImage.Height + 28, 142))
  $window.Dispatcher.BeginInvoke([Action]{
    $screen = Get-TargetWorkingArea
    if ($script:needsInitialPosition) {
      $window.Left = $screen.Left + 48
      $window.Top = $screen.Top + 96
      $script:needsInitialPosition = $false
      Add-PetLog "positioned left=$($window.Left) top=$($window.Top) width=$($window.ActualWidth) height=$($window.ActualHeight)"
    }
  }, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle) | Out-Null
}

function Set-FrameImage {
  $info = $states[$script:state]
  if (-not $info) { $script:state = 'idle'; $info = $states[$script:state] }
  if ($script:frame -ge $info.Count) { $script:frame = 0 }
  $rect = New-Object System.Windows.Int32Rect(($script:frame * $cellW), ($info.Row * $cellH), $cellW, $cellH)
  $crop = New-Object System.Windows.Media.Imaging.CroppedBitmap($sheet, $rect)
  $crop.Freeze()
  $petImage.Source = $crop
}

$animTimer = New-Object System.Windows.Threading.DispatcherTimer
$animTimer.Interval = [TimeSpan]::FromMilliseconds(180)
$animTimer.Add_Tick({
  if ($script:isPaused) {
    $script:frame = 0
    Set-FrameImage
    $animTimer.Interval = [TimeSpan]::FromMilliseconds(1200)
    return
  }
  Set-FrameImage
  $info = $states[$script:state]
  $dur = $info.Dur[$script:frame]
  $script:frame++
  if ($script:frame -ge $info.Count) {
    if ($script:state -eq 'waving' -or $script:state -eq 'jumping' -or $script:state -eq 'failed') {
      $script:state = 'idle'
    }
    $script:frame = 0
  }
  $animTimer.Interval = [TimeSpan]::FromMilliseconds([int]([double]$dur * $SpeedScale))
})

$watchTimer = New-Object System.Windows.Threading.DispatcherTimer
$watchTimer.Interval = [TimeSpan]::FromMilliseconds(2500)
$watchTimer.Add_Tick({
  $snap = Get-ClaudeSnapshot
  if ($snap.State -and $script:state -ne 'waving' -and $script:state -ne 'jumping') {
    $script:state = $snap.State
  }
  $message.Text = $snap.Text
  $detail.Text = $snap.Detail
})

$watchTimer.Start()
$animTimer.Start()
$snap = Get-ClaudeSnapshot
$message.Text = $snap.Text
$detail.Text = $snap.Detail
Update-Size
Set-FrameImage
$script:needsInitialPosition = $true
$window.Dispatcher.BeginInvoke([Action]{
  $screen = Get-TargetWorkingArea
  $window.Left = $screen.Left + 48
  $window.Top = $screen.Top + 96
  $window.Activate() | Out-Null
  Add-PetLog "initial position left=$($window.Left) top=$($window.Top) width=$($window.ActualWidth) height=$($window.ActualHeight)"
}, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle) | Out-Null
Add-PetLog 'show dialog'
try {
  [void]$window.ShowDialog()
  Add-PetLog 'dialog closed'
} catch {
  Add-PetLog "fatal: $($_.Exception.ToString())"
  throw
}
