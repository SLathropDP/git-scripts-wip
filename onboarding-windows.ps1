<#
.SYNOPSIS
  Windows onboarding (Pandoc + Node).

.DESCRIPTION
  - Installs Pandoc locally using the official ZIP release (if not already present)
  - Installs Node.js locally using the official ZIP release (if not already present)
  - Adds both install directories to User PATH
  - Uses hard-coded proxy settings for Invoke-WebRequest downloads
  - Skips downloads if any version of node/pandoc is already installed
#>

param(
  [string]$PandocVersion    = "2.14.0.3",
  [string]$PandocInstallDir = "$env:USERPROFILE\Tools\pandoc",
  [string]$NodeVersion      = "22.20.0",
  [string]$NodeInstallDir   = "$env:USERPROFILE\Tools\node",
  [switch]$SkipPandocInstall,
  [switch]$SkipNodeInstall,
  [switch]$SkipVerification
)

###############################################################################
# HARD-CODED NETWORK PROXY SETTINGS
###############################################################################
# Leave them empty if you do NOT want proxy usage
###############################################################################
$HTTP_PROXY  = ""
$HTTPS_PROXY = ""
###############################################################################

function Write-Info($msg)      { Write-Host $msg -ForegroundColor Cyan }
function Write-Warn($msg)      { Write-Host $msg -ForegroundColor Yellow }
function Write-ErrorMsg($msg)  { Write-Host $msg -ForegroundColor Red }

function Test-CommandExists($name) {
  $cmd = Get-Command $name -ErrorAction SilentlyContinue
  return $null -ne $cmd
}

function Ensure-Directory($path) {
  if (-not (Test-Path $path)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
  }
}

###############################################################################
# Download helper with proxy awareness
###############################################################################
function Invoke-WebRequestWithProxy {
  param(
    [string]$Url,
    [string]$OutFile
  )

  $params = @{
    Uri            = $Url
    OutFile        = $OutFile
    UseBasicParsing = $true
  }

  # Prefer HTTPS proxy if URL is HTTPS
  if ($Url -match '^https://' -and $HTTPS_PROXY) {
    Write-Info "Using HTTPS proxy: $HTTPS_PROXY"
    $params.Proxy = $HTTPS_PROXY
    $params.ProxyUseDefaultCredentials = $true
  }
  elseif ($HTTP_PROXY) {
    Write-Info "Using HTTP proxy: $HTTP_PROXY"
    $params.Proxy = $HTTP_PROXY
    $params.ProxyUseDefaultCredentials = $true
  }

  Invoke-WebRequest @params
}
###############################################################################

function Add-UserPathDirectory($dir) {
  $fullDir = [System.IO.Path]::GetFullPath($dir)

  # Persist to User PATH
  $currentUserPath = [Environment]::GetEnvironmentVariable("PATH","User")
  $userDirs = if ($currentUserPath) { $currentUserPath -split ';' } else { @() }

  if (-not ($userDirs -contains $fullDir)) {
    $newUserPath = if ($currentUserPath) { "$currentUserPath;$fullDir" } else { $fullDir }
    [Environment]::SetEnvironmentVariable("PATH",$newUserPath,"User")
    Write-Info "Added to user PATH: $fullDir"
  }

  # Update current session PATH
  if (-not (($env:PATH -split ';') -contains $fullDir)) {
    $env:PATH = "$fullDir;$env:PATH"
    Write-Info "Added to session PATH: $fullDir"
  }
}

###############################################################################
# Pandoc Installation (assumes NOT already installed when called)
###############################################################################
function Install-PandocFromZip {
  param([string]$Version,[string]$TargetDir)

  Write-Info "Installing Pandoc $Version..."
  Ensure-Directory $TargetDir

  $zip        = "pandoc-$Version-windows-x86_64.zip"
  $url        = "https://github.com/jgm/pandoc/releases/download/$Version/$zip"
  $tmp        = Join-Path $env:TEMP "pandoc-$Version.zip"
  $tmpExtract = Join-Path $env:TEMP "pandoc-$Version-extract"

  Write-Info "Downloading Pandoc ZIP..."
  Invoke-WebRequestWithProxy -Url $url -OutFile $tmp

  Write-Info "Extracting Pandoc ZIP..."
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

###############################################################################
# Node Installation (assumes NOT already installed when called)
###############################################################################
function Install-NodeFromZip {
  param([string]$Version,[string]$TargetDir)

  Write-Info "Installing Node.js $Version..."
  Ensure-Directory $TargetDir

  $zip        = "node-v$Version-win-x64.zip"
  $url        = "https://nodejs.org/dist/v$Version/$zip"
  $tmp        = Join-Path $env:TEMP "node-$Version.zip"
  $tmpExtract = Join-Path $env:TEMP "node-$Version-extract"

  Write-Info "Downloading Node.js ZIP..."
  Invoke-WebRequestWithProxy -Url $url -OutFile $tmp

  Write-Info "Extracting Node.js ZIP..."
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

###############################################################################
# Toolchain Verification
###############################################################################
function Verify-Toolchain {
  Write-Info "Verifying node + pandoc availability..."

  if (-not (Test-CommandExists 'node')) {
    Write-ErrorMsg "node not found on PATH."
    return $false
  }

  if (-not (Test-CommandExists 'pandoc')) {
    Write-ErrorMsg "pandoc not found on PATH."
    return $false
  }

  Write-Info "node:   $(node --version)"
  Write-Info "pandoc: $(pandoc --version | Select-Object -First 1)"
  return $true
}

###############################################################################
# MAIN SCRIPT LOGIC
###############################################################################

Write-Info "=== Windows onboarding ==="
Write-Info "Repository: $(Get-Location)"

# --- Node.js handling --------------------------------------------------------
if ($SkipNodeInstall) {
  Write-Info "Skipping Node.js installation (SkipNodeInstall specified)."
} elseif (Test-CommandExists 'node') {
  Write-Info "Node.js is already installed: $(node --version)"
} else {
  Install-NodeFromZip -Version $NodeVersion -TargetDir $NodeInstallDir
}

# --- Pandoc handling ---------------------------------------------------------
if ($SkipPandocInstall) {
  Write-Info "Skipping Pandoc installation (SkipPandocInstall specified)."
} elseif (Test-CommandExists 'pandoc') {
  Write-Info "Pandoc is already installed: $(pandoc --version | Select-Object -First 1)"
} else {
  Install-PandocFromZip -Version $PandocVersion -TargetDir $PandocInstallDir
}

# --- Final verification ------------------------------------------------------
if (-not $SkipVerification) {
  if (-not (Verify-Toolchain)) {
    Write-ErrorMsg "Onboarding failed."
    exit 1
  }
} else {
  Write-Info "Skipping verification step (SkipVerification specified)."
}

Write-Info "Onboarding complete. If PATH was modified, this session already sees it; new terminals will as well."
