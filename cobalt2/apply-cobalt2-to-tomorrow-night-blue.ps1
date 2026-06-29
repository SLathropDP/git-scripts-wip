<#
.SYNOPSIS
    Re-skins the "Tomorrow Night Blue" VS Code theme with Cobalt2 colors.

.DESCRIPTION
    Loads Cobalt2 theme data and injects its UI colors and syntax token
    rules into the user's VS Code settings.json, scoped to
    "[Tomorrow Night Blue]" so other themes are unaffected.

    A timestamped backup of the existing settings.json is created before
    any changes are written.

.NOTES
    Run from any PowerShell prompt on Windows.
    Restart / reload VS Code after running to pick up the changes.
#>

param(
    [switch]$Undo
)

$settingsPath = Join-Path $env:APPDATA "Code\User\settings.json"
$themeDataPath = Join-Path $PSScriptRoot "cobalt2-data.ps1"
$themeScopeKey = "[Tomorrow Night Blue]"

# ── helpers ──────────────────────────────────────────────────────────────

function Read-SettingsJson([string]$Path) {
    if (-not (Test-Path $Path)) {
        Write-Error "File not found: $Path"
        exit 1
    }
    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path $Path).Path)
    $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $offset = 3
    }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes, $offset, $bytes.Length - $offset)
    return (ConvertFrom-Json -InputObject $text)
}

function Write-SettingsJson([string]$Path, $Object) {
    $Object | ConvertTo-Json -Depth 100 | Set-Content -Encoding UTF8 $Path
}

function Ensure-Property($obj, [string]$name) {
    if (-not ($obj.PSObject.Properties.Name -contains $name)) {
        $obj | Add-Member -NotePropertyName $name -NotePropertyValue ([PSCustomObject]@{})
    }
}

function Set-ScopedObject($parent, [string]$propName, [string]$scopeKey, $value) {
    Ensure-Property $parent $propName
    $section = $parent.$propName
    if ($section.PSObject.Properties.Name -contains $scopeKey) {
        $section.PSObject.Properties.Remove($scopeKey)
    }
    $section | Add-Member -NotePropertyName $scopeKey -NotePropertyValue $value
}

# ── undo mode ────────────────────────────────────────────────────────────

if ($Undo) {
    if (-not (Test-Path $settingsPath)) {
        Write-Host "No settings.json found at $settingsPath - nothing to undo."
        exit 0
    }
    $settings = Read-SettingsJson $settingsPath

    $changed = $false
    foreach ($section in @("workbench.colorCustomizations", "editor.tokenColorCustomizations", "editor.semanticTokenColorCustomizations")) {
        if ($settings.PSObject.Properties.Name -contains $section) {
            $obj = $settings.$section
            if ($obj.PSObject.Properties.Name -contains $themeScopeKey) {
                $obj.PSObject.Properties.Remove($themeScopeKey)
                $changed = $true
            }
        }
    }

    if ($changed) {
        $backup = "$settingsPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $settingsPath $backup
        Write-SettingsJson $settingsPath $settings
        Write-Host "Removed Cobalt2 overrides for $themeScopeKey."
        Write-Host "Backup saved to: $backup"
    } else {
        Write-Host "No Cobalt2 overrides found for $themeScopeKey - nothing to undo."
    }
    exit 0
}

# ── apply mode ───────────────────────────────────────────────────────────

if (-not (Test-Path $themeDataPath)) {
    Write-Error "Theme data file not found: $themeDataPath"
    exit 1
}
$cobalt = & $themeDataPath

# Build the color customizations object
$colorOverrides = [PSCustomObject]@{}
foreach ($key in $cobalt.colors.Keys) {
    $colorOverrides | Add-Member -NotePropertyName $key -NotePropertyValue $cobalt.colors[$key]
}

# Build the token color customizations (textMateRules)
$textMateRules = @()
foreach ($rule in $cobalt.tokenColors) {
    $entry = [PSCustomObject]@{}

    if ($rule.name) {
        $entry | Add-Member -NotePropertyName "name" -NotePropertyValue $rule.name
    }
    $entry | Add-Member -NotePropertyName "scope" -NotePropertyValue $rule.scope
    $entry | Add-Member -NotePropertyName "settings" -NotePropertyValue ([PSCustomObject]$rule.settings)
    $textMateRules += $entry
}

$tokenOverrides = [PSCustomObject]@{
    textMateRules = $textMateRules
}

# Build semantic token customizations
$semanticRules = [PSCustomObject]@{}
foreach ($key in $cobalt.semanticTokenColors.Keys) {
    $val = $cobalt.semanticTokenColors[$key]
    if ($val -is [hashtable]) {
        $val = [PSCustomObject]$val
    }
    $semanticRules | Add-Member -NotePropertyName $key -NotePropertyValue $val
}
$semanticOverrides = [PSCustomObject]@{
    rules = $semanticRules
}

# Read or create settings.json
if (Test-Path $settingsPath) {
    $backup = "$settingsPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $settingsPath $backup
    Write-Host "Backup saved to: $backup"
    $settings = Read-SettingsJson $settingsPath
} else {
    $dir = Split-Path $settingsPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $settings = [PSCustomObject]@{}
    Write-Host "Creating new settings.json at: $settingsPath"
}

# Inject the Cobalt2 overrides scoped to Tomorrow Night Blue
Set-ScopedObject $settings "workbench.colorCustomizations" $themeScopeKey $colorOverrides
Set-ScopedObject $settings "editor.tokenColorCustomizations" $themeScopeKey $tokenOverrides
Set-ScopedObject $settings "editor.semanticTokenColorCustomizations" $themeScopeKey $semanticOverrides

Write-SettingsJson $settingsPath $settings

Write-Host ""
Write-Host "Done! Cobalt2 colors applied to '$themeScopeKey'."
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Open VS Code"
Write-Host "  2. Ctrl+K Ctrl+T  ->  select 'Tomorrow Night Blue'"
Write-Host "  3. Enjoy Cobalt2 colors without installing the extension"
Write-Host ""
Write-Host "To revert:  .\apply-cobalt2-to-tomorrow-night-blue.ps1 -Undo"
