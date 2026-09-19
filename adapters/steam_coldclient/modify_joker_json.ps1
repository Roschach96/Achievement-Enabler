# adapters\steam_coldclient\modify_joker_json.ps1
# Jokerverse creates the game's config .json itself, on its own detection
# cycle - so this adapter no longer writes it. Mirroring the EA adapter, this:
#   1. Creates the emulator's own save-data folder (GSE Saves\<appid>).
#   2. Launches core\common\watch_and_patch_joker_config.ps1 as a DETACHED
#      background process and returns immediately - it does not block setup.
#      That watcher patches "executable"/"arguments"/"process_name" into
#      whatever config Jokerverse eventually creates for this Steam appid
#      (matched on the "appid" field), including re-patching if Jokerverse
#      rewrites it later - for up to ~3 minutes.
#
#   AE_APP_ID       - Steam AppID
#   AE_APP_DATA     - real %AppData% path (expanded by cmd)
#   AE_ADAPTER_DIR  - full path to this adapter folder
#   AE_EXECUTABLE   - full path to the selected _ColdClient steamclient_loader exe
#   AE_ARGUMENTS    - launch args from SteamCMD (may be empty)
#   AE_PROCESS_NAME - filename of the game exe (e.g. GameName.exe)

param([switch]$CreateFolderOnly)

$appId       = $env:AE_APP_ID
$appDataPath = $env:AE_APP_DATA
$adapterDir  = $env:AE_ADAPTER_DIR
$executable  = $env:AE_EXECUTABLE
$arguments   = if ($env:AE_ARGUMENTS) { $env:AE_ARGUMENTS } else { "" }
$processName = $env:AE_PROCESS_NAME

$missing = @()
if (-not $appId)       { $missing += "AE_APP_ID" }
if (-not $appDataPath) { $missing += "AE_APP_DATA" }
if (-not $CreateFolderOnly) {
    # These are only needed to launch the watcher / patch the config,
    # not to create the save folder - skip them in -CreateFolderOnly mode.
    if (-not $adapterDir)  { $missing += "AE_ADAPTER_DIR" }
    if (-not $executable)  { $missing += "AE_EXECUTABLE" }
    if (-not $processName) { $missing += "AE_PROCESS_NAME" }
}

if ($missing.Count -gt 0) {
    Write-Host "[ERROR] steam_coldclient\modify_joker_json.ps1: missing env var(s): $($missing -join ', ')"
    exit 1
}

$savePath = Join-Path $appDataPath "GSE Saves\$appId"

Write-Host "[INFO] Jokerverse config generation is skipped for this adapter - creating empty save folder instead."

try {
    if (-not (Test-Path -LiteralPath $savePath)) {
        New-Item -ItemType Directory -Path $savePath -Force | Out-Null
        Write-Host "[INFO] Created: $savePath"
    } else {
        Write-Host "[INFO] Already exists: $savePath"
    }
} catch {
    Write-Host "[ERROR] Failed to create save folder: $_"
    exit 1
}

if ($CreateFolderOnly) { exit 0 }

# ---- Hand off to the shared detached watcher (mirrors ea_origin_emulator) ----
$configsDir    = Join-Path $appDataPath "Achievements\configs"
$commonDir     = Join-Path (Split-Path -Parent (Split-Path -Parent $adapterDir)) "core\common"
$watcherScript = Join-Path $commonDir "watch_and_patch_joker_config.ps1"

if (-not (Test-Path -LiteralPath $watcherScript)) {
    Write-Host "[ERROR] $watcherScript not found - cannot patch Jokerverse's config once it appears."
    exit 1
}

try {
    $argString = "-NoProfile -ExecutionPolicy Bypass -File `"$watcherScript`" " +
                 "-ConfigsDir `"$configsDir`" -AppId `"$appId`" " +
                 "-Executable `"$executable`" -ProcessName `"$processName`" " +
                 "-PatchArguments -Arguments `"$arguments`""
    Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList $argString
    Write-Host "[INFO] Launched background watcher for Jokerverse config (appid $appId) - it will patch"
    Write-Host "[INFO] executable/arguments/process_name whenever the config appears or is rewritten, for up to 3 minutes."
} catch {
    Write-Host "[ERROR] Failed to launch background watcher: $_"
    exit 1
}
