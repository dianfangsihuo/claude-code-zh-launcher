param()

$ErrorActionPreference = 'Stop'

function S([int[]]$Codes) {
  return -join ($Codes | ForEach-Object { [char]$_ })
}

function Quote-Arg([string]$Value) {
  return '"' + ($Value -replace '"', '\"') + '"'
}

function Read-EnvFile([string]$Path) {
  $map = @{}
  if (-not (Test-Path -LiteralPath $Path)) { return $map }

  $lines = [System.IO.File]::ReadAllLines($Path, [System.Text.UTF8Encoding]::new($false))
  foreach ($line in $lines) {
    $trimmed = $line.Trim()
    if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }

    $parts = $trimmed.Split('=', 2)
    if ($parts.Count -eq 2) {
      $map[$parts[0].Trim()] = $parts[1].Trim()
    }
  }
  return $map
}

function Get-LauncherConfigPath {
  $dir = Join-Path $HOME '.claude-code-oneclick'
  return Join-Path $dir 'launcher.env'
}

function Test-UsableValue([string]$Value) {
  if (-not $Value) { return $false }
  if ($Value -match 'replace_with') { return $false }
  if ($Value -in @('local-launcher-proxy', 'local-deepseek-proxy')) { return $false }
  return $true
}

function Get-MapValue($Primary, $Secondary, [string[]]$Keys, [string]$Fallback) {
  foreach ($key in $Keys) {
    if ($Primary.ContainsKey($key) -and (Test-UsableValue $Primary[$key])) { return $Primary[$key] }
  }
  foreach ($key in $Keys) {
    if ($Secondary.ContainsKey($key) -and (Test-UsableValue $Secondary[$key])) { return $Secondary[$key] }
  }
  return $Fallback
}

function Normalize-ClaudeBaseUrl([string]$Url, [string]$Provider) {
  $u = $Url.Trim().TrimEnd('/')
  if ($Provider -eq 'anthropic' -and $u.EndsWith('/v1', [System.StringComparison]::OrdinalIgnoreCase)) {
    return $u.Substring(0, $u.Length - 3).TrimEnd('/')
  }
  return $u
}

function Test-ProxyProviderUrl([string]$Url) {
  if (-not $Url) { return $false }
  return ($Url -match 'api\.deepseek\.com' -or $Url -match 'siliconflow\.(cn|com)')
}

function Resolve-ProviderModel([string]$Model, [string]$Url) {
  if (-not $Model) { return $Model }
  if ($Url -match 'siliconflow\.(cn|com)') {
    if ($Model -eq 'flash' -or $Model -eq 'deepseek-v4-flash') { return 'deepseek-ai/DeepSeek-V4-Flash' }
    if ($Model -eq 'pro' -or $Model -eq 'deepseek-v4-pro') { return 'deepseek-ai/DeepSeek-V4-Pro' }
  } else {
    if ($Model -eq 'flash') { return 'deepseek-v4-flash' }
    if ($Model -eq 'pro') { return 'deepseek-v4-pro' }
  }
  return $Model
}

function Get-ModelEndpointCandidates([string]$Url) {
  $u = $Url.Trim().TrimEnd('/')
  if ($u -match '^https://api\.deepseek\.com(/anthropic)?/?$') {
    return @('https://api.deepseek.com/models')
  }
  $path = ([Uri]$u).AbsolutePath.TrimEnd('/')
  if ($path -match '/(v\d+(?:beta)?|openai)$') {
    return @("$u/models")
  }
  return @("$u/v1/models", "$u/models")
}

function Get-ChatCompletionEndpointCandidates([string]$Url) {
  $u = $Url.Trim().TrimEnd('/')
  if ($u -match '^https://api\.deepseek\.com/?$') {
    return @("$u/chat/completions")
  }
  $path = ([Uri]$u).AbsolutePath.TrimEnd('/')
  if ($path -match '/(v\d+(?:beta)?|openai)$') {
    return @("$u/chat/completions")
  }
  return @("$u/v1/chat/completions", "$u/chat/completions")
}

function Invoke-ChatCompletionProbe([string]$Url, $Headers, [string]$Model) {
  if (-not (Test-UsableValue $Model)) {
    throw 'Current model is empty.'
  }

  $body = @{
    model = $Model
    messages = @(
      @{
        role = 'user'
        content = 'ping'
      }
    )
    max_tokens = 4
    stream = $false
  } | ConvertTo-Json -Depth 8

  $lastError = $null
  foreach ($endpoint in (Get-ChatCompletionEndpointCandidates $Url)) {
    try {
      $response = Invoke-RestMethod -Method Post -Uri $endpoint -Headers $Headers -ContentType 'application/json' -Body $body -TimeoutSec 30
      if ($response.choices -or $response.id) {
        return $endpoint
      }
      $lastError = "$endpoint returned no choices"
    } catch {
      $lastError = "$endpoint -> $($_.Exception.Message)"
    }
  }

  throw $lastError
}

function Get-OpenRouterAuthEndpoint([string]$Url) {
  $u = $Url.Trim().TrimEnd('/')
  if ($u.EndsWith('/v1', [System.StringComparison]::OrdinalIgnoreCase)) { return "$u/key" }
  return "$u/v1/key"
}

function Test-OpenRouterAuth([string]$Url, [string]$ApiKey) {
  if ($Url -notmatch 'openrouter\.ai') { return }
  if (-not (Test-UsableValue $ApiKey)) {
    throw 'OpenRouter API key is missing.'
  }
  if ($ApiKey -notlike 'sk-or-*') {
    throw 'OpenRouter API key should start with sk-or-. The model list may be public, but chat/auth endpoints require a real OpenRouter key.'
  }
  $headers = @{
    Authorization = "Bearer $ApiKey"
    'HTTP-Referer' = 'http://localhost'
    'X-Title' = 'Claude Code OneClick Check'
  }
  [void](Invoke-RestMethod -Method Get -Uri (Get-OpenRouterAuthEndpoint $Url) -Headers $headers -TimeoutSec 15)
}

function Get-RecentClaudeSessions([int]$Limit) {
  $sessions = @()
  $projectsDir = Join-Path $HOME '.claude\projects'
  if (-not (Test-Path -LiteralPath $projectsDir)) { return $sessions }

  $files = @(Get-ChildItem -LiteralPath $projectsDir -Filter '*.jsonl' -File -Recurse -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First $Limit)

  foreach ($file in $files) {
    $sessionId = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    $titleText = $null
    $promptText = $null
    $cwdText = $null
    try {
      foreach ($line in [System.IO.File]::ReadLines($file.FullName, [System.Text.UTF8Encoding]::new($false))) {
        if (-not $line) { continue }
        try {
          $item = $line | ConvertFrom-Json
        } catch {
          continue
        }
        if ($item.sessionId) { $sessionId = [string]$item.sessionId }
        if ($item.cwd) { $cwdText = [string]$item.cwd }
        if ($item.type -eq 'ai-title' -and $item.aiTitle) { $titleText = [string]$item.aiTitle }
        if ($item.type -eq 'last-prompt' -and $item.lastPrompt) { $promptText = [string]$item.lastPrompt }
        if (-not $promptText -and $item.message -and $item.message.role -eq 'user' -and $item.message.content) {
          if ($item.message.content -is [string]) {
            $promptText = [string]$item.message.content
          } else {
            $textParts = @($item.message.content | Where-Object { $_.type -eq 'text' -and $_.text } | ForEach-Object { $_.text })
            if ($textParts.Count -gt 0) { $promptText = [string]$textParts[0] }
          }
        }
      }
    } catch {
    }

    $name = $(if ($titleText) { $titleText } elseif ($promptText) { $promptText } else { $sessionId })
    $name = (($name -replace '\s+', ' ').Trim())
    if ($name.Length -gt 42) { $name = $name.Substring(0, 42) + '...' }
    $folderName = $(if ($cwdText) { Split-Path -Leaf $cwdText } else { Split-Path -Leaf $file.DirectoryName })
    $stamp = $file.LastWriteTime.ToString('MM-dd HH:mm')
    $shortId = $(if ($sessionId.Length -gt 8) { $sessionId.Substring(0, 8) } else { $sessionId })
    $sessions += [pscustomobject]@{
      Display = "$stamp  $name  [$folderName]  $shortId"
      SessionId = $sessionId
      Cwd = $cwdText
      Path = $file.FullName
    }
  }

  return $sessions
}

$workspace = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $workspace '.env.local'
$launcherConfigFile = Get-LauncherConfigPath
$envMap = Read-EnvFile $envFile
$globalMap = Read-EnvFile $launcherConfigFile

$defaultBaseUrl = Get-MapValue $envMap $globalMap @('PROVIDER_BASE_URL', 'DEEPSEEK_BASE_URL', 'ANTHROPIC_BASE_URL') 'https://api.deepseek.com'
$defaultApiKey = Get-MapValue $envMap $globalMap @('PROVIDER_API_KEY', 'DEEPSEEK_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_API_KEY') ''
$defaultModel = Get-MapValue $envMap $globalMap @('PROVIDER_MODEL', 'DEEPSEEK_MODEL', 'ANTHROPIC_MODEL') 'deepseek-v4-flash'
$defaultWorkspace = Get-MapValue $envMap $globalMap @('CLAUDE_WORKSPACE') $workspace
$defaultCleanMode = (Get-MapValue $envMap $globalMap @('CLAUDE_CLEAN_MODE') '0') -eq '1'
$defaultHookSafe = (Get-MapValue $envMap $globalMap @('CLAUDE_HOOK_SAFE') '1') -eq '1'
$defaultProvider = Get-MapValue $envMap $globalMap @('CLAUDE_PROVIDER') 'openai'
$defaultReasoning = Get-MapValue $envMap $globalMap @('PROVIDER_REASONING') 'auto'
$providerPresets = @(
  [pscustomobject]@{ Display = 'Custom / Any OpenAI-compatible'; BaseUrl = ''; Model = ''; Provider = 'openai' },
  [pscustomobject]@{ Display = 'DeepSeek'; BaseUrl = 'https://api.deepseek.com'; Model = 'deepseek-v4-flash'; Provider = 'openai' },
  [pscustomobject]@{ Display = 'SiliconFlow'; BaseUrl = 'https://api.siliconflow.cn/v1'; Model = 'deepseek-ai/DeepSeek-V4-Flash'; Provider = 'openai' },
  [pscustomobject]@{ Display = 'Z.AI / Zhipu'; BaseUrl = 'https://api.z.ai/api/paas/v4'; Model = 'glm-4.5'; Provider = 'openai' },
  [pscustomobject]@{ Display = 'BigModel / ' + (S @(26234,35889)); BaseUrl = 'https://open.bigmodel.cn/api/paas/v4'; Model = 'glm-4.5'; Provider = 'openai' },
  [pscustomobject]@{ Display = 'DashScope / ' + (S @(36890,20041,21315,38382)); BaseUrl = 'https://dashscope.aliyuncs.com/compatible-mode/v1'; Model = 'qwen-plus'; Provider = 'openai' },
  [pscustomobject]@{ Display = 'Moonshot / Kimi'; BaseUrl = 'https://api.moonshot.cn/v1'; Model = 'kimi-k2-0711-preview'; Provider = 'openai' },
  [pscustomobject]@{ Display = 'OpenRouter'; BaseUrl = 'https://openrouter.ai/api'; Model = 'deepseek/deepseek-v4-flash'; Provider = 'anthropic' },
  [pscustomobject]@{ Display = 'OpenAI'; BaseUrl = 'https://api.openai.com/v1'; Model = 'gpt-4o'; Provider = 'openai' },
  [pscustomobject]@{ Display = 'Gemini OpenAI-compatible'; BaseUrl = 'https://generativelanguage.googleapis.com/v1beta/openai'; Model = 'gemini-2.5-pro'; Provider = 'openai' },
  [pscustomobject]@{ Display = 'Groq'; BaseUrl = 'https://api.groq.com/openai/v1'; Model = 'llama-3.3-70b-versatile'; Provider = 'openai' },
  [pscustomobject]@{ Display = 'xAI'; BaseUrl = 'https://api.x.ai/v1'; Model = 'grok-4'; Provider = 'openai' },
  [pscustomobject]@{ Display = 'Anthropic-compatible direct'; BaseUrl = 'https://api.anthropic.com'; Model = 'claude-sonnet-4-5'; Provider = 'anthropic' }
)

$launcherVersion = '2026.05.27-hook-safe2'
$launcherTitle = 'Claude Code ' + (S @(20013,25991,21551,21160,22120)) + ' ' + $launcherVersion

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = $launcherTitle
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(760, 680)
$form.MinimumSize = New-Object System.Drawing.Size(760, 680)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(30, 27, 24)
$form.ForeColor = [System.Drawing.Color]::FromArgb(246, 232, 214)

$font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$titleFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 15, [System.Drawing.FontStyle]::Bold)
$form.Font = $font

function Add-Label($text, $x, $y) {
  $label = New-Object System.Windows.Forms.Label
  $label.Text = $text
  $label.AutoSize = $true
  $label.Location = New-Object System.Drawing.Point($x, $y)
  $form.Controls.Add($label)
  return $label
}

function Add-TextBox($x, $y, $w, $text) {
  $box = New-Object System.Windows.Forms.TextBox
  $box.Location = New-Object System.Drawing.Point($x, $y)
  $box.Size = New-Object System.Drawing.Size($w, 28)
  $box.Text = $text
  $form.Controls.Add($box)
  return $box
}

function Add-Combo($x, $y, $w, $items, $selected) {
  $combo = New-Object System.Windows.Forms.ComboBox
  $combo.DropDownStyle = 'DropDownList'
  $combo.Location = New-Object System.Drawing.Point($x, $y)
  $combo.Size = New-Object System.Drawing.Size($w, 28)
  [void]$combo.Items.AddRange($items)
  if ($items -contains $selected) {
    $combo.SelectedItem = $selected
  } else {
    [void]$combo.Items.Insert(0, $selected)
    $combo.SelectedItem = $selected
  }
  $form.Controls.Add($combo)
  return $combo
}

function New-ConfigContent([string]$BaseUrl, [string]$ApiKey, [string]$Model, [string]$Folder, [bool]$CleanMode, [bool]$HookSafe, [string]$Provider, [string]$Reasoning) {
  $selectedProvider = $(if ($Provider) { $Provider } else { 'openai' })
  $selectedBaseUrl = Normalize-ClaudeBaseUrl $BaseUrl $selectedProvider
  $selectedModel = Resolve-ProviderModel $Model $selectedBaseUrl
  $selectedReasoning = $(if ($Reasoning) { $Reasoning } else { 'auto' })
  $cleanValue = $(if ($CleanMode) { '1' } else { '0' })
  $hookSafeValue = $(if ($HookSafe) { '1' } else { '0' })
  if ($selectedProvider -ne 'anthropic') {
    if ($selectedBaseUrl -match 'siliconflow\.(cn|com)' -and $selectedModel -notlike 'deepseek-ai/*' -and $selectedModel -notlike 'Pro/*') {
      throw "SiliconFlow must use a SiliconFlow model id, for example deepseek-ai/DeepSeek-V4-Flash."
    }
    return @(
      "CLAUDE_PROVIDER=openai",
      "PROVIDER_BASE_URL=$selectedBaseUrl",
      "PROVIDER_API_KEY=$ApiKey",
      "PROVIDER_MODEL=$selectedModel",
      "DEEPSEEK_BASE_URL=$selectedBaseUrl",
      "DEEPSEEK_API_KEY=$ApiKey",
      "DEEPSEEK_MODEL=$selectedModel",
      "ANTHROPIC_BASE_URL=http://127.0.0.1:17860",
      "ANTHROPIC_AUTH_TOKEN=local-launcher-proxy",
      "ANTHROPIC_MODEL=$selectedModel",
      "PROVIDER_REASONING=$selectedReasoning",
      "CLAUDE_WORKSPACE=$Folder",
      "CLAUDE_CLEAN_MODE=$cleanValue",
      "CLAUDE_HOOK_SAFE=$hookSafeValue"
    ) -join [Environment]::NewLine
  }
  if ($selectedBaseUrl -match 'openrouter\.ai') {
    return @(
      "CLAUDE_PROVIDER=anthropic",
      "ANTHROPIC_BASE_URL=$selectedBaseUrl",
      "ANTHROPIC_AUTH_TOKEN=$ApiKey",
      "ANTHROPIC_MODEL=$selectedModel",
      "PROVIDER_REASONING=$selectedReasoning",
      "CLAUDE_WORKSPACE=$Folder",
      "CLAUDE_CLEAN_MODE=$cleanValue",
      "CLAUDE_HOOK_SAFE=$hookSafeValue"
    ) -join [Environment]::NewLine
  }
  return @(
    "CLAUDE_PROVIDER=anthropic",
    "ANTHROPIC_BASE_URL=$selectedBaseUrl",
    "ANTHROPIC_API_KEY=$ApiKey",
    "ANTHROPIC_MODEL=$selectedModel",
    "PROVIDER_REASONING=$selectedReasoning",
    "CLAUDE_WORKSPACE=$Folder",
    "CLAUDE_CLEAN_MODE=$cleanValue",
    "CLAUDE_HOOK_SAFE=$hookSafeValue"
  ) -join [Environment]::NewLine
}

function Save-Config([string]$BaseUrl, [string]$ApiKey, [string]$Model, [string]$Folder, [bool]$CleanMode, [bool]$HookSafe, [string]$Provider, [string]$Reasoning) {
  $content = New-ConfigContent $BaseUrl $ApiKey $Model $Folder $CleanMode $HookSafe $Provider $Reasoning
  [System.IO.File]::WriteAllText($envFile, $content + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
  $configDir = Split-Path -Parent $launcherConfigFile
  New-Item -ItemType Directory -Force -Path $configDir | Out-Null
  [System.IO.File]::WriteAllText($launcherConfigFile, $content + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
  return $content
}

$title = New-Object System.Windows.Forms.Label
$title.Text = $launcherTitle
$title.Font = $titleFont
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(36, 20)
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'OpenAI proxy / Anthropic direct'
$subtitle.AutoSize = $true
$subtitle.ForeColor = [System.Drawing.Color]::FromArgb(214, 139, 82)
$subtitle.Location = New-Object System.Drawing.Point(38, 55)
$form.Controls.Add($subtitle)

[void](Add-Label 'Preset' 490 55)
$presetCombo = New-Object System.Windows.Forms.ComboBox
$presetCombo.DropDownStyle = 'DropDownList'
$presetCombo.Location = New-Object System.Drawing.Point(550, 51)
$presetCombo.Size = New-Object System.Drawing.Size(174, 28)
$presetCombo.DisplayMember = 'Display'
[void]$presetCombo.Items.AddRange([object[]]$providerPresets)
$presetCombo.SelectedIndex = 0
for ($i = 1; $i -lt $providerPresets.Count; $i++) {
  if ($defaultBaseUrl.TrimEnd('/') -ieq $providerPresets[$i].BaseUrl.TrimEnd('/')) {
    $presetCombo.SelectedIndex = $i
    break
  }
}
$form.Controls.Add($presetCombo)

[void](Add-Label ((S @(19978,28216,22320,22336)) + ' / URL') 38 92)
$urlBox = Add-TextBox 220 88 410 $defaultBaseUrl

$detectButton = New-Object System.Windows.Forms.Button
$detectButton.Text = S @(26816,27979,27169,22411)
$detectButton.Size = New-Object System.Drawing.Size(92, 30)
$detectButton.Location = New-Object System.Drawing.Point(640, 86)
$detectButton.BackColor = [System.Drawing.Color]::FromArgb(64, 55, 47)
$detectButton.ForeColor = [System.Drawing.Color]::FromArgb(246, 232, 214)
$detectButton.FlatStyle = 'Flat'
$form.Controls.Add($detectButton)

[void](Add-Label 'API Key' 38 132)
$keyBox = Add-TextBox 220 128 512 $defaultApiKey
$keyBox.UseSystemPasswordChar = $true

[void](Add-Label ((S @(24037,20316,25991,20214,22841)) + ' / Folder') 38 172)
$folderBox = Add-TextBox 220 168 410 $defaultWorkspace

$folderButton = New-Object System.Windows.Forms.Button
$folderButton.Text = S @(36873,25321)
$folderButton.Size = New-Object System.Drawing.Size(92, 30)
$folderButton.Location = New-Object System.Drawing.Point(640, 166)
$folderButton.BackColor = [System.Drawing.Color]::FromArgb(64, 55, 47)
$folderButton.ForeColor = [System.Drawing.Color]::FromArgb(246, 232, 214)
$folderButton.FlatStyle = 'Flat'
$form.Controls.Add($folderButton)

[void](Add-Label ((S @(27169,22411)) + ' / Model') 38 212)
$modelCombo = Add-Combo 220 208 512 @('deepseek/deepseek-v4-flash', 'deepseek/deepseek-v4-pro', 'deepseek-v4-flash', 'deepseek-v4-pro', 'deepseek-ai/DeepSeek-V4-Flash', 'deepseek-ai/DeepSeek-V4-Pro', 'flash', 'pro', 'gpt-5.5', 'gpt-5.4', 'gpt-5.4-mini', 'gpt-5.3-codex', 'gpt-5.2') $defaultModel

[void](Add-Label 'Provider' 38 252)
$providerCombo = Add-Combo 220 248 512 @('openai', 'anthropic', 'auto') $defaultProvider

$presetCombo.Add_SelectedIndexChanged({
  $preset = $presetCombo.SelectedItem
  if (-not $preset -or -not $preset.BaseUrl) { return }
  $urlBox.Text = $preset.BaseUrl
  if ($preset.Model) {
    if (-not $modelCombo.Items.Contains($preset.Model)) {
      [void]$modelCombo.Items.Insert(0, $preset.Model)
    }
    $modelCombo.SelectedItem = $preset.Model
  }
  if ($preset.Provider -and $providerCombo.Items.Contains($preset.Provider)) {
    $providerCombo.SelectedItem = $preset.Provider
  }
})

[void](Add-Label ((S @(24605,32771,31243,24230)) + ' / Effort') 38 292)
$effortCombo = Add-Combo 220 288 512 @('low', 'medium', 'high', 'xhigh', 'max') 'medium'

[void](Add-Label 'Thinking / Reasoning' 38 332)
$reasoningCombo = Add-Combo 220 328 512 @('auto', 'off', 'low', 'medium', 'high', 'xhigh', 'max') $defaultReasoning

[void](Add-Label ((S @(21551,21160,27169,24335)) + ' / Mode') 38 372)
$modeCombo = Add-Combo 220 368 512 @('default', 'acceptEdits', 'plan', 'dontAsk', 'bypassPermissions') 'default'

$sessionItems = @([pscustomobject]@{ Display = 'New Session'; SessionId = ''; Cwd = ''; Path = '' })
$sessionItems += [pscustomobject]@{ Display = 'Continue Latest'; SessionId = '__continue__'; Cwd = ''; Path = '' }
$sessionItems += @(Get-RecentClaudeSessions 30)

[void](Add-Label 'Session' 38 412)
$sessionCombo = New-Object System.Windows.Forms.ComboBox
$sessionCombo.DropDownStyle = 'DropDownList'
$sessionCombo.Location = New-Object System.Drawing.Point(220, 408)
$sessionCombo.Size = New-Object System.Drawing.Size(512, 28)
$sessionCombo.DisplayMember = 'Display'
[void]$sessionCombo.Items.AddRange([object[]]$sessionItems)
$sessionCombo.SelectedIndex = 0
$form.Controls.Add($sessionCombo)

$chineseCheck = New-Object System.Windows.Forms.CheckBox
$chineseCheck.Text = S @(20013,25991,21451,22909)
$chineseCheck.Checked = $true
$chineseCheck.AutoSize = $true
$chineseCheck.Location = New-Object System.Drawing.Point(220, 448)
$form.Controls.Add($chineseCheck)

$bareCheck = New-Object System.Windows.Forms.CheckBox
$bareCheck.Text = (S @(31934,31616,27169,24335)) + ' / Bare'
$bareCheck.Checked = $false
$bareCheck.AutoSize = $true
$bareCheck.Location = New-Object System.Drawing.Point(350, 448)
$form.Controls.Add($bareCheck)

$petCheck = New-Object System.Windows.Forms.CheckBox
$petCheck.Text = (S @(26700,23456)) + ' / Pet'
$petCheck.Checked = $true
$petCheck.AutoSize = $true
$petCheck.Location = New-Object System.Drawing.Point(470, 448)
$form.Controls.Add($petCheck)

$motionCheck = New-Object System.Windows.Forms.CheckBox
$motionCheck.Text = 'Motion'
$motionCheck.Checked = $false
$motionCheck.AutoSize = $true
$motionCheck.Location = New-Object System.Drawing.Point(590, 448)
$form.Controls.Add($motionCheck)

$cleanCheck = New-Object System.Windows.Forms.CheckBox
$cleanCheck.Text = 'Clean / No Hooks'
$cleanCheck.Checked = $defaultCleanMode
$cleanCheck.AutoSize = $true
$cleanCheck.Location = New-Object System.Drawing.Point(220, 475)
$form.Controls.Add($cleanCheck)

$hookSafeCheck = New-Object System.Windows.Forms.CheckBox
$hookSafeCheck.Text = 'Hook Safe'
$hookSafeCheck.Checked = $defaultHookSafe
$hookSafeCheck.AutoSize = $true
$hookSafeCheck.Location = New-Object System.Drawing.Point(390, 475)
$form.Controls.Add($hookSafeCheck)

$status = New-Object System.Windows.Forms.Label
$status.Text = S @(25552,31034,65306,21487,36755,20837,32,47,118,49,32,25110,19981,24102,32,47,118,49,32,30340,19978,28216,22320,22336,65292,28857,20987,26816,27979,27169,22411,12290)
$status.Size = New-Object System.Drawing.Size(690, 45)
$status.ForeColor = [System.Drawing.Color]::FromArgb(180, 169, 158)
$status.Location = New-Object System.Drawing.Point(38, 502)
$form.Controls.Add($status)

$launchButton = New-Object System.Windows.Forms.Button
$launchButton.Text = S @(21551,21160,32,67,108,97,117,100,101,32,67,111,100,101)
$launchButton.Size = New-Object System.Drawing.Size(180, 38)
$launchButton.Location = New-Object System.Drawing.Point(220, 565)
$launchButton.BackColor = [System.Drawing.Color]::FromArgb(214, 139, 82)
$launchButton.ForeColor = [System.Drawing.Color]::FromArgb(24, 21, 18)
$launchButton.FlatStyle = 'Flat'
$form.Controls.Add($launchButton)

$saveButton = New-Object System.Windows.Forms.Button
$saveButton.Text = 'Save Config'
$saveButton.Size = New-Object System.Drawing.Size(150, 38)
$saveButton.Location = New-Object System.Drawing.Point(430, 565)
$saveButton.BackColor = [System.Drawing.Color]::FromArgb(64, 55, 47)
$saveButton.ForeColor = [System.Drawing.Color]::FromArgb(246, 232, 214)
$saveButton.FlatStyle = 'Flat'
$form.Controls.Add($saveButton)

$folderButton.Add_Click({
  $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
  $dialog.Description = S @(36873,25321,32,67,108,97,117,100,101,32,67,111,100,101,32,21551,21160,30340,24037,20316,25991,20214,22841)
  if (Test-Path -LiteralPath $folderBox.Text) {
    $dialog.SelectedPath = $folderBox.Text
  }
  if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $folderBox.Text = $dialog.SelectedPath
  }
})

$detectButton.Add_Click({
  try {
    $detectButton.Enabled = $false
    $status.Text = S @(27491,22312,26816,27979,19978,28216,27169,22411,46,46,46)
    [System.Windows.Forms.Application]::DoEvents()

    $headers = @{
      Authorization = "Bearer $($keyBox.Text)"
      'x-api-key' = $keyBox.Text
    }

    Test-OpenRouterAuth $urlBox.Text $keyBox.Text

    $models = @()
    $usedEndpoint = $null
    $modelErrors = @()
    foreach ($endpoint in (Get-ModelEndpointCandidates $urlBox.Text)) {
      try {
        $response = Invoke-RestMethod -Method Get -Uri $endpoint -Headers $headers -TimeoutSec 15
        if ($response.data) {
          $models = @($response.data | ForEach-Object { $_.id } | Where-Object { $_ })
        }
        if ($models.Count -gt 0) {
          $usedEndpoint = $endpoint
          break
        }
      } catch {
        $modelErrors += "$endpoint -> $($_.Exception.Message)"
      }
    }

    $current = $modelCombo.Text
    if ($models.Count -eq 0) {
      if ([string]$providerCombo.SelectedItem -ne 'openai') {
        $detail = $(if ($modelErrors.Count -gt 0) { ' Last error: ' + $modelErrors[-1] } else { '' })
        throw "No models returned.$detail"
      }

      try {
        $probeModel = Resolve-ProviderModel $current $urlBox.Text
        $usedEndpoint = Invoke-ChatCompletionProbe $urlBox.Text $headers $probeModel
        $models = @($current)
      } catch {
        $detail = $(if ($modelErrors.Count -gt 0) { ' Last /models error: ' + $modelErrors[-1] } else { '' })
        throw "No models returned, and current model probe failed: $($_.Exception.Message).$detail"
      }
    }

    $modelCombo.Items.Clear()
    [void]$modelCombo.Items.AddRange([string[]]$models)
    if ($models -contains $current) {
      $modelCombo.SelectedItem = $current
    } elseif ($models -contains $defaultModel) {
      $modelCombo.SelectedItem = $defaultModel
    } else {
      $modelCombo.SelectedIndex = 0
    }

    $claudeBase = Normalize-ClaudeBaseUrl $urlBox.Text ([string]$providerCombo.SelectedItem)
    if ($models.Count -eq 1 -and $models[0] -eq $current -and $usedEndpoint -match '/chat/completions$') {
      $status.Text = (S @(26816,27979,25104,21151,65306)) + " current model works via chat probe, endpoint: $usedEndpoint, Claude base: $claudeBase"
    } else {
      $status.Text = (S @(26816,27979,25104,21151,65306)) + " $($models.Count) models, endpoint: $usedEndpoint, Claude base: $claudeBase"
    }
  } catch {
    $status.Text = (S @(26816,27979,22833,36133,65306)) + " $($_.Exception.Message)"
  } finally {
    $detectButton.Enabled = $true
  }
})

$saveButton.Add_Click({
  try {
    if (-not (Test-Path -LiteralPath $folderBox.Text)) {
      [System.Windows.Forms.MessageBox]::Show((S @(24037,20316,25991,20214,22841,19981,23384,22312)) + ": $($folderBox.Text)", $launcherTitle) | Out-Null
      return
    }
    $selectedModel = [string]$modelCombo.SelectedItem
    [void](Save-Config $urlBox.Text $keyBox.Text $selectedModel $folderBox.Text $cleanCheck.Checked $hookSafeCheck.Checked ([string]$providerCombo.SelectedItem) ([string]$reasoningCombo.SelectedItem))
    $status.Text = "Saved config to .env.local and $launcherConfigFile"
  } catch {
    [System.Windows.Forms.MessageBox]::Show("Failed to save config: $($_.Exception.Message)", $launcherTitle) | Out-Null
  }
})

$launchButton.Add_Click({
  if (-not (Test-Path -LiteralPath $folderBox.Text)) {
    [System.Windows.Forms.MessageBox]::Show((S @(24037,20316,25991,20214,22841,19981,23384,22312)) + ": $($folderBox.Text)", $launcherTitle) | Out-Null
    return
  }

  try {
    $selectedModel = [string]$modelCombo.SelectedItem
    [void](Save-Config $urlBox.Text $keyBox.Text $selectedModel $folderBox.Text $cleanCheck.Checked $hookSafeCheck.Checked ([string]$providerCombo.SelectedItem) ([string]$reasoningCombo.SelectedItem))
    $selectedBaseUrl = Normalize-ClaudeBaseUrl $urlBox.Text ([string]$providerCombo.SelectedItem)
    $selectedModel = Resolve-ProviderModel $selectedModel $selectedBaseUrl
  } catch {
    [System.Windows.Forms.MessageBox]::Show("Failed to save config: $($_.Exception.Message)", $launcherTitle) | Out-Null
    return
  }

  $script = Join-Path $workspace 'scripts\start-claude.ps1'
  $argList = @(
    '-NoExit',
    '-ExecutionPolicy', 'BYPASS',
    '-File', (Quote-Arg $script),
    '-BaseUrl', (Quote-Arg $urlBox.Text),
    '-ApiKey', (Quote-Arg $keyBox.Text),
    '-Model', (Quote-Arg $selectedModel),
    '-Provider', (Quote-Arg $providerCombo.SelectedItem),
    '-Effort', (Quote-Arg $effortCombo.SelectedItem),
    '-Reasoning', (Quote-Arg $reasoningCombo.SelectedItem)
  )
  if ($modeCombo.SelectedItem -ne 'default') {
    $argList += @('-PermissionMode', (Quote-Arg $modeCombo.SelectedItem))
  }
  $selectedSession = $sessionCombo.SelectedItem
  if ($selectedSession -and $selectedSession.SessionId -eq '__continue__') {
    $argList += '-ContinueLatest'
  } elseif ($selectedSession -and $selectedSession.SessionId) {
    $argList += @('-ResumeSessionId', (Quote-Arg $selectedSession.SessionId))
  }
  if (-not $chineseCheck.Checked) {
    $argList += '-NoChinesePrompt'
  }
  if ($bareCheck.Checked) {
    $argList += '-Bare'
  }
  if ($cleanCheck.Checked) {
    $argList += '-CleanMode'
  }
  if ($hookSafeCheck.Checked) {
    $argList += '-HookSafe'
  }
  if (-not $petCheck.Checked) {
    $argList += '-NoPet'
  }
  if ($motionCheck.Checked) {
    $argList += '-PetMotion'
  }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  $psi.Arguments = ($argList -join ' ')
  $psi.WorkingDirectory = $folderBox.Text
  [void][System.Diagnostics.Process]::Start($psi)
  $form.Close()
})

[void]$form.ShowDialog()
