# adapters\uplay_r1\modify_joker_json.ps1
# Reads GameSample.json (Uplay variant - executable field points straight at
# the game exe rather than a loader), fills in all real values, writes the
# final per-game config to the Jokerverse Achievements folder.
#
#   AE_SOURCE_JSON   - path to the GameSample.json template
#   AE_DEST_JSON     - destination path for the output JSON
#   AE_GAME_NAME     - internal name / file name (folder name)
#   AE_APP_ID        - Steam AppID
#   AE_APP_DATA      - real %AppData% path
#   AE_EXECUTABLE    - full path to the selected game exe
#   AE_ARGUMENTS     - launch args from SteamCMD (may be empty)
#   AE_PROCESS_NAME  - filename of the game exe (e.g. GameName.exe)
#   AE_MANIFEST_FILE - path to the SteamCMD manifest txt

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
    Write-Host "[ERROR] uplay_r1\modify_joker_json.ps1: missing env var(s): $($missing -join ', ')"
    exit 1
}

if (-not (Test-Path -LiteralPath $sourceJson)) {
    Write-Host "[ERROR] Source JSON not found: $sourceJson"
    exit 1
}

$displayName = $gameName

if ($manifestFile -and (Test-Path -LiteralPath $manifestFile)) {
    try {
        $raw = [System.IO.File]::ReadAllBytes($manifestFile)
        if ($raw.Length -ge 2 -and $raw[0] -eq 0xFF -and $raw[1] -eq 0xFE) {
            $text = [System.Text.Encoding]::Unicode.GetString($raw, 2, $raw.Length - 2)
        } elseif ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF) {
            $text = [System.Text.Encoding]::UTF8.GetString($raw, 3, $raw.Length - 3)
        } else {
            $text = [System.Text.Encoding]::UTF8.GetString($raw)
        }

        $inCommon   = $false
        $braceDepth = 0
        $found      = $false

        foreach ($line in ($text -split "`r?`n")) {
            if (-not $inCommon) {
                if ($line -match '^\s*"common"\s*$') { $inCommon = $true }
            } else {
                if      ($line -match '^\s*\{')                                          { $braceDepth++ }
                elseif  ($line -match '^\s*\}')                                          { $braceDepth--; if ($braceDepth -le 0) { break } }
                elseif  ($braceDepth -eq 1 -and $line -match '^\s*"name"\s+"(.+)"\s*$') { $displayName = $Matches[1]; $found = $true; break }
            }
        }

        if ($found) { Write-Host "[INFO] Display name from manifest: $displayName" }
        else        { Write-Host "[INFO] 'common > name' not found - using folder name: $displayName" }
    } catch {
        Write-Host "[WARN] Could not read manifest: $_ - falling back to folder name."
    }
} else {
    Write-Host "[INFO] No manifest file - using folder name as display name."
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
if ($json.PSObject.Properties.Name -contains 'steamAppId') {
    $json.PSObject.Properties.Remove('steamAppId')
}
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
