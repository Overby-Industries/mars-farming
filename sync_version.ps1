# Keeps the version number of the exported game in step with itch.io: "0.1.N", where N is the itch.io build number (the number
# shown on the public page and returned by `butler status`). That makes butler the one source of truth for what is live; there is
# no separately kept VERSION file to drift away from it. Same idea as the Asteroid Miner's sync_version.ps1, for the one place
# this repository quotes a version: the exe's file and product version in godot\export_presets.cfg (what Windows shows under
# Properties > Details).
#
# deploy_to_itch.ps1 runs it after a successful push, with the build number butler reports. By hand:
#   powershell -File sync_version.ps1 -BuildNumber 12
#
# The patterns are narrow, anchored to the key they replace, so nothing else that happens to read like a version is touched.

param(
    [int]$BuildNumber = 0
)

$ErrorActionPreference = "Stop"
$RepoRoot = $PSScriptRoot
$Version = "0.1.$BuildNumber"

function Update-InFile {
    param([string]$Path, [string]$Pattern, [string]$Replacement, [string]$Label)
    $full = Join-Path $RepoRoot $Path
    $content = Get-Content -Raw -Path $full
    $updated = $content -replace $Pattern, $Replacement
    if ($updated -eq $content) {
        Write-Host "  (no change) $Label"
        return
    }
    Set-Content -Path $full -Value $updated -NoNewline
    Write-Host "  updated: $Label"
}

if ($BuildNumber -le 0) {
    Write-Host "No -BuildNumber given: nothing to sync."
    exit 0
}

Write-Host "Syncing the version to $Version (itch.io build #$BuildNumber)..."

# file_version wants the traditional four-part Windows form.
Update-InFile "godot/export_presets.cfg" `
    'application/file_version="[^"]*"' `
    "application/file_version=`"$Version.0`"" `
    "export_presets.cfg (file_version)"
Update-InFile "godot/export_presets.cfg" `
    'application/product_version="[^"]*"' `
    "application/product_version=`"$Version`"" `
    "export_presets.cfg (product_version)"

Write-Host "Version sync done."
