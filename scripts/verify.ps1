# dsh-vision-bridge acceptance suite
#   T1 eyes:  local VLM describes a real solid-colour PNG
#   T2 proxy: vision_shim rewrites image blocks to text before the brain
#   T3 tool:  analyze_image plugin executes against the real VLM
# Exit code 0 = all passed.

param(
  [string]$OllamaBase = "http://127.0.0.1:11434/v1",
  [string]$VisionModel = "qwen2.5vl:3b",
  [string]$ShimPy = "",
  [string]$PluginIndex = "",
  [int]$StubPort = 8911,
  [int]$ShimPort = 8900
)

$ErrorActionPreference = "Stop"
if (-not $ShimPy) { $ShimPy = Join-Path $PSScriptRoot "..\shim\vision_shim.py" }
if (-not $PluginIndex) {
  $candidates = @(
    "$env:USERPROFILE\.dsh\plugins\dsh-vision-bridge\index.js",
    "$env:USERPROFILE\.dsh\plugins\vision\index.js"
  )
  $PluginIndex = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $PluginIndex) {
    $PluginIndex = Join-Path $PSScriptRoot "..\plugin\vision\index.js"
  }
}

$scriptDir = $PSScriptRoot
$work = Join-Path $env:TEMP "dsh-vision-bridge-verify"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$png = Join-Path $work "solid-red.png"
$record = Join-Path $work "stub-request.json"
$shimOut = Join-Path $work "shim-out.log"
$shimErr = Join-Path $work "shim-err.log"
$stubOut = Join-Path $work "stub-out.log"
$stubErr = Join-Path $work "stub-err.log"

$passed = 0
$failed = 0

function Step([string]$name, [scriptblock]$body) {
  Write-Host ""
  Write-Host "===== $name =====" -ForegroundColor Cyan
  try {
    & $body
    Write-Host "PASS: $name" -ForegroundColor Green
    $script:passed++
  } catch {
    Write-Host "FAIL: $name -> $($_.Exception.Message)" -ForegroundColor Red
    $script:failed++
  }
}

function Assert([bool]$cond, [string]$msg) {
  if (-not $cond) { throw $msg }
}

function Wait-Http([string]$url, [int]$seconds = 20) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $deadline) {
    try {
      return Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 3
    } catch {
      Start-Sleep -Milliseconds 500
    }
  }
  throw "timeout waiting for $url"
}

function Stop-Tree([int]$procId) {
  Get-Process -Id $procId -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
}

Step "Prerequisites" {
  Assert (Test-Path $ShimPy) "vision_shim.py not found: $ShimPy"
  Assert (Test-Path $PluginIndex) "plugin not found: $PluginIndex"
  Assert (Test-Path (Join-Path $scriptDir "upstream-stub.mjs")) "upstream-stub.mjs missing"
  Assert (Test-Path (Join-Path $scriptDir "tool-mount-test.mjs")) "tool-mount-test.mjs missing"
  $models = Invoke-RestMethod -Uri "$OllamaBase/models" -TimeoutSec 5
  Assert ($models.data.id -contains $VisionModel) "Ollama has no model $VisionModel (run: ollama pull $VisionModel)"
  Write-Host "  Ollama OK, model $VisionModel ready"
}

Step "T1 Eyes: direct VLM call" {
  Add-Type -AssemblyName System.Drawing
  $bmp = New-Object System.Drawing.Bitmap 64, 64
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.Clear([System.Drawing.Color]::Red)
  $g.Dispose()
  $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()

  $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($png))
  $body = @{
    model     = $VisionModel
    messages  = @(@{
      role    = "user"
      content = @(
        @{ type = "text"; text = "What colour is this image? Answer with one word." },
        @{ type = "image_url"; image_url = @{ url = "data:image/png;base64,$b64" } }
      )
    })
    max_tokens = 64
  } | ConvertTo-Json -Depth 8

  $resp = Invoke-RestMethod -Uri "$OllamaBase/chat/completions" -Method Post `
    -ContentType "application/json" -Body $body -TimeoutSec 90
  $text = $resp.choices[0].message.content
  Assert ($text -and $text.Trim()) "vision model returned empty content"
  Write-Host "  vision model said: $($text.Trim())"
}

Step "T2 Proxy: attachment rewrite" {
  Remove-Item -LiteralPath $record -Force -ErrorAction SilentlyContinue
  $env:STUB_PORT = "$StubPort"
  $env:RECORD_PATH = $record
  $stub = Start-Process -FilePath "node" `
    -ArgumentList (Join-Path $scriptDir "upstream-stub.mjs") `
    -WindowStyle Hidden -RedirectStandardOutput $stubOut -RedirectStandardError $stubErr -PassThru
  try {
    Wait-Http "http://127.0.0.1:$StubPort/v1/models" | Out-Null

    $shim = Start-Process -FilePath "python" `
      -ArgumentList @($ShimPy, "--port", "$ShimPort", "--upstream", "http://127.0.0.1:$StubPort", "--vision-url", "$OllamaBase/chat/completions", "--vision-model", $VisionModel) `
      -WindowStyle Hidden -RedirectStandardOutput $shimOut -RedirectStandardError $shimErr -PassThru
    try {
      $health = Invoke-RestMethod -Uri "http://127.0.0.1:$ShimPort/health" -TimeoutSec 20
      Assert $health.upstream_ok "shim /health: upstream unreachable"
      Assert $health.vision_ok "shim /health: vision unreachable"

      $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($png))
      $payload = @{
        model    = "stub-text-model"
        messages = @(@{
          role    = "user"
          content = @(
            @{ type = "text"; text = "What colour is this image?" },
            @{ type = "image_url"; image_url = @{ url = "data:image/png;base64,$b64" } }
          )
        })
        stream   = $false
      } | ConvertTo-Json -Depth 8

      $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$ShimPort/v1/chat/completions" `
        -Method Post -ContentType "application/json" -Body $payload -TimeoutSec 90
      Assert ($resp.choices[0].message.content -eq "stub upstream reply") "shim did not pass through upstream reply"

      $sent = Get-Content $record -Raw
      Assert ($sent -match '\[Image: ') "upstream request has no [Image: ...] rewrite"
      Assert ($sent -notmatch 'image_url') "upstream received an unrewritten image_url block"
      Write-Host "  upstream got text rewrite: $(([regex]::Match($sent, '\[Image: [^\]]*\]')).Value)"
    } finally {
      Stop-Tree $shim.Id
    }
  } finally {
    Stop-Tree $stub.Id
  }
}

Step "T3 Tool: analyze_image real call" {
  $env:VISION_PLUGIN = $PluginIndex
  $env:VISION_FAST_URL = "$OllamaBase/chat/completions"
  $env:VISION_FAST_MODEL = $VisionModel
  $out = & node (Join-Path $scriptDir "tool-mount-test.mjs") $png 2>&1
  Assert ($LASTEXITCODE -eq 0) "analyze_image mount/call failed: $out"
  Assert (($out -join "`n") -match 'TOOL OK') "tool did not return success marker: $out"
  Write-Host "  $((($out -join ' ') -replace '.*RESULT: ', 'RESULT: '))"
}

Write-Host ""
Write-Host "=================== SUMMARY ===================" -ForegroundColor Cyan
Write-Host "passed: $passed / $($passed + $failed)"
if ($failed -gt 0) {
  Write-Host "FAILED - vision bridge cannot be frozen" -ForegroundColor Red
  exit 1
}
Write-Host "ALL PASSED - vision bridge is frozen" -ForegroundColor Green
