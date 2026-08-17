# dsh-vision-bridge uninstaller (Windows / PowerShell)
# Removes the plugin, profile wiring, standard-vision default preset and autostart VBS.
#
# Usage: powershell -ExecutionPolicy Bypass -File uninstall.ps1 [-KillShim] [-DryRun]

param(
  [switch]$KillShim,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$profileDir = "$env:USERPROFILE\.dsh\profiles\web"
$profilePkg = Join-Path $profileDir "package.json"
$patchFile = Join-Path $profileDir "cordis.patch.yml"
$settingsFile = "$env:USERPROFILE\.dsh\settings.yaml"
$pluginDest = "$env:USERPROFILE\.dsh\plugins\dsh-vision-bridge"
$startup = [Environment]::GetFolderPath("Startup")
$vbsDest = Join-Path $startup "vision-proxy.vbs"

function Remove-Line([string]$path, [string]$needle) {
  if (-not (Test-Path $path)) { return }
  $text = [System.IO.File]::ReadAllText($path)
  if ($text -notmatch $needle) { return }
  $lines = [System.Collections.ArrayList]::new()
  $skip = $false
  foreach ($line in $text -split "`r?`n") {
    if ($skip) {
      if ($line -match '^\s*-\s*id:') { $skip = $false }
      continue
    }
    if ($line -match $needle) {
      $skip = $true
      continue
    }
    [void]$lines.Add($line)
  }
  $out = ($lines -join "`n").TrimEnd() + "`n"
  if ($DryRun) { Write-Host "  [dry-run] rewrite $path (remove $needle)" }
  else { [System.IO.File]::WriteAllText($path, $out, (New-Object System.Text.UTF8Encoding($false))) }
}

Write-Host "===== dsh-vision-bridge uninstall ====="

# profile dependency + patch row
if (Test-Path $profilePkg) {
  $text = [System.IO.File]::ReadAllText($profilePkg)
  if ($text -match 'dsh-vision-bridge') {
    Write-Host "Removing dsh-vision-bridge from profile package.json"
    if (-not $DryRun) {
      $pkg = Get-Content $profilePkg -Raw | ConvertFrom-Json
      $pkg.dependencies.PSObject.Properties.Remove("dsh-vision-bridge")
      $json = $pkg | ConvertTo-Json -Depth 10
      [System.IO.File]::WriteAllText($profilePkg, $json, (New-Object System.Text.UTF8Encoding($false)))
    } else {
      Write-Host "  [dry-run] remove dependency from $profilePkg"
    }
  }
}
Remove-Line $patchFile "name: 'dsh-vision-bridge'"

# plugin folder
if (Test-Path $pluginDest) {
  Write-Host "Removing $pluginDest"
  if (-not $DryRun) { Remove-Item -LiteralPath $pluginDest -Recurse -Force }
  else { Write-Host "  [dry-run] remove $pluginDest" }
}

# default preset rollback
if (Test-Path $settingsFile) {
  $settingsText = [System.IO.File]::ReadAllText($settingsFile)
  if ($settingsText -match 'default: standard-vision') {
    Write-Host "Resetting default agent preset to standard"
    if ($DryRun) { Write-Host "  [dry-run] rewrite $settingsFile" }
    else {
      $settingsText = $settingsText -replace '(?ms)^agent-presets:\s*default:\s*standard-vision\s*$', "agent-presets:`n  default: standard"
      [System.IO.File]::WriteAllText($settingsFile, $settingsText, (New-Object System.Text.UTF8Encoding($false)))
    }
  }
}

# autostart
if (Test-Path $vbsDest) {
  Write-Host "Removing autostart $vbsDest"
  if (-not $DryRun) { Remove-Item -LiteralPath $vbsDest -Force }
  else { Write-Host "  [dry-run] remove $vbsDest" }
}

# optional: stop the proxy
if ($KillShim) {
  Write-Host "Stopping the vision proxy (port 8900)"
  if (-not $DryRun) {
    Get-NetTCPConnection -State Listen -LocalPort 8900 -ErrorAction SilentlyContinue |
      ForEach-Object { Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue | Stop-Process -Force }
  }
}

Write-Host "===== uninstall done ====="
