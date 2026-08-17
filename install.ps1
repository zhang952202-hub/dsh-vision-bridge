# dsh-vision-bridge installer (Windows / PowerShell)
# Installs the analyze_image tool plugin, the chat-attachment proxy wiring,
# the standard-vision preset, model picker entries and (optionally) logon autostart.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Upstream https://api.deepseek.com -TextModelId deepseek-v4-flash -ApiKeyEnv DEEPSEEK_API_KEY -Autostart
#   powershell -ExecutionPolicy Bypass -File install.ps1 -DryRun   # preview only

param(
  [string]$Upstream = "https://api.deepseek.com",
  [string]$TextModelId = "deepseek-v4-flash",
  [string]$ApiKeyEnv = "DEEPSEEK_API_KEY",
  [string]$VisionUrl = "http://127.0.0.1:11434/v1/chat/completions",
  [string]$VisionModel = "qwen2.5vl:3b",
  [switch]$Autostart,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$packageRoot = $PSScriptRoot

function Write-FileUtf8([string]$path, [string]$content) {
  if ($DryRun) { Write-Host "  [dry-run] write $path"; return }
  [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))
}

function Run-Cmd([string]$desc, [scriptblock]$body) {
  if ($DryRun) { Write-Host "  [dry-run] $desc"; return }
  Write-Host "  -> $desc"
  & $body
  if ($LASTEXITCODE -ne 0) { throw "command failed: $desc" }
}

Write-Host "===== dsh-vision-bridge install ====="

# ------------------------------------------------------------ prerequisites
foreach ($tool in @("node", "pnpm", "python", "dsh")) {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
    throw "Prerequisite missing: $tool (install it first)"
  }
}
$profileDir = "$env:USERPROFILE\.dsh\profiles\web"
if (-not (Test-Path $profileDir)) { throw "web profile not found: $profileDir" }
Write-Host "Prerequisites OK (node/pnpm/python/dsh, web profile present)"

# ------------------------------------------------- dsh-tools bundled copy
$dshCmd = Get-Command dsh | Select-Object -First 1
$npmDir = Split-Path $dshCmd.Source
$dshTools = Join-Path $npmDir "node_modules\@deepseek-ai\dsh\node_modules\@deepseek-ai\dsh-tools"
if (-not (Test-Path $dshTools)) {
  throw "dsh-tools not found at $dshTools (unexpected dsh install layout)"
}
Write-Host "dsh-tools: $dshTools"

# ------------------------------------------------------------ plugin folder
$pluginDest = "$env:USERPROFILE\.dsh\plugins\dsh-vision-bridge"
$pluginSrc = Join-Path $packageRoot "plugin\vision"
Write-Host "Installing plugin to $pluginDest"
if ($DryRun) {
  Write-Host "  [dry-run] copy plugin\vision -> $pluginDest"
} else {
  New-Item -ItemType Directory -Force -Path $pluginDest | Out-Null
  Copy-Item -Path (Join-Path $pluginSrc "*") -Destination $pluginDest -Recurse -Force
  $pkgFile = Join-Path $pluginDest "package.json"
  $pkg = [System.IO.File]::ReadAllText($pkgFile)
  $pkg = $pkg.Replace("<DSH_TOOLS_PATH>", $dshTools.Replace("\", "/"))
  Write-FileUtf8 $pkgFile $pkg
}
Run-Cmd "pnpm install in $pluginDest" {
  Push-Location $pluginDest
  pnpm install
  Pop-Location
}

# ------------------------------------------------------------ profile wiring
$profilePkg = Join-Path $profileDir "package.json"
$patchFile = Join-Path $profileDir "cordis.patch.yml"
$existing = ""
if (Test-Path $profilePkg) {
  $existing = [System.IO.File]::ReadAllText($profilePkg)
}
$alreadyInstalled = ($existing -match 'dsh-vision-bridge|dsh-vision-tools')

if ($alreadyInstalled) {
  Write-Host "Existing vision plugin detected in web profile - skipping plugin wiring (keep your current install)"
} else {
  Write-Host "Wiring plugin into web profile"
  if ($DryRun) {
    Write-Host "  [dry-run] add dependency dsh-vision-bridge -> link:$pluginDest"
    Write-Host "  [dry-run] append patch row to $patchFile"
    Write-Host "  [dry-run] pnpm install in $profileDir"
  } else {
    $pkgObj = Get-Content $profilePkg -Raw | ConvertFrom-Json
    $pkgObj.dependencies."dsh-vision-bridge" = "link:$($pluginDest.Replace("\", "/"))"
    $json = $pkgObj | ConvertTo-Json -Depth 10
    Write-FileUtf8 $profilePkg $json

    $patchAdd = @"

- insert:
    - id: dsh-vision-bridge
      name: 'dsh-vision-bridge'
"@
    [System.IO.File]::AppendAllText($patchFile, $patchAdd, (New-Object System.Text.UTF8Encoding($false)))

    Run-Cmd "pnpm install in $profileDir" {
      Push-Location $profileDir
      pnpm install
      Pop-Location
    }
  }
}

# ------------------------------------------------- standard-vision preset
$presetDir = "$env:USERPROFILE\.dsh\.agent-presets\standard-vision"
if (-not (Test-Path $presetDir)) {
  Write-Host "Creating standard-vision preset"
  $stdPreset = Join-Path $npmDir "node_modules\@deepseek-ai\dsh\config\agent-presets\standard"
  if ($DryRun) {
    Write-Host "  [dry-run] copy $stdPreset -> $presetDir + append vision row"
  } else {
    Copy-Item -Path $stdPreset -Destination $presetDir -Recurse -Force
    $agentFile = Join-Path $presetDir "agent.cordis.yml"
    $row = "`n- id: dsh-vision-bridge`n  name: 'dsh-vision-bridge'`n"
    [System.IO.File]::AppendAllText($agentFile, $row, (New-Object System.Text.UTF8Encoding($false)))
  }
} else {
  Write-Host "standard-vision preset already exists"
}

$settingsFile = "$env:USERPROFILE\.dsh\settings.yaml"
$settingsText = if (Test-Path $settingsFile) { [System.IO.File]::ReadAllText($settingsFile) } else { "" }
if ($settingsText -notmatch 'default: standard-vision') {
  Write-Host "Setting default agent preset to standard-vision"
  $add = "`nagent-presets:`n  default: standard-vision`n"
  if ($DryRun) { Write-Host "  [dry-run] append to $settingsFile" }
  else { [System.IO.File]::AppendAllText($settingsFile, $add, (New-Object System.Text.UTF8Encoding($false))) }
}

# ----------------------------------------------------- model picker entries
if ($settingsText -notmatch 'llm-pi-ai') {
  Write-Host "Adding model picker entries (Vision Bridge)"
  $block = @"

llm-pi-ai:
  providers:
    vision-bridge:
      displayName: Vision Bridge
      apiKeyEnv: $ApiKeyEnv
      api: openai-completions
      baseURL: http://127.0.0.1:8900/v1
      models:
        - id: $TextModelId
          displayName: $TextModelId + Vision
          contextWindow: 262144
          maxTokens: 32768
          input: [text, image]
    zhipu-vision:
      displayName: Zhipu Vision (GLM-4.6V)
      apiKeyEnv: ZHIPU_API_KEY
      api: openai-completions
      baseURL: https://open.bigmodel.cn/api/paas/v4
      models:
        - id: glm-4.6v-flash
          displayName: glm-4.6v-flash
          contextWindow: 131072
          maxTokens: 4096
          input: [text, image]
"@
  if ($DryRun) { Write-Host "  [dry-run] append llm-pi-ai block to $settingsFile" }
  else { [System.IO.File]::AppendAllText($settingsFile, $block, (New-Object System.Text.UTF8Encoding($false))) }
} else {
  Write-Host "llm-pi-ai already present in settings.yaml - leaving it untouched"
}

# ---------------------------------------------------------------- AGENTS.md
$agentsFile = "$env:USERPROFILE\.dsh\AGENTS.md"
if (-not (Test-Path $agentsFile)) {
  Write-Host "Creating AGENTS.md"
  $agents = @"
# You are $TextModelId. You are not multimodal.

If an image appears in your context already described in words, nothing switched
you to a vision model. A local proxy intercepts images, has a vision model
describe them, and replaces them with [Image: ...] text before they reach you.

There is also an analyze_image tool for image files on disk: you pass a path,
it returns a text description the same way. Either way you are reading words,
not pixels.

Say "the description indicates...", not "I can see...". You cannot verify
pixels. The describer is small and unreliable on small text, so flag
uncertainty rather than asserting fine detail.
"@
  if ($DryRun) { Write-Host "  [dry-run] write $agentsFile" }
  else { Write-FileUtf8 $agentsFile $agents }
}

# ---------------------------------------------------------------- autostart
if ($Autostart) {
  $py = (Get-Command python | Select-Object -First 1).Source
  $startup = [Environment]::GetFolderPath("Startup")
  $vbsDest = Join-Path $startup "vision-proxy.vbs"
  Write-Host "Installing logon autostart: $vbsDest"
  if ($DryRun) {
    Write-Host "  [dry-run] render autostart template and write $vbsDest"
  } else {
    $tmpl = [System.IO.File]::ReadAllText((Join-Path $packageRoot "autostart\vision-proxy.vbs.template"))
    $shimPath = Join-Path $packageRoot "shim\vision_shim.py"
    $vbs = $tmpl.Replace("<PYTHON_PATH>", $py.Replace("\", "/"))
      .Replace("<SHIM_PATH>", $shimPath.Replace("\", "/"))
      .Replace("<UPSTREAM>", $Upstream)
      .Replace("<VISION_URL>", $VisionUrl)
      .Replace("<VISION_MODEL>", $VisionModel)
    Write-FileUtf8 $vbsDest $vbs
  }
}

# ---------------------------------------------------------------- summary
Write-Host ""
Write-Host "===== done ====="
Write-Host "1. Start the proxy (or reboot / logon if autostart was enabled):"
Write-Host "   python `"$(Join-Path $packageRoot 'shim\vision_shim.py')`" --port 8900 --upstream $Upstream --vision-url $VisionUrl --vision-model $VisionModel"
Write-Host "2. Restart dsh web, then pick 'Vision Bridge' in the model selector."
Write-Host "3. Run the acceptance suite:"
Write-Host "   powershell -ExecutionPolicy Bypass -File `"$(Join-Path $packageRoot 'scripts\verify.ps1')`""
Write-Host ""
Write-Host "Note: make sure $ApiKeyEnv (and ZHIPU_API_KEY for the Zhipu entry) exist,"
Write-Host "e.g. in $env:USERPROFILE\.dsh\.credentials.yaml"
