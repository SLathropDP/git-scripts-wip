<#
.SYNOPSIS
  Windows onboarding (Node + Pandoc)

.DESCRIPTION
  - Re-runnable script
  - Installs Node.js locally using the official ZIP release (if not already present)
  - Installs Pandoc locally using the official ZIP release (if not already present)
  - Adds both install directories to User PATH
  - Persists HTTP_PROXY and HTTPS_PROXY as user-level environment variables
  - Downloads the Nexus CA cert into the user's profile
  - Skips download for anything that is already installed
  - Configures npm registry and cafile once Node/npm are available
#>

param(
  [string]$PandocVersion    = "2.14.0.3",
  [string]$PandocInstallDir = "$env:USERPROFILE\Tools\pandoc",
  [string]$NodeVersion      = "22.20.1",
  [string]$NodeInstallDir   = "$env:USERPROFILE\Tools\node",
  [switch]$SkipPandocInstall,
  [switch]$SkipNodeInstall,
  [switch]$SkipVerification
)

###############################################################################
# HARD-CODED NETWORK PROXY SETTINGS
###############################################################################
# These will be:
#   - used for all downloads in this script, AND
#   - saved as user-level environment variables (HTTP_PROXY/HTTPS_PROXY)
###############################################################################
$HTTP_PROXY  = ""
$HTTPS_PROXY = ""
###############################################################################

###############################################################################
# NPM NEXUS SETTINGS
###############################################################################
# These will be:
#   - used for downloading the cert, AND
#   - saved as npm config values
###############################################################################

# Nexus CA cert URL and destination within the user's profile
$NexusCertUrl  = "https://mynexus.org/repository/certs/trust-cert.pem"
$NexusCertPath = Join-Path $env:USERPROFILE "trust-cert.pem"  # adjust if desired

###############################################################################
# HELPER FUNCTIONS
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
# Persist proxy values as user-level environment variables + this session
###############################################################################
function Set-UserProxyEnvironment {
  param(
    [string]$HttpProxy,
    [string]$HttpsProxy
  )

  if ($HttpProxy) {
    [Environment]::SetEnvironmentVariable("HTTP_PROXY",$HttpProxy,"User")
    [Environment]::SetEnvironmentVariable("http_proxy",$HttpProxy,"User")
    $env:HTTP_PROXY  = $HttpProxy
    $env:http_proxy  = $HttpProxy
    Write-Info "Set user HTTP_PROXY=http_proxy."
  }

  if ($HttpsProxy) {
    [Environment]::SetEnvironmentVariable("HTTPS_PROXY",$HttpsProxy,"User")
    [Environment]::SetEnvironmentVariable("https_proxy",$HttpsProxy,"User")
    $env:HTTPS_PROXY = $HttpsProxy
    $env:https_proxy = $HttpsProxy
    Write-Info "Set user HTTPS_PROXY=https_proxy."
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
    Uri             = $Url
    OutFile         = $OutFile
    UseBasicParsing = $true
  }

  # Prefer HTTPS proxy if URL is HTTPS
  if ($Url -match '^https://' -and $HTTPS_PROXY) {
    Write-Info "Using HTTPS proxy for download."
    $params.Proxy = $HTTPS_PROXY
    $params.ProxyUseDefaultCredentials = $true
  }
  elseif ($HTTP_PROXY) {
    Write-Info "Using HTTP proxy for download."
    $params.Proxy = $HTTP_PROXY
    $params.ProxyUseDefaultCredentials = $true
  }

  Invoke-WebRequest @params
}

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
# Node Installation (assumes NOT already installed when called)
###############################################################################
function Install-NodeFromZip {
  param([string]$Version,[string]$TargetDir)

  Write-Info "Installing Node.js $Version (non-admin)..."
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
# Pandoc Installation (assumes NOT already installed when called)
###############################################################################
function Install-PandocFromZip {
  param([string]$Version,[string]$TargetDir)

  Write-Info "Installing Pandoc $Version (non-admin)..."
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
# Nexus CA cert download
###############################################################################
function Ensure-NexusCert {
  param(
    [string]$Url,
    [string]$DestPath
  )

  Write-Info "Ensuring Nexus CA certificate at: $DestPath"

  $destDir = Split-Path -Parent $DestPath
  if ($destDir -and -not (Test-Path $destDir)) {
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
  }

  Write-Info "Downloading Nexus CA cert from: $Url"
  Invoke-WebRequestWithProxy -Url $Url -OutFile $DestPath

  Write-Info "Nexus CA cert downloaded."
}

###############################################################################
# NPM configuration for Nexus
###############################################################################
function Configure-NpmForNexus {
  param(
    [string]$CertPath
  )

  if (-not (Test-CommandExists 'npm')) {
    Write-Warn "npm not found; skipping npm Nexus configuration."
    return
  }

  Write-Info "Configuring npm to use Nexus registry and CA file..."

  $registry = "https://nxrm.my.org/repository/npm-all"

  npm config set registry $registry
  npm config set cafile $CertPath

  Write-Info "npm registry set to: $registry"
  Write-Info "npm cafile set to: $CertPath"
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

# 1. Persist proxy variables if configured
Set-UserProxyEnvironment -HttpProxy $HTTP_PROXY -HttpsProxy $HTTPS_PROXY

# 2. Node.js handling
if ($SkipNodeInstall) {
  Write-Info "Skipping Node.js installation (SkipNodeInstall specified)."
} elseif (Test-CommandExists 'node') {
  Write-Info "Node.js is already installed: $(node --version)"
} else {
  Install-NodeFromZip -Version $NodeVersion -TargetDir $NodeInstallDir
}

# 3. Pandoc handling
if ($SkipPandocInstall) {
  Write-Info "Skipping Pandoc installation (SkipPandocInstall specified)."
} elseif (Test-CommandExists 'pandoc') {
  Write-Info "Pandoc is already installed: $(pandoc --version | Select-Object -First 1)"
} else {
  Install-PandocFromZip -Version $PandocVersion -TargetDir $PandocInstallDir
}

# 4. Nexus CA cert
Ensure-NexusCert -Url $NexusCertUrl -DestPath $NexusCertPath

# 5. NPM Nexus configuration (if Node/npm available)
if (Test-CommandExists 'node') {
  Configure-NpmForNexus -CertPath $NexusCertPath
} else {
  Write-Warn "Node.js not available; skipping npm Nexus configuration."
}

# 6. Final verification
if (-not $SkipVerification) {
  if (-not (Verify-Toolchain)) {
    Write-ErrorMsg "Onboarding failed."
    exit 1
  }
} else {
  Write-Info "Skipping verification step (SkipVerification specified)."
}

Write-Info "Onboarding completed. New PATH and proxy settings will apply to new shells."
