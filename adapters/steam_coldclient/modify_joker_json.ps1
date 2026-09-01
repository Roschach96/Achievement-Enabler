# adapters\steam_coldclient\modify_joker_json.ps1
# Reads GameSample.json, fills in all real values, writes the
# final per-game config to the Jokerverse Achievements folder.
#
#   AE_SOURCE_JSON   - path to the GameSample.json template
#   AE_DEST_JSON     - destination path for the output JSON
#   AE_GAME_NAME     - display / file name of the game (folder name)
#   AE_APP_ID        - Steam AppID (numeric string)
#   AE_APP_DATA      - real %AppData% path (expanded by cmd)
#   AE_EXECUTABLE    - full path to the selected _ColdClient steamclient_loader exe
#   AE_ARGUMENTS     - launch args from SteamCMD (may be empty)
#   AE_PROCESS_NAME  - filename of the game exe (e.g. GameName.exe)
#   AE_MANIFEST_FILE - (optional) path to the SteamCMD manifest txt

$sourceJson   = $env:AE_SOURCE_JSON
$destJson     = $env:AE_DEST_JSON
$gameName     = $env:AE_GAME_NAME
$appId        = $env:AE_APP_ID
$appDataPath  = $env:AE_APP_DATA
$executable   = $env:AE_EXECUTABLE
$arguments    = if ($env:AE_ARGUMENTS) { $env:AE_ARGUMENTS } else { "" }
$processName  = $env:AE_PROCESS_NAME
$manifestFile = $env:AE_MANIFEST_FILE

$missing = @()
if (-not $sourceJson)  { $missing += "AE_SOURCE_JSON" }
if (-not $destJson)    { $missing += "AE_DEST_JSON" }
if (-not $gameName)    { $missing += "AE_GAME_NAME" }
if (-not $appId)       { $missing += "AE_APP_ID" }
if (-not $appDataPath) { $missing += "AE_APP_DATA" }
if (-not $executable)  { $missing += "AE_EXECUTABLE" }
if (-not $processName) { $missing += "AE_PROCESS_NAME" }

if ($missing.Count -gt 0) {
    Write-Host "[ERROR] steam_coldclient\modify_joker_json.ps1: missing env var(s): $($missing -join ', ')"
    exit 1
}

if (-not (Test-Path -LiteralPath $sourceJson)) {
    Write-Host "[ERROR] Source JSON not found: $sourceJson"
    exit 1
}

$displayName = $gameName

if ($manifestFile -and (Test-Path -LiteralPath $manifestFile)) {
    try {
        $lines      = Get-Content -LiteralPath $manifestFile -Encoding UTF8
        $inCommon   = $false
        $braceDepth = 0
        $found      = $false

        foreach ($line in $lines) {
            if (-not $inCommon) {
                if ($line -match '^\s*"common"\s*$') {
                    $inCommon = $true
                }
            } else {
                if ($line -match '^\s*\{') {
                    $braceDepth++
                } elseif ($line -match '^\s*\}') {
                    $braceDepth--
                    if ($braceDepth -le 0) { break }
                } elseif ($braceDepth -eq 1 -and $line -match '^\s*"name"\s+"(.+)"\s*$') {
                    $displayName = $Matches[1]
                    $found = $true
                    break
                }
            }
        }

        if ($found) {
            Write-Host "[INFO] Display name from manifest: $displayName"
        } else {
            Write-Host "[INFO] 'common > name' not found in manifest - using folder name: $displayName"
        }
    } catch {
        Write-Host "[WARN] Could not read manifest file: $_ - falling back to folder name."
    }
} else {
    Write-Host "[INFO] No manifest file provided or found - using folder name as display name."
}

try {
    $json = Get-Content -LiteralPath $sourceJson -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Host "[ERROR] Failed to parse JSON template: $_"
    exit 1
}

$configPath = Join-Path $appDataPath "Achievements\configs\schema\steam\$appId"
$savePath   = Join-Path $appDataPath "GSE Saves\$appId"

$json.name         = $gameName
$json.appid        = $appId
$json.config_path  = $configPath
$json.save_path    = $savePath
$json.executable   = $executable
$json.arguments    = $arguments
$json.process_name = $processName
$json.displayName  = $displayName

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
