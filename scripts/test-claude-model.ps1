$ErrorActionPreference = 'Stop'

$workspace = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $workspace '.env.local'

if (-not (Test-Path -LiteralPath $envFile)) {
  throw "Missing .env.local."
}

$lines = [System.IO.File]::ReadAllLines($envFile, [System.Text.UTF8Encoding]::new($false))
foreach ($line in $lines) {
  $trimmed = $line.Trim()
  if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }

  $parts = $trimmed.Split('=', 2)
  if ($parts.Count -ne 2) { continue }

    [System.Environment]::SetEnvironmentVariable($parts[0].Trim(), $parts[1].Trim(), 'Process')
}

if (-not $env:ANTHROPIC_BASE_URL -and -not $env:PROVIDER_BASE_URL -and -not $env:DEEPSEEK_BASE_URL) { throw "Provider base URL is not set." }
if (-not $env:ANTHROPIC_API_KEY -and -not $env:ANTHROPIC_AUTH_TOKEN -and -not $env:PROVIDER_API_KEY -and -not $env:DEEPSEEK_API_KEY) { throw "Provider API key is not set." }
if (-not $env:ANTHROPIC_MODEL -and -not $env:PROVIDER_MODEL -and -not $env:DEEPSEEK_MODEL) { $env:ANTHROPIC_MODEL = 'deepseek-v4-pro' }

if ($env:ANTHROPIC_BASE_URL -match '^https://api\.deepseek\.com/?$') {
  $env:ANTHROPIC_BASE_URL = 'https://api.deepseek.com/anthropic'
}
if ($env:ANTHROPIC_MODEL -eq 'pro') {
  $env:ANTHROPIC_MODEL = 'deepseek-v4-pro'
}
if ($env:ANTHROPIC_MODEL -eq 'flash') {
  $env:ANTHROPIC_MODEL = 'deepseek-v4-flash'
}

if ($env:ANTHROPIC_BASE_URL -match 'api\.deepseek\.com') {
  if (-not $env:ANTHROPIC_AUTH_TOKEN -and $env:ANTHROPIC_API_KEY) {
    $env:ANTHROPIC_AUTH_TOKEN = $env:ANTHROPIC_API_KEY
  }
  Remove-Item Env:\ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
}

$providerMode = $(if ($env:CLAUDE_PROVIDER) { $env:CLAUDE_PROVIDER } else { 'openai' })
if ($providerMode -ne 'anthropic') {
  $proxyScript = Join-Path $workspace 'scripts\deepseek-claude-proxy.cjs'
  $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
  if (-not $nodeCmd) { throw "Node.js is required for the local provider proxy." }

  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse('127.0.0.1'), 0)
  $listener.Start()
  $proxyPort = $listener.LocalEndpoint.Port
  $listener.Stop()

  $proxyBaseUrl = $(if ($env:PROVIDER_BASE_URL) { $env:PROVIDER_BASE_URL } elseif ($env:DEEPSEEK_BASE_URL) { $env:DEEPSEEK_BASE_URL } else { $env:ANTHROPIC_BASE_URL })
  $proxyApiKey = $(if ($env:PROVIDER_API_KEY) { $env:PROVIDER_API_KEY } elseif ($env:DEEPSEEK_API_KEY) { $env:DEEPSEEK_API_KEY } elseif ($env:ANTHROPIC_AUTH_TOKEN -and $env:ANTHROPIC_AUTH_TOKEN -notin @('local-launcher-proxy', 'local-deepseek-proxy')) { $env:ANTHROPIC_AUTH_TOKEN } else { $env:ANTHROPIC_API_KEY })
  $proxyModel = $(if ($env:PROVIDER_MODEL) { $env:PROVIDER_MODEL } elseif ($env:DEEPSEEK_MODEL) { $env:DEEPSEEK_MODEL } else { $env:ANTHROPIC_MODEL })
  $proxyReasoning = $(if ($env:PROVIDER_REASONING) { $env:PROVIDER_REASONING } else { 'auto' })

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $nodeCmd.Source
  $psi.Arguments = "`"$proxyScript`""
  $psi.WorkingDirectory = $workspace
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.EnvironmentVariables['DEEPSEEK_PROXY_PORT'] = [string]$proxyPort
  $psi.EnvironmentVariables['PROVIDER_BASE_URL'] = $proxyBaseUrl
  $psi.EnvironmentVariables['PROVIDER_API_KEY'] = $proxyApiKey
  $psi.EnvironmentVariables['PROVIDER_MODEL'] = $proxyModel
  $psi.EnvironmentVariables['PROVIDER_REASONING'] = $proxyReasoning
  $psi.EnvironmentVariables['PROVIDER_NAME'] = $(if ($proxyBaseUrl -match 'deepseek') { 'deepseek' } elseif ($proxyBaseUrl -match 'siliconflow') { 'siliconflow' } elseif ($proxyBaseUrl -match 'openrouter') { 'openrouter' } else { 'openai-compatible' })
  $proxyProcess = [System.Diagnostics.Process]::Start($psi)

  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $health = Invoke-RestMethod -Method Get -Uri "http://127.0.0.1:$proxyPort/health" -TimeoutSec 2
      if ($health.ok) { break }
    } catch {
    }
    if ($i -eq 39) { throw "Local provider proxy failed to start." }
  }
  $env:ANTHROPIC_BASE_URL = "http://127.0.0.1:$proxyPort"
  $env:ANTHROPIC_AUTH_TOKEN = 'local-launcher-proxy'
  $env:ANTHROPIC_MODEL = $proxyModel
  Remove-Item Env:\ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
}

$headers = @{
  'anthropic-version' = '2023-06-01'
  'content-type' = 'application/json'
}
if ($env:ANTHROPIC_AUTH_TOKEN) {
  $headers['Authorization'] = "Bearer $($env:ANTHROPIC_AUTH_TOKEN)"
} else {
  $headers['x-api-key'] = $env:ANTHROPIC_API_KEY
}

$body = @{
  model = $env:ANTHROPIC_MODEL
  max_tokens = 128
  messages = @(
    @{
      role = 'user'
      content = 'Reply with exactly: OK'
    }
  )
} | ConvertTo-Json -Depth 8

try {
  $response = Invoke-RestMethod -Method Post -Uri "$($env:ANTHROPIC_BASE_URL)/v1/messages" -Headers $headers -Body $body -TimeoutSec 60
} finally {
  if ($proxyProcess -and -not $proxyProcess.HasExited) {
    try {
      $proxyProcess.Kill()
      $proxyProcess.WaitForExit(3000) | Out-Null
    } catch {
    }
  }
}
$textBlock = @($response.content | Where-Object { $_.type -eq 'text' -and $_.text } | Select-Object -First 1)
$text = ''
if ($textBlock) {
  $text = $textBlock.text
}

Write-Output "Model: $($response.model)"
Write-Output "Reply: $text"
Write-Output "Usage: input=$($response.usage.input_tokens), output=$($response.usage.output_tokens)"

if ($text -ne 'OK') {
  throw "Unexpected model reply: $text"
}

Write-Output 'Model test passed.'
