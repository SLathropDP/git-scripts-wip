<#
onboarding-windows-cleanup.ps1

Simple cleanup script for the Windows onboarding artifacts:

- Looks for Node.js installed under $nodeInstallDir
- Looks for Pandoc installed under $pandocInstallDir
- If found, prints the location and asks for confirmation before:
    - Deleting the install folder
    - Removing that folder from the user's PATH (registry + current session)

Usage (from PowerShell):

    .\scripts\onboarding-windows-cleanup.ps1
#>

$nodeInstallDir   = Join-Path $env:USERPROFILE "Tools\node"
$pandocInstallDir = Join-Path $env:USERPROFILE "Tools\pandoc"

# $nodeInstallDir   = "C:\PROGRAMS\AUTHORIZED\node"
# $pandocInstallDir = "C:\PROGRAMS\AUTHORIZED\pandoc"

function Write-Info($msg) { Write-Host $msg -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host $msg -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host $msg -ForegroundColor Red }

function Remove-FromUserPath {
  param(
    [Parameter(Mandatory = $true)][string]$Dir
  )

  $normalized = $Dir.TrimEnd('\')

  # Update user-level PATH (registry)
  $userPath = [Environment]::GetEnvironmentVariable("PATH","User")
  if ($userPath) {
    $segments = $userPath -split ';'
    $filtered = $segments | Where-Object { $_.TrimEnd('\') -ne $normalized -and $_ -ne "" }
    $newUserPath = ($filtered -join ';')
    [Environment]::SetEnvironmentVariable("PATH",$newUserPath,"User")
  }

  # Update current session PATH
  $sessionPath = $env:PATH
  if ($sessionPath) {
    $segments = $sessionPath -split ';'
    $filtered = $segments | Where-Object { $_.TrimEnd('\') -ne $normalized -and $_ -ne "" }
    $env:PATH = ($filtered -join ';')
  }
}

function Confirm-And-Remove-Install {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$InstallDir,
    [Parameter(Mandatory = $true)][string]$ExeName
  )

  $exePath = Join-Path $InstallDir $ExeName

  if (-not (Test-Path $exePath)) {
    return
  }

  Write-Info ""
  Write-Info "$Name installation detected at:"
  Write-Host "    $InstallDir"
  $answer = Read-Host "Do you want to remove this $Name installation and its PATH entry? [y/N]"

  if ($answer -notmatch '^[Yy]') {
    Write-Info "Skipping removal of $Name."
    return
  }

  Write-Info "Removing $Name install directory..."
  try {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction Stop
    Write-Info "$Name files removed."
  }
  catch {
    Write-Err ("Failed to remove {0}: {1}" -f $InstallDir, $_.Exception.Message)
  }

  Write-Info "Removing $InstallDir from PATH..."
  Remove-FromUserPath -Dir $InstallDir
  Write-Info "$Name PATH entry removed (user-level and current session)."
}

Write-Info "=== Windows onboarding cleanup ==="

Confirm-And-Remove-Install -Name "Node.js" -InstallDir $nodeInstallDir -ExeName "node.exe"
Confirm-And-Remove-Install -Name "Pandoc"  -InstallDir $pandocInstallDir -ExeName "pandoc.exe"

Write-Info ""
Write-Info "Cleanup script finished."
Write-Info "If you removed Node.js or Pandoc, you may want to open a new terminal or run:"
Write-Info "    node --version"
Write-Info "    pandoc --version"
Write-Info "to confirm they are gone from your PATH."
