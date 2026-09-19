# adapters\gog_universelan\modify_joker_json.ps1
# Jokerverse creates the game's config .json itself, on its own detection
# cycle - so this adapter no longer writes it. Mirroring the EA adapter, this:
#   1. Creates UniverseLAN's own save-data folder (Local\UniverseLAN\<appid>).
#   2. Launches core\common\watch_and_patch_joker_config.ps1 as a DETACHED
#      background process and returns immediately - it does not block setup.
#      That watcher patches "executable"/"process_name" into whatever config
#      Jokerverse eventually creates for this GOG App ID (matched on the
#      "appid" field), including re-patching if Jokerverse rewrites it later -
#      for up to ~3 minutes.
#
# The GOG App ID is looked up from the game's own goggame-<id>.info file
# (GOG never appears in a SteamCMD manifest), same as deploy_universelan.ps1.
#
#   AE_APP_DATA     - real %AppData% path
#   AE_GAME_FOLDER  - game root (searched for goggame-<id>.info)
#   AE_ADAPTER_DIR  - full path to this adapter folder
#   AE_EXECUTABLE   - full path to the selected game exe
#   AE_PROCESS_NAME - filename of the game exe (e.g. GameName.exe)

param([switch]$CreateFolderOnly)

$appDataPath = $env:AE_APP_DATA
$gameFolder  = $env:AE_GAME_FOLDER
$adapterDir  = $env:AE_ADAPTER_DIR
$executable  = $env:AE_EXECUTABLE
$processName = $env:AE_PROCESS_NAME

$missing = @()
if (-not $appDataPath) { $missing += "AE_APP_DATA" }
if (-not $gameFolder)  { $missing += "AE_GAME_FOLDER" }
if (-not $CreateFolderOnly) {
    # These are only needed to launch the watcher / patch the config,
    # not to create the save folder - skip them in -CreateFolderOnly mode.
    if (-not $adapterDir)  { $missing += "AE_ADAPTER_DIR" }
    if (-not $executable)  { $missing += "AE_EXECUTABLE" }
    if (-not $processName) { $missing += "AE_PROCESS_NAME" }
}

if ($missing.Count -gt 0) {
    Write-Host "[ERROR] gog_universelan\modify_joker_json.ps1: missing env var(s): $($missing -join ', ')"
    exit 1
}

function Get-GogAppId {
    # Finds the game's GOG App ID from its "goggame-<id>.info" file - checks
    # the game folder itself first, then falls back to a recursive search.
    param([string]$GameFolder)
    $infoFile = Get-ChildItem -LiteralPath $GameFolder -Filter 'goggame-*.info' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $infoFile) {
        $infoFile = Get-ChildItem -LiteralPath $GameFolder -Recurse -Filter 'goggame-*.info' -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }
    if ($infoFile -and $infoFile.Name -match 'goggame-(?<id>\d+)\.info') {
        return $Matches['id']
    }
    return $null
}

$appId = Get-GogAppId -GameFolder $gameFolder
if (-not $appId) {
    Write-Host "[ERROR] No goggame-*.info found under $gameFolder - could not determine the GOG App ID."
    exit 1
}
Write-Host "[INFO] GOG App ID detected: $appId"

$savePath = Join-Path $appDataPath "Local\UniverseLAN\$appId"

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
                 "-Executable `"$executable`" -ProcessName `"$processName`""
    Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList $argString
    Write-Host "[INFO] Launched background watcher for Jokerverse config (appid $appId) - it will patch"
    Write-Host "[INFO] executable/process_name whenever the config appears or is rewritten, for up to 3 minutes."
} catch {
    Write-Host "[ERROR] Failed to launch background watcher: $_"
    exit 1
}
