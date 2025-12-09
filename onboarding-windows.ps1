<#
.SYNOPSIS
  Windows onboarding (Pandoc + Node).

.DESCRIPTION
  - Installs Pandoc locally using the official ZIP release.
  - Installs Node.js locally using the official ZIP release.
  - Adds both install directories to User PATH.
  - Uses hard-coded proxy settings for Invoke-WebRequest downloads.
#>

param(
  [string]$PandocVersion = "2.14.0",
  [string]$PandocInstallDir = "$env:USERPROFILE\Tools\pandoc",
  [string]$NodeVersion = "22.19.1",
  [string]$NodeInstallDir = "$env:USERPROFILE\Tools\node",
  [switch]$SkipPandocInstall,
  [switch]$SkipNodeInstall,
  [switch]$SkipVerification
)

###############################################################################
# NETWORK PROXY SETTINGS
###############################################################################
$HTTP_PROXY  = ""
$HTTPS_PROXY = ""
###############################################################################

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

  # Prefer HTTPS_PROXY if URL is HTTPS
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
# Pandoc Installation
###############################################################################
function Install-PandocFromZip {
  param([string]$Version,[string]$TargetDir)

  if (Test-CommandExists 'pandoc') {
    Write-Info "pandoc already installed: $(pandoc --version | Select-Object -First 1)"
    return
  }

  Write-Info "Installing Pandoc $Version (non-admin)..."
  Ensure-Directory $TargetDir

  $zip = "pandoc-$Version-windows-x86_64.zip"
  $url = "https://github.com/jgm/pandoc/releases/download/$Version/$zip"
  $tmp = Join-Path $env:TEMP "pandoc-$Version.zip"
  $tmpExtract = Join-Path $env:TEMP "pandoc-$Version-extract"

  Write-Info "Downloading Pandoc ZIP..."
  Invoke-WebRequestWithProxy -Url $url -OutFile $tmp

  Write-Info "Extracting..."
  if (Test-Path $tmpExtract) { Remove-Item $tmpExtract -Recurse -Force }
  Expand-Archive -Path $tmp -DestinationPath $tmpExtract -Force

  $nested = Join-Path $tmpExtract "pandoc-$Version"
  if (-not (Test-Path $nested)) { $ne
