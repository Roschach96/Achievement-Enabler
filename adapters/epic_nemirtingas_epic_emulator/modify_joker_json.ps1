# adapters\epic_nemirtingas_epic_emulator\modify_joker_json.ps1
# Jokerverse creates the game's config .json itself, on its own detection
# cycle - so this adapter no longer writes it. Mirroring the EA adapter, this:
#   1. Creates the empty save-data folder the emulator itself uses:
#        %AppData%\NemirtingasEpicEmu\{EpicId}\{Namespace}
#   2. Launches core\common\watch_and_patch_joker_config.ps1 as a DETACHED
#      background process and returns immediately - it does not block setup.
#      That watcher patches "executable"/"process_name" into whatever config
#      Jokerverse eventually creates for this game, matched on the "appid"
#      field - which for an Epic title is the Epic namespace/sandboxId (see
#      $namespace) - including re-patching if Jokerverse rewrites it later,
#      for up to ~3 minutes.
#
# EpicId is the fixed placeholder baked into the shipped
# nepice_settings\NemirtingasEpicEmu.json template - see $fixedEpicId below.
# If that template's EpicId is ever changed, this constant must be updated
# to match.
#
#   AE_APP_DATA        - real %AppData% path (already includes \Roaming)
#   AE_EPIC_NAMESPACE  - Epic namespace/sandboxId, resolved in write_config.ps1
#   AE_ADAPTER_DIR     - full path to this adapter folder
#   AE_EXECUTABLE      - full path to the selected launcher (Launch *.bat)
#   AE_PROCESS_NAME    - filename of the game exe

param([switch]$CreateFolderOnly)

$appDataPath = $env:AE_APP_DATA
$namespace   = $env:AE_EPIC_NAMESPACE
$adapterDir  = $env:AE_ADAPTER_DIR
$executable  = $env:AE_EXECUTABLE
$processName = $env:AE_PROCESS_NAME

$missing = @()
if (-not $appDataPath) { $missing += "AE_APP_DATA" }
if (-not $namespace)   { $missing += "AE_EPIC_NAMESPACE" }
if (-not $CreateFolderOnly) {
    # These are only needed to launch the watcher / patch the config,
    # not to create the save folder - skip them in -CreateFolderOnly mode.
    if (-not $adapterDir)  { $missing += "AE_ADAPTER_DIR" }
    if (-not $executable)  { $missing += "AE_EXECUTABLE" }
    if (-not $processName) { $missing += "AE_PROCESS_NAME" }
}

if ($missing.Count -gt 0) {
    Write-Host "[ERROR] epic_nemirtingas_epic_emulator\modify_joker_json.ps1: missing env var(s): $($missing -join ', ')"
    exit 1
}

$fixedEpicId = "17380c2a51230d05a341a2319657af57"
$savePath    = Join-Path $appDataPath "NemirtingasEpicEmu\$fixedEpicId\$namespace"

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
# For an Epic title, Jokerverse's "appid" field holds the Epic namespace.
$configsDir    = Join-Path $appDataPath "Achievements\configs"
$commonDir     = Join-Path (Split-Path -Parent (Split-Path -Parent $adapterDir)) "core\common"
$watcherScript = Join-Path $commonDir "watch_and_patch_joker_config.ps1"

if (-not (Test-Path -LiteralPath $watcherScript)) {
    Write-Host "[ERROR] $watcherScript not found - cannot patch Jokerverse's config once it appears."
    exit 1
}

try {
    $argString = "-NoProfile -ExecutionPolicy Bypass -File `"$watcherScript`" " +
                 "-ConfigsDir `"$configsDir`" -AppId `"$namespace`" " +
                 "-Executable `"$executable`" -ProcessName `"$processName`""
    Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList $argString
    Write-Host "[INFO] Launched background watcher for Jokerverse config (namespace $namespace) - it will patch"
    Write-Host "[INFO] executable/process_name whenever the config appears or is rewritten, for up to 3 minutes."
} catch {
    Write-Host "[ERROR] Failed to launch background watcher: $_"
    exit 1
}
