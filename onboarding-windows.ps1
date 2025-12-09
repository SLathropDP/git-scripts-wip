<#
.SYNOPSIS
  Non-admin Windows onboarding for snippet mirroring (Pandoc + Node).

.DESCRIPTION
  - Installs Pandoc locally for the current user using the official ZIP release.
  - Installs Node.js locally for the current user using the official ZIP release.
  - Adds both install directories to the *user* PATH and current session PATH.
  - Verifies that "pandoc" and "node" are available.
  - Does NOT run any snippet generation scripts; it only prepares the environment.

.USAGE
  From the repo root...
  
    in Git Bash:

      powershell.exe -ExecutionPolicy Bypass -File scripts/onboarding-windows.ps1

    in cmd.exe:

      powershell.exe -ExecutionPolicy Bypass -File scripts\onboarding-windows.ps1

  Optional parameters:

      -PandocVersion "2.14.0.3"
      -PandocInstallDir "C:\Users\<user>\Tools\pandoc"
      -NodeVersion "22.19.1"
      -NodeInstallDir "C:\Users\<user>\Tools\node"
      -SkipPandocInstall
      -SkipNodeInstall
      -SkipVerification
#>

param(
  [string]$PandocVersion = "2.14.0.3",
  [string]$PandocInstallDir = "$env:USERPROFILE\Tools\pandoc",
  [string]$NodeVersion = "22.19.1",
  [string]$NodeInstallDir = "$env:USERPROFILE\Tools\node",
  [switch]$SkipPandocInstall,
  [switch]$SkipNodeInstall,
  [switch]$SkipVerification
)

function Write-Info($msg)  { Write-Host $msg -ForegroundColor Cyan }
function Write-Warn($msg)  { Write-Host $msg -ForegroundColor Yellow }
function Write-ErrorMsg($msg) { Write-Host $msg -ForegroundColor Red }

function Test-CommandExists($name) {
  $cmd = Get-Command $name -ErrorAction SilentlyContinue
  return $null -ne $cmd
}

function Ensure-Directory($path) {
  if (-not (Test-Path $path)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
  }
}

function Add-UserPathDirectory($dir) {
  $fullDir = [System.IO.Path]::GetFullPath($dir)

  # Persist to User PATH
  $currentUserPath = [Environment]::GetEnvironmentVariable("PATH","User")
  $userDirs = if ($currentUserPath) { $currentUserPath -split ';' } else { @() }

  if (-not ($userDirs -contains $fullDir)) {
    $newUserPath = if ($currentUserPath) {
      "$currentUserPath;$fullDir"
    } else {
      $fullDir
    }
    [Environment]::SetEnvironmentVariable("PATH",$newUserPath,"User")
    Write-Info "Added to user PATH: $fullDir"
  }

  # Update current session PATH immediately
  if (-not (($env:PATH -split ';') -contains $fullDir)) {
    $env:PATH = "$fullDir;$env:PATH"
    Write-Info "Added to session PATH: $fullDir"
  }
}

function Install-PandocFromZip {
  param([string]$Version,[string]$TargetDir)

  if (Test-CommandExists 'pandoc') {
    Write-Info "pandoc is already installed and available on PATH."
    return
  }

  Write-Info "Installing Pandoc $Version (non-admin)..."
  Ensure-Directory $TargetDir

  $zip = "pandoc-$Version-windows-x86_64.zip"
  $url = "https://github.com/jgm/pandoc/releases/download/$Version/$zip"
  $tmp = Join-Path $env:TEMP "pandoc-$Version.zip"
  $tmpExtract = Join-Path $env:TEMP "pandoc-$Version-extract"

  Write-Info "Downloading Pandoc ZIP..."
  Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing

  Write-Info "Extracting..."
  if (Test-Path $tmpExtract) { Remove-Item $tmpExtract -Recurse -Force }
  Expand-Archive -Path $tmp -DestinationPath $tmpExtract -Force

  $nested = Join-Path $tmpExtract "pandoc-$Version"
  if (-not (Test-Path $nested)) { $nested = $tmpExtract }

  Write-Info "Copying Pandoc files to $TargetDir ..."
  Get-ChildItem $nested | ForEach-Object {
    Copy-Item $_.FullName -Destination $TargetDir -Recurse -Force
  }

  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  Remove-Item $tmpExtract -Recurse -Force -ErrorAction SilentlyContinue

  Add-UserPathDirectory $TargetDir

  Write-Info "Pandoc installation complete."
}

function Install-NodeFromZip {
  param([string]$Version,[string]$TargetDir)

  if (Test-CommandExists 'node') {
    Write-Info "node is already installed and available on PATH."
    return
  }

  Write-Info "Installing Node.js $Version (non-admin)..."
  Ensure-Directory $TargetDir

  $zip = "node-v$Version-win-x64.zip"
  $url = "https://nodejs.org/dist/v$Version/$zip"
  $tmp = Join-Path $env:TEMP "node-$Version.zip"
  $tmpExtract = Join-Path $env:TEMP "node-$Version-extract"

  Write-Info "Downloading Node.js ZIP..."
  Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing

  Write-Info "Extracting..."
  if (Test-Path $tmpExtract) { Remove-Item $tmpExtract -Recurse -Force }
  Expand-Archive -Path $tmp -DestinationPath $tmpExtract -Force

  $nested = Join-Path $tmpExtract "node-v$Version-win-x64"
  if (-not (Test-Path $nested)) { $nested = $tmpExtract }

  Write-Info "Copying Node.js files to $TargetDir ..."
  Get-ChildItem $nested | ForEach-Object {
    Copy-Item $_.FullName -Destination $TargetDir -Recurse -Force
  }

  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  Remove-Item $tmpExtract -Recurse -Force -ErrorAction SilentlyContinue

  Add-UserPathDirectory $TargetDir

  Write-Info "Node.js installation complete."
}

function Verify-Toolchain {
  Write-Info "Verifying toolchain (node + pandoc)..."

  if (-not (Test-CommandExists 'node')) {
    Write-ErrorMsg "node not found on PATH. Please ensure Node.js is installed correctly."
    return $false
  }

  if (-not (Test-CommandExists 'pandoc')) {
    Write-ErrorMsg "pandoc not found on PATH. Please ensure Pandoc is installed correctly."
    return $false
  }

  Write-Info "node:   $(node --version)"
  Write-Info "pandoc: $(pandoc --version | Select-String -Pattern 'pandoc ' | Select-Object -First 1)"
  return $true
}

# --- MAIN --------------------------------------------------------

Write-Info "=== Windows onboarding for snippet mirroring (non-admin) ==="
Write-Info "Repository: $(Get-Location)"

if (-not $SkipNodeInstall) {
  Install-NodeFromZip -Version $NodeVersion -TargetDir $NodeInstallDir
} else {
  Write-Info "Skipping Node.js installation."
}

if (-not $SkipPandocInstall) {
  Install-PandocFromZip -Version $PandocVersion -TargetDir $PandocInstallDir
} else {
  Write-Info "Skipping Pandoc installation."
}

if (-not $SkipVerification) {
  if (-not (Verify-Toolchain)) {
    Write-ErrorMsg "Onboarding failed; see errors above."
    exit 1
  }
} else {
  Write-Info "Skipping verification."
}

Write-Info "Onboarding complete. If PATH was modified, this session already sees it; new terminals will as well."
