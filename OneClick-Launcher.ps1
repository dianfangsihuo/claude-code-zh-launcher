param(
  [string]$InstallDir = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'claude code'),
  [string]$AuthToken,
  [string]$BaseUrl = 'https://api.deepseek.com',
  [ValidateSet('openai', 'anthropic')]
  [string]$Provider = 'openai',
  [string]$Model = 'deepseek-v4-flash',
  [string]$ClaudeStateDir,
  [switch]$NoFreshReinstall,
  [switch]$RequireKeyAndVerify,
  [switch]$NoLaunch,
  [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
try {
  [Console]::OutputEncoding = $script:Utf8NoBom
  $OutputEncoding = $script:Utf8NoBom
} catch {
}

function Normalize-Model([string]$Value) {
  if ($Value -eq 'flash') { return 'deepseek-v4-flash' }
  if ($Value -eq 'pro') { return 'deepseek-v4-pro' }
  return $Value
}

function Write-Step([string]$Message) {
  Write-Host ''
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
  Write-Host "OK  $Message" -ForegroundColor Green
}

function Add-Log([string]$Message) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  [System.IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, $script:Utf8NoBom)
}

function Invoke-Logged([string]$Label, [scriptblock]$Script) {
  Add-Log "START $Label"
  Write-Step $Label
  try {
    & $Script 2>&1 | ForEach-Object {
      $text = $_ | Out-String
      $text = $text.TrimEnd()
      if ($text) {
        Write-Host $text
        Add-Log $text
      }
    }
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
      throw "$Label failed with exit code $LASTEXITCODE"
    }
    Add-Log "OK $Label"
  } catch {
    Add-Log "FAIL ${Label}: $($_.Exception.Message)"
    throw
  }
}

function Test-Command([string]$Name) {
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Copy-NewestFiles([string]$Source, [string]$Target) {
  $sourceFull = [System.IO.Path]::GetFullPath($Source).TrimEnd('\')
  $targetFull = [System.IO.Path]::GetFullPath($Target).TrimEnd('\')
  if ($sourceFull -ieq $targetFull) {
    Write-Ok "Source is install directory; copy skipped"
    Add-Log "Source is install directory; copy skipped"
    return
  }

  New-Item -ItemType Directory -Force -Path $targetFull | Out-Null
  $nestedName = 'claude code'
  $nestedPackage = Join-Path $targetFull $nestedName
  if (((Test-Path -LiteralPath (Join-Path $nestedPackage 'OneClick-Launcher.ps1')) -or (Test-Path -LiteralPath (Join-Path $nestedPackage 'OneClick-DeepSeek.ps1'))) -and ($sourceFull -ne $nestedPackage)) {
    Remove-Item -LiteralPath $nestedPackage -Recurse -Force
    Add-Log "Removed nested package directory $nestedPackage"
  }
  $excludeNames = @('.git', '.claude', '.learnings', 'node_modules', '.env.local', 'dist')
  $excludePatterns = @('*.log', '.env.local.bak-*', '.claude.bak-*', 'DeepSeek-Claude-Diagnose-*.txt')
  $replaceDirs = @('assets', 'docs', 'prompts', 'scripts')

  Get-ChildItem -LiteralPath $sourceFull -Force |
    Where-Object {
      if ($excludeNames -contains $_.Name) { return $false }
      foreach ($pattern in $excludePatterns) {
        if ($_.Name -like $pattern) { return $false }
      }
      return $true
    } |
    ForEach-Object {
      $destination = Join-Path $targetFull $_.Name
      if ($_.PSIsContainer) {
        if ($replaceDirs -contains $_.Name -and (Test-Path -LiteralPath $destination)) {
          Remove-Item -LiteralPath $destination -Recurse -Force
          Add-Log "Replaced package directory $destination"
        }
        Copy-Item -LiteralPath $_.FullName -Destination $targetFull -Recurse -Force
      } else {
        Copy-Item -LiteralPath $_.FullName -Destination $destination -Force
      }
    }
  $commandSource = Join-Path $sourceFull '.claude\commands'
  if (Test-Path -LiteralPath $commandSource) {
    $commandTarget = Join-Path $targetFull '.claude\commands'
    New-Item -ItemType Directory -Force -Path $commandTarget | Out-Null
    Copy-Item -LiteralPath (Join-Path $commandSource '*') -Destination $commandTarget -Recurse -Force
  }
  Write-Ok "Copied newest files to $targetFull"
}

function Initialize-FreshInstallDir([string]$Source, [string]$Target) {
  $sourceFull = [System.IO.Path]::GetFullPath($Source).TrimEnd('\')
  $targetFull = [System.IO.Path]::GetFullPath($Target).TrimEnd('\')
  if ($NoFreshReinstall -or (-not $RequireKeyAndVerify -and -not $AuthToken) -or $sourceFull -ieq $targetFull) {
    Add-Log "Fresh reinstall skipped"
    return
  }
  if (-not (Test-Path -LiteralPath $targetFull)) {
    New-Item -ItemType Directory -Force -Path $targetFull | Out-Null
    Add-Log "Created fresh install dir $targetFull"
    return
  }

  $documents = [Environment]::GetFolderPath('MyDocuments')
  $targetResolved = [System.IO.Path]::GetFullPath($targetFull)
  $documentsResolved = [System.IO.Path]::GetFullPath($documents).TrimEnd('\')
  if (-not $targetResolved.StartsWith($documentsResolved, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing fresh reinstall outside Documents: $targetResolved"
  }

  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $backup = "$targetFull.fresh-bak-$stamp"
  Stop-LikelyLockingProcesses -Workspace $targetFull
  try {
    Move-Item -LiteralPath $targetFull -Destination $backup -Force
  } catch {
    Start-Sleep -Seconds 2
    Stop-LikelyLockingProcesses -Workspace $targetFull
    Move-Item -LiteralPath $targetFull -Destination $backup -Force
  }
  New-Item -ItemType Directory -Force -Path $targetFull | Out-Null
  Add-Log "Moved old install dir to $backup"
  Write-Ok "Old install dir moved to $backup"
}

function Stop-LikelyLockingProcesses([string]$Workspace) {
  $workspaceFull = [System.IO.Path]::GetFullPath($Workspace).TrimEnd('\')
  Get-Process -ErrorAction SilentlyContinue |
    Where-Object {
      $_.ProcessName -match '^(claude|node|powershell|pwsh)$' -and
      $_.Id -ne $PID -and
      $_.Path
    } |
    ForEach-Object {
      $stop = $false
      try {
        if ($_.Path -like "$workspaceFull*") { $stop = $true }
        if (-not $stop) {
          $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -ErrorAction SilentlyContinue).CommandLine
          if ($cmd -and $cmd -like "*$workspaceFull*") { $stop = $true }
        }
      } catch {
      }
      if ($stop) {
        try {
          Add-Log "Stopping locking process $($_.ProcessName) pid=$($_.Id)"
          Stop-Process -Id $_.Id -Force
        } catch {
          Add-Log "WARN could not stop process $($_.Id): $($_.Exception.Message)"
        }
      }
    }
}

function Clear-ConflictingEnv {
  foreach ($name in @(
    'ANTHROPIC_API_KEY',
    'ANTHROPIC_AUTH_TOKEN',
    'ANTHROPIC_BASE_URL',
    'ANTHROPIC_MODEL',
    'CLAUDE_CODE_OAUTH_TOKEN',
    'CLAUDE_CODE_API_KEY',
    'DEEPSEEK_API_KEY',
    'DEEPSEEK_BASE_URL',
    'DEEPSEEK_MODEL',
    'PROVIDER_API_KEY',
    'PROVIDER_BASE_URL',
    'PROVIDER_MODEL',
    'PROVIDER_REASONING'
  )) {
    Remove-Item "Env:\$name" -ErrorAction SilentlyContinue
    foreach ($scope in @('User', 'Machine')) {
      if ([System.Environment]::GetEnvironmentVariable($name, $scope)) {
        try {
          [System.Environment]::SetEnvironmentVariable($name, $null, $scope)
          Add-Log "Removed $scope-level $name"
        } catch {
          Add-Log "WARN could not remove $scope-level ${name}: $($_.Exception.Message)"
        }
      }
    }
  }
}

function Backup-Path([string]$Path, [string]$Stamp) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $backup = "$Path.bak-$Stamp"
  Move-Item -LiteralPath $Path -Destination $backup -Force
  Add-Log "Backed up $Path to $backup"
  Write-Ok "Backed up $Path"
}

function Write-CleanEnv([string]$Workspace, [string]$Token, [string]$ModelId, [string]$ProviderBaseUrl, [string]$ProviderMode) {
  $envFile = Join-Path $Workspace '.env.local'
  if ($ProviderMode -eq 'anthropic') {
    if ($ProviderBaseUrl -match 'openrouter\.ai') {
      $content = @"
CLAUDE_PROVIDER=anthropic
ANTHROPIC_BASE_URL=$ProviderBaseUrl
ANTHROPIC_AUTH_TOKEN=$Token
ANTHROPIC_MODEL=$ModelId
PROVIDER_REASONING=auto
CLAUDE_WORKSPACE=$Workspace
CLAUDE_CLEAN_MODE=0
CLAUDE_HOOK_SAFE=1
"@
    } else {
      $content = @"
CLAUDE_PROVIDER=anthropic
ANTHROPIC_BASE_URL=$ProviderBaseUrl
ANTHROPIC_API_KEY=$Token
ANTHROPIC_MODEL=$ModelId
PROVIDER_REASONING=auto
CLAUDE_WORKSPACE=$Workspace
CLAUDE_CLEAN_MODE=0
CLAUDE_HOOK_SAFE=1
"@
    }
  } else {
    $content = @"
CLAUDE_PROVIDER=openai
PROVIDER_BASE_URL=$ProviderBaseUrl
PROVIDER_API_KEY=$Token
PROVIDER_MODEL=$ModelId
DEEPSEEK_BASE_URL=$ProviderBaseUrl
DEEPSEEK_API_KEY=$Token
DEEPSEEK_MODEL=$ModelId
ANTHROPIC_BASE_URL=http://127.0.0.1:17860
ANTHROPIC_AUTH_TOKEN=local-launcher-proxy
ANTHROPIC_MODEL=$ModelId
PROVIDER_REASONING=auto
CLAUDE_WORKSPACE=$Workspace
CLAUDE_CLEAN_MODE=0
CLAUDE_HOOK_SAFE=1
"@
  }
  [System.IO.File]::WriteAllText($envFile, $content + [Environment]::NewLine, $script:Utf8NoBom)
  Add-Log "Wrote clean .env.local with model $ModelId"
  Write-Ok "Wrote clean provider config"
}

function Ensure-Node {
  if (Test-Command node -and Test-Command npm) {
    Write-Ok "Detected Node.js $((& node --version))"
    Add-Log "Detected Node.js $((& node --version))"
    return
  }
  if (-not (Test-Command winget)) {
    throw "Node.js/npm was not found and winget is unavailable. Install Node.js LTS first."
  }
  Write-Host "Command: winget install -e --id OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements"
  Add-Log "Command: winget install -e --id OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements"
  & winget install -e --id OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements
  if ($LASTEXITCODE -ne 0) { throw "Node.js install failed with exit code $LASTEXITCODE" }
  $env:Path = "C:\Program Files\nodejs;$env:Path"
}

function Test-RequiredFiles([string]$Workspace) {
  foreach ($rel in @(
    'OneClick-Launcher.ps1',
    'scripts\claude-launcher.ps1',
    'scripts\start-claude.ps1',
    'scripts\deepseek-claude-proxy.cjs',
    'package.json'
  )) {
    $path = Join-Path $Workspace $rel
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing required file: $path" }
  }
  $pet = Join-Path $Workspace 'scripts\claude-pet.ps1'
  if (-not (Test-Path -LiteralPath $pet)) {
    Add-Log "Optional file missing: $pet"
    Write-Host "WARN Optional pet file is missing; Claude Code can still launch." -ForegroundColor Yellow
  }
  Write-Ok "Required files exist"
}

function Get-LauncherCmdName {
  return (-join (@(19968, 38190, 21551, 21160) | ForEach-Object { [char]$_ })) + '.cmd'
}

function Get-LegacyLauncherCmdName {
  return (-join (@(19968, 38190, 21551, 21160) | ForEach-Object { [char]$_ })) + 'DeepSeek.cmd'
}

function Write-LauncherCmd([string]$Path) {
  $content = @'
@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0OneClick-Launcher.ps1"
set "exitcode=%ERRORLEVEL%"
if not "%exitcode%"=="0" (
  echo.
  echo One-click run failed with exit code %exitcode%.
  pause
)
exit /b %exitcode%
'@
  [System.IO.File]::WriteAllText($Path, $content + [Environment]::NewLine, $script:Utf8NoBom)
  Add-Log "Recreated launcher command: $Path"
}

function Resolve-LauncherCmd([string]$Workspace) {
  $current = Join-Path $Workspace (Get-LauncherCmdName)
  if (Test-Path -LiteralPath $current) { return $current }

  $legacy = Join-Path $Workspace (Get-LegacyLauncherCmdName)
  if (Test-Path -LiteralPath $legacy) {
    Write-LauncherCmd -Path $current
    return $current
  }

  $mainScript = Join-Path $Workspace 'OneClick-Launcher.ps1'
  if (-not (Test-Path -LiteralPath $mainScript)) {
    throw "Missing one-click launcher script: $mainScript"
  }
  Write-LauncherCmd -Path $current
  return $current
}

function Create-Shortcut([string]$Workspace) {
  $desktop = [Environment]::GetFolderPath('Desktop')
  $shortcutPath = Join-Path $desktop 'Claude Code.lnk'
  $oneClick = Resolve-LauncherCmd -Workspace $Workspace
  $icon = Join-Path $Workspace 'assets\claude-code-style-icon.ico'
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($shortcutPath)
  $shortcut.TargetPath = $oneClick
  $shortcut.Arguments = ''
  $shortcut.WorkingDirectory = $Workspace
  if (Test-Path -LiteralPath $icon) { $shortcut.IconLocation = "$icon,0" }
  $shortcut.Description = 'Update and open Claude Code launcher'
  $shortcut.Save()
  Write-Ok "Desktop shortcut updated: $shortcutPath"
}

function Install-ClaudePetCommands([string]$Workspace) {
  $source = Join-Path $Workspace '.claude\commands'
  if (-not (Test-Path -LiteralPath $source)) { return }
  $target = Join-Path $HOME '.claude\commands'
  New-Item -ItemType Directory -Force -Path $target | Out-Null
  Copy-Item -LiteralPath (Join-Path $source 'pet*.md') -Destination $target -Force -ErrorAction SilentlyContinue
  Write-Ok "Claude pet slash commands installed"
}

function Test-ClaudeCodeTools([string]$Workspace) {
  $start = Join-Path $Workspace 'scripts\start-claude.ps1'
  $prompt = "Use available tools to list filenames in the current working directory. Your final answer must include package.json and OK."
  Push-Location $Workspace
  try {
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $start -Print -NoChinesePrompt -NoChineseUiHelp -PermissionMode acceptEdits $prompt 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    Pop-Location
  }
  $text = ($output | Out-String).Trim()
  Add-Log "Claude verification output: $text"
  Write-Host $text
  if ($exitCode -ne 0) { throw "Claude Code verification failed with exit code $exitCode" }
  if ($text -match 'Invalid tool parameters|API Error|Retrying|reasoning_content|Not logged in|auth conflict') {
    throw "Claude Code verification returned an error: $text"
  }
  if ($text -notmatch 'OK' -or $text -notmatch 'package\.json') {
    throw "Claude Code verification output did not prove tool success: $text"
  }
  Write-Ok "Claude Code tool verification passed"
}

function Show-LogTail {
  if (Test-Path -LiteralPath $script:LogFile) {
    Write-Host ''
    Write-Host "===== Last log lines: $script:LogFile =====" -ForegroundColor Yellow
    try {
      $all = [System.IO.File]::ReadAllLines($script:LogFile, $script:Utf8NoBom)
      $start = [Math]::Max(0, $all.Length - 120)
      for ($i = $start; $i -lt $all.Length; $i++) {
        Write-Host $all[$i]
      }
    } catch {
      Get-Content -LiteralPath $script:LogFile -Tail 120 -ErrorAction SilentlyContinue
    }
  }
}

$sourceRoot = $PSScriptRoot
$installRoot = [System.IO.Path]::GetFullPath($InstallDir)
New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
$script:LogFile = Join-Path $installRoot 'OneClick-Launcher.log'
[System.IO.File]::WriteAllText($script:LogFile, "Claude Code launcher one-click run started $(Get-Date -Format s)$([Environment]::NewLine)", $script:Utf8NoBom)

try {
  $modelId = Normalize-Model $Model
  Write-Host 'Claude Code launcher one-click install / repair / launch' -ForegroundColor Yellow
  Write-Host "Install directory: $installRoot"
  Write-Host "Log file: $script:LogFile"

  if ($RequireKeyAndVerify -and -not $AuthToken) {
    $secure = Read-Host 'Paste provider API key' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $AuthToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
  }
  if ($RequireKeyAndVerify -and (-not $AuthToken)) { throw "An API key is required." }

  if ($RequireKeyAndVerify -or $AuthToken) {
    Invoke-Logged 'Stop old Claude Code processes' { Stop-LikelyLockingProcesses -Workspace $installRoot }
  }
  Invoke-Logged 'Fresh reinstall directory' { Initialize-FreshInstallDir -Source $sourceRoot -Target $installRoot }
  Invoke-Logged 'Copy newest package files' { Copy-NewestFiles -Source $sourceRoot -Target $installRoot }
  Invoke-Logged 'Check Node.js/npm' { Ensure-Node }
  Invoke-Logged 'Install npm dependencies' {
    Push-Location $installRoot
    try {
      & npm install
      if ($LASTEXITCODE -ne 0) { throw "npm install failed with exit code $LASTEXITCODE" }
    } finally {
      Pop-Location
    }
  }
  Invoke-Logged 'Verify required files' { Test-RequiredFiles -Workspace $installRoot }
  if ($RequireKeyAndVerify -or $AuthToken) {
    Invoke-Logged 'Backup old Claude state' {
      $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
      Backup-Path (Join-Path $installRoot '.claude') $stamp
      if ($ClaudeStateDir) {
        Backup-Path ([System.IO.Path]::GetFullPath($ClaudeStateDir)) $stamp
      } else {
        Backup-Path (Join-Path $HOME '.claude') $stamp
      }
    }
    Invoke-Logged 'Clear conflicting environment variables' { Clear-ConflictingEnv }
  } else {
    Add-Log 'Preserving Claude state and environment because no key was provided'
  }
  if ($AuthToken) {
    Invoke-Logged 'Write clean provider proxy config' { Write-CleanEnv -Workspace $installRoot -Token $AuthToken -ModelId $modelId -ProviderBaseUrl $BaseUrl -ProviderMode $Provider }
  } elseif (-not (Test-Path -LiteralPath (Join-Path $installRoot '.env.local'))) {
    Invoke-Logged 'Write placeholder provider proxy config' { Write-CleanEnv -Workspace $installRoot -Token 'replace_with_your_api_key' -ModelId $modelId -ProviderBaseUrl $BaseUrl -ProviderMode $Provider }
  } else {
    Add-Log 'Keeping existing .env.local because no key was provided'
    Write-Ok 'Keeping existing .env.local'
  }
  Invoke-Logged 'Create desktop shortcut' { Create-Shortcut -Workspace $installRoot }
  Invoke-Logged 'Install Claude pet slash commands' { Install-ClaudePetCommands -Workspace $installRoot }
  if ($RequireKeyAndVerify -or $AuthToken) {
    Invoke-Logged 'Verify Claude Code tool use' { Test-ClaudeCodeTools -Workspace $installRoot }
  } else {
    Add-Log 'Skipped Claude Code verification because no key was provided'
    Write-Ok 'Skipped online verification; enter key in launcher'
  }

  Write-Host ''
  Write-Host 'All checks passed.' -ForegroundColor Green
  Add-Log 'All checks passed'

  if (-not $NoLaunch) {
    Invoke-Logged 'Launch Claude Code launcher' {
      $launcher = Join-Path $installRoot 'scripts\claude-launcher.ps1'
      Start-Process -FilePath powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$launcher`"" -WorkingDirectory $installRoot
    }
  }
} catch {
  Add-Log "FATAL: $($_.Exception.Message)"
  Write-Host ''
  Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
  Show-LogTail
  exit 1
} finally {
  if (-not $NoPause) {
    Write-Host ''
    Read-Host 'Press Enter to exit'
  }
}
