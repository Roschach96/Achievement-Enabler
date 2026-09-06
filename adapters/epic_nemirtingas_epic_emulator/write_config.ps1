# adapters\epic_nemirtingas_epic_emulator\write_config.ps1
#
# Runs the lookup -> fetch achievements -> download -> deploy Nemirtingas
# Epic Emulator pipeline against the game folder. Calls
# jokerverse_fetch_epic_achievements.bat as a subprocess (passing the
# resolved namespace so it doesn't prompt interactively) to produce
# epic_output\achievements_db.json + achievements_images\, which
# deploy_nemir_epic_emu.ps1 then copies into nepice_settings alongside the
# patched NemirtingasEpicEmu.json. deploy_nemir_epic_emu.ps1 also renames
# the game's existing EOSSDK loader DLL (found by find_paths.ps1, whatever
# crack/loader was already in place) to <name>.BAK on first run, then
# deploys the matching _no_network variant from the downloaded release in
# its place.
#
#   AE_GAME_FOLDER   - game root
#   AE_GAME_NAME     - display / folder name of the game
#   AE_EXE_PATH_RELATIVE / AE_DLL_REL - set by find_paths.ps1's _ae_vars.cmd
#
# Writes: _ae_final_exe.cmd (AE_FINAL_EXECUTABLE) and _ae_epic_namespace.cmd
#         (AE_EPIC_NAMESPACE, consumed by modify_joker_json.ps1) in the game
#         root, matching the orchestrator's env-handoff convention.

$ErrorActionPreference = 'Stop'

$gameFolder = $env:AE_GAME_FOLDER
$gameName   = $env:AE_GAME_NAME
$adapterDir = $env:AE_ADAPTER_DIR
$dllRel     = $env:AE_DLL_REL
$exeRel     = $env:AE_EXE_PATH_RELATIVE
if ($exeRel) { $exeRel = $exeRel -replace '^\.\.\\', '' }

if (-not $adapterDir) { $adapterDir = $PSScriptRoot }

$missing = @()
if (-not $gameFolder) { $missing += "AE_GAME_FOLDER" }
if (-not $gameName)   { $missing += "AE_GAME_NAME" }
if ($missing.Count -gt 0) {
    Write-Host "[ERROR] epic_nemirtingas_epic_emulator\write_config.ps1: missing env var(s): $($missing -join ', ')"
    exit 1
}

$dllFolderRel = if ($dllRel) { Split-Path -Parent $dllRel } else { '' }

. (Join-Path $adapterDir 'epic_namespace_lookup.ps1')
. (Join-Path $adapterDir 'download_nemir_epic_emu.ps1')
. (Join-Path $adapterDir 'deploy_nemir_epic_emu.ps1')

$cacheRoot = Join-Path $env:SystemDrive 'steamcmd\_Epic\NemirtingasEpicEmu'

Write-Host "[INFO] Looking up Epic namespace for '$gameName'..."
$lookup = Invoke-EpicNamespaceLookup -GameName $gameName
$namespace = $lookup.Namespace
Write-Host ""

Write-Host "[INFO] Fetching Epic achievements data for namespace $namespace..."
$fetchBat = Join-Path $adapterDir 'jokerverse_fetch_epic_achievements.bat'
$achievementsOutputDir = $null
if (Test-Path -LiteralPath $fetchBat) {
    & $fetchBat $namespace
    $fetchExit = $LASTEXITCODE
    $candidateOutputDir = Join-Path $adapterDir 'epic_output'
    if ($fetchExit -eq 0 -and (Test-Path -LiteralPath (Join-Path $candidateOutputDir 'achievements_db.json'))) {
        $achievementsOutputDir = $candidateOutputDir
        Write-Host "[INFO] Achievements data ready: $candidateOutputDir"
    } else {
        Write-Host "[WARN] jokerverse_fetch_epic_achievements.bat did not produce achievements_db.json (exit code $fetchExit) - continuing without achievements data."
    }
} else {
    Write-Host "[WARN] jokerverse_fetch_epic_achievements.bat not found at: $fetchBat - skipping achievements fetch."
}
Write-Host ""

Write-Host "[INFO] Fetching Nemirtingas EpicEmulatorRegistry release..."
$releaseDir = Invoke-DownloadNemirEpicEmu -CacheRoot $cacheRoot
if (-not $releaseDir) {
    Write-Host "[ERROR] Could not obtain EOSSDK loader DLL - aborting."
    exit 1
}
Write-Host ""

Write-Host "[INFO] Deploying Nemirtingas Epic Emulator..."
$deployed = Invoke-DeployNemirEpicEmu -GameRoot $gameFolder -SourceReleaseDir $releaseDir `
    -AdapterDir $adapterDir -GameName $gameName -Namespace $namespace `
    -DllFolderRel $dllFolderRel -ExeRel $exeRel -ExistingDllRel $dllRel `
    -AchievementsOutputDir $achievementsOutputDir

$lines = @(
    "set `"AE_FINAL_EXECUTABLE=$($deployed.LaunchBat)`"",
    "set `"AE_EPIC_NAMESPACE=$namespace`""
)
[System.IO.File]::WriteAllLines((Join-Path $gameFolder "_ae_final_exe.cmd"), $lines, [System.Text.Encoding]::ASCII)

Write-Host ""
Write-Host "[INFO] Nemirtingas Epic Emulator setup complete."
exit 0
