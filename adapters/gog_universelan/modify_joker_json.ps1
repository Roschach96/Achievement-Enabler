# adapters\gog_universelan\modify_joker_json.ps1
# Reads GameSample.json (GOG variant - platform "gog", config/save paths
# under UniverseLAN's own layout), fills in real values, writes the final
# per-game config to the Jokerverse Achievements folder.
#
# The GOG App ID is looked up here from the game's own goggame-<id>.info
# file (same approach as deploy_universelan.ps1's Get-GogAppId) rather than
# being passed in - GOG never appears in a SteamCMD manifest, so there is no
# earlier orchestrator step that already knows it.
#
#   AE_SOURCE_JSON  - path to the GameSample.json template
#   AE_DEST_JSON    - destination path for the output JSON
#   AE_GAME_NAME    - display / folder name of the game
#   AE_GAME_FOLDER  - game root (searched for goggame-<id>.info)
#   AE_APP_DATA     - real %AppData% path
#   AE_EXECUTABLE   - full path to the selected game exe
#   AE_ARGUMENTS    - launch args (may be empty)
#   AE_PROCESS_NAME - filename of the game exe (e.g. GameName.exe)

$sourceJson  = $env:AE_SOURCE_JSON
$destJson    = $env:AE_DEST_JSON
$gameName    = $env:AE_GAME_NAME
$gameFolder  = $env:AE_GAME_FOLDER
$appDataPath = $env:AE_APP_DATA
$executable  = $env:AE_EXECUTABLE
$arguments   = if ($env:AE_ARGUMENTS) { $env:AE_ARGUMENTS } else { "" }
$processName = $env:AE_PROCESS_NAME

$missing = @()
if (-not $sourceJson)  { $missing += "AE_SOURCE_JSON" }
if (-not $destJson)    { $missing += "AE_DEST_JSON" }
if (-not $gameName)    { $missing += "AE_GAME_NAME" }
if (-not $gameFolder)  { $missing += "AE_GAME_FOLDER" }
if (-not $appDataPath) { $missing += "AE_APP_DATA" }
if (-not $executable)  { $missing += "AE_EXECUTABLE" }
if (-not $processName) { $missing += "AE_PROCESS_NAME" }

if ($missing.Count -gt 0) {
    Write-Host "[ERROR] gog_universelan\modify_joker_json.ps1: missing env var(s): $($missing -join ', ')"
    exit 1
}

if (-not (Test-Path -LiteralPath $sourceJson)) {
    Write-Host "[ERROR] Source JSON not found: $sourceJson"
    exit 1
}

function Get-GogAppId {
    # Finds the game's GOG App ID from its "goggame-<id>.info" file - checks
    # the game folder itself first, then falls back to a recursive search
    # in case it's nested. Returns $null if no such file is found.
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

try {
    $json = Get-Content -LiteralPath $sourceJson -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Host "[ERROR] Failed to parse JSON template: $_"
    exit 1
}

$configPath = Join-Path $appDataPath "Achievements\configs\schema\gog\$appId"
$savePath   = Join-Path $appDataPath "Local\UniverseLAN\$appId"

$json.name         = "$gameName (GOG)"
$json.appid        = $appId
$json.platform     = "gog"
$json.config_path  = $configPath
$json.save_path    = $savePath
$json.executable   = $executable
$json.arguments    = $arguments
$json.process_name = $processName

$destDir = Split-Path -Parent $destJson
if (-not (Test-Path -LiteralPath $destDir)) {
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
}

try {
    $output = $json | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($destJson, $output, [System.Text.UTF8Encoding]::new($false))
    Write-Host "[INFO] Game config written to: $destJson"
} catch {
    Write-Host "[ERROR] Failed to write output JSON: $_"
    exit 1
}
