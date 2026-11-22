<#
One-command release: build the release GDExtension, export the Windows release build, smoke-test it, and push it to itch.io with
butler (which only uploads what changed, and makes the patches the itch.io app downloads). Page:
https://overby-industries.itch.io/mars-farming

Usage, from any folder:
    powershell -File deploy_to_itch.ps1                      # build, export, test, push
    powershell -File deploy_to_itch.ps1 -NoPush              # everything except publishing; the build is left in godot\builds\windows-release
    powershell -File deploy_to_itch.ps1 -SkipExtensionBuild  # reuse the DLLs already in godot\bin

It publishes to a public page: run it only when you mean to release. -NoPush is the way to check that it works.

Needs:
  - Godot 4.6.3, with its Windows export templates installed (Editor > Manage Export Templates).
  - Python 3 with SCons (python -m pip install scons) and Visual Studio's C++ tools (MSVC), to build the extension.
  - butler, logged in as an itch.io account that may push to the page (butler login), unless you use -NoPush.
Each tool is looked up, in this order, as the parameter (-GodotExe, -ButlerExe, -Python), the environment variable (GODOT_EXE,
BUTLER_EXE, PYTHON), the PATH, and the usual install folders (a Godot_v4.6* folder under Downloads, the itch app's butler).

Afterwards, sync_version.ps1 writes the itch.io build number into godot\export_presets.cfg as the version 0.1.<N>; commit that
as "Sync version to itch.io build #N" together with any .uid or .import files Godot wrote.
#>
param(
    [switch]$NoPush,
    [switch]$SkipExtensionBuild,
    [string]$GodotExe,
    [string]$ButlerExe,
    [string]$Python,
    [int]$Jobs = [Environment]::ProcessorCount
)

$ErrorActionPreference = "Stop"

# What is specific to this game.
$ItchGame = "overby-industries/mars-farming"
$Channel = "windows"
$ItchTarget = "${ItchGame}:$Channel"
$ExeName = "MarsFarming.exe"
$Library = "libmarsfarm"
$GodotVersionPrefix = "4.6.3"

$RepoRoot = $PSScriptRoot
$ProjectDir = Join-Path $RepoRoot "godot"
$BuildDir = Join-Path $ProjectDir "builds\windows-release"
$BuildExe = Join-Path $BuildDir $ExeName

function Find-Tool {
    param([string]$Label, [string]$Given, [string]$EnvName, [string[]]$Commands, [string[]]$Patterns)
    if ($Given) {
        if (Test-Path -LiteralPath $Given) { return (Resolve-Path -LiteralPath $Given).Path }
        throw "$Label was not found at '$Given' (the parameter)."
    }
    $fromEnv = [Environment]::GetEnvironmentVariable($EnvName)
    if ($fromEnv) {
        if (Test-Path -LiteralPath $fromEnv) { return (Resolve-Path -LiteralPath $fromEnv).Path }
        throw "$Label was not found at '$fromEnv' (the environment variable $EnvName)."
    }
    foreach ($c in $Commands) {
        $found = Get-Command $c -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.Source }
    }
    foreach ($p in $Patterns) {
        $hit = Get-ChildItem -Path $p -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -Last 1
        if ($hit) { return $hit.FullName }
    }
    throw "Could not find $Label. Pass it as a parameter, set `$env:$EnvName, or put it on the PATH."
}

function Invoke-Checked {
    param([string]$What, [scriptblock]$Command)
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE." }
}

$Godot = Find-Tool "Godot" $GodotExe "GODOT_EXE" @("godot.console", "godot") @(
    "$env:ProgramFiles\Godot*\*console*.exe",
    "$HOME\Downloads\Godot_v4.6*\*console*.exe",
    "$env:LOCALAPPDATA\Godot*\*console*.exe")
$PythonExe = Find-Tool "Python" $Python "PYTHON" @("python", "py") @()
$Butler = $null
if (-not $NoPush) {
    $Butler = Find-Tool "butler" $ButlerExe "BUTLER_EXE" @("butler") @(
        "$env:APPDATA\itch\apps\butler\butler.exe",
        "$env:LOCALAPPDATA\butler\butler.exe")
}

$godotVersion = (& $Godot --version | Select-Object -First 1)
if (-not "$godotVersion".StartsWith($GodotVersionPrefix)) {
    throw "This project is built for Godot $GodotVersionPrefix but '$Godot' says '$godotVersion'."
}
Write-Host "Godot $godotVersion"

if (Get-Command git -ErrorAction SilentlyContinue) {
    $dirty = & git -C $RepoRoot status --porcelain
    if ($dirty) { Write-Host "Warning: there are uncommitted changes, and the build will include them." }
}

# 1. The extension. The editor loads the debug library to export, the game ships the release one. SCons only rebuilds what
#    changed; the very first build also compiles godot-cpp and takes a long time.
if (-not $SkipExtensionBuild) {
    foreach ($target in "template_debug", "template_release") {
        Write-Host "Building the extension ($target)..."
        Push-Location $RepoRoot
        try {
            Invoke-Checked "The $target build" { & $PythonExe -m SCons platform=windows target=$target arch=x86_64 "-j$Jobs" }
        } finally {
            Pop-Location
        }
    }
}
$releaseDll = Join-Path $ProjectDir "bin\$Library.windows.template_release.x86_64.dll"
$debugDll = Join-Path $ProjectDir "bin\$Library.windows.template_debug.x86_64.dll"
foreach ($dll in $releaseDll, $debugDll) {
    if (-not (Test-Path -LiteralPath $dll)) { throw "Missing $dll. Build it, or run without -SkipExtensionBuild." }
}

# 2. Import the project (the first import of a fresh checkout can end with a crash code from inside Godot after it has
#    finished; running it twice, and judging by the export, is the way round that), then export.
Write-Host "Importing the project..."
& $Godot --headless --path $ProjectDir --import
& $Godot --headless --path $ProjectDir --import
Write-Host "Exporting the release build..."
if (Test-Path -LiteralPath $BuildDir) {
    if (-not $BuildDir.EndsWith("builds\windows-release")) { throw "Refusing to clear '$BuildDir'." }
    Remove-Item -LiteralPath $BuildDir -Recurse -Force   # no stale files from an earlier export in what gets uploaded
}
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
# --path is required: Godot does not look for a project, and $ProjectDir is the project whatever folder this is run from.
Invoke-Checked "The Godot export" { & $Godot --headless --path $ProjectDir --export-release "Windows Desktop" $BuildExe }
if (-not (Test-Path -LiteralPath $BuildExe)) { throw "The export did not produce $BuildExe." }
if (-not (Test-Path -LiteralPath (Join-Path $BuildDir "$Library.windows.template_release.x86_64.dll"))) {
    throw "The export has no release library next to the exe: the game would not start."
}

# 3. Start the exported game, headless, for 300 frames. It has to start, find its library and quit cleanly.
Write-Host "Smoke test: starting the exported game for 300 frames..."
# Start-Process -PassThru can leave ExitCode empty in Windows PowerShell 5.1, so the process is started through .NET, which also
# gives the game's output to show if it fails.
$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName = $BuildExe
$startInfo.Arguments = "--headless --quit-after 300"
$startInfo.WorkingDirectory = $BuildDir
$startInfo.UseShellExecute = $false
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$game = [System.Diagnostics.Process]::Start($startInfo)
$gameOut = $game.StandardOutput.ReadToEndAsync()
$gameErr = $game.StandardError.ReadToEndAsync()
if (-not $game.WaitForExit(120000)) {
    $game.Kill()
    throw "The exported game did not quit within 120 s."
}
$game.WaitForExit()
$gameText = "$($gameOut.Result)`n$($gameErr.Result)"
if ($game.ExitCode -ne 0) {
    Write-Host $gameText
    throw "The exported game exited with code $($game.ExitCode) in the smoke test."
}
# A missing library or a script that does not compile prints an error but can still let the game quit with code 0.
if ($gameText -match "ERROR") {
    Write-Host $gameText
    throw "The exported game printed errors in the smoke test."
}
Write-Host "The exported game started, printed no errors and quit cleanly."

if ($NoPush) {
    $size = (Get-ChildItem -LiteralPath $BuildDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
    Write-Host ("Not pushed (-NoPush). The build is in {0} ({1:N1} MiB). To release it: powershell -File deploy_to_itch.ps1 -SkipExtensionBuild" -f $BuildDir, ($size / 1MB))
    return
}

# 4. Push. The live build is read BEFORE the push so that the poll below has something to compare against: `butler status`
#    can return the previous build for a few seconds after a push while itch.io processes the new one.
function Get-LiveBuild {
    $line = & $Butler status $ItchGame --json 2>$null | Select-String '"type":"result"' | Select-Object -Last 1
    if (-not $line) { return $null }
    $status = $line.ToString() | ConvertFrom-Json
    return ($status.value.channels | Where-Object { $_.name -eq $Channel }).head
}

$before = Get-LiveBuild
Write-Host "Pushing to itch.io ($ItchTarget)..."
Invoke-Checked "butler push" { & $Butler push $BuildDir $ItchTarget }

Write-Host "Waiting for itch.io to finish processing the new build..."
$build = $null
for ($i = 0; $i -lt 20; $i++) {
    $build = Get-LiveBuild
    if ($build -and (-not $before -or $build.id -ne $before.id)) { break }
    Start-Sleep -Seconds 3
}
if (-not $build -or ($before -and $build.id -eq $before.id)) {
    throw "Timed out waiting for the new build in 'butler status $ItchGame'. The version number was NOT synced: run sync_version.ps1 -BuildNumber <N> once it shows."
}
if ($build.state -ne "completed") {
    Write-Host "Warning: build $($build.id) is still '$($build.state)', not 'completed'. Its number will not change, so going on."
}
$buildNumber = $build.version
Write-Host "Syncing the version to build #$buildNumber..."
& powershell -NoProfile -File (Join-Path $RepoRoot "sync_version.ps1") -BuildNumber $buildNumber
if ($LASTEXITCODE -ne 0) { throw "sync_version.ps1 failed with exit code $LASTEXITCODE." }

Write-Host "Done. Live version: 0.1.$buildNumber at https://overby-industries.itch.io/mars-farming"
Write-Host "Commit the version change (and any .uid or .import files) as 'Sync version to itch.io build #$buildNumber (0.1.$buildNumber)'."
