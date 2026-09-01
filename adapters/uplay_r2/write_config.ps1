# adapters\uplay_r2\write_config.ps1
#
# All inputs come in via env vars set by AchievementEnabler.bat:
#
#   AE_GAME_FOLDER   - game root (where generate_emu_config\_OUTPUT lives)
#   AE_APP_ID        - Steam AppID
#   AE_ADAPTER_DIR   - full path to adapters\uplay_r2 (this folder)
#   AE_ASSETS_DIR    - full path to the GoldbergUplayR2-* assets folder
#   AE_DLL_REL       - relative path (from game root) to the selected loader DLL
#   AE_DESTINATION   - full path to the folder the DLL/INI should live in
#   AE_APPDATA       - real %AppData% path

$gameFolder  = $env:AE_GAME_FOLDER
$appId       = $env:AE_APP_ID
$adapterDir  = $env:AE_ADAPTER_DIR
$assetsDir   = $env:AE_ASSETS_DIR
$dllRel      = $env:AE_DLL_REL
$destination = $env:AE_DESTINATION
$appData     = $env:AE_APPDATA

$missing = @()
if (-not $gameFolder)  { $missing += "AE_GAME_FOLDER" }
if (-not $appId)       { $missing += "AE_APP_ID" }
if (-not $adapterDir)  { $missing += "AE_ADAPTER_DIR" }
if (-not $destination) { $missing += "AE_DESTINATION" }
if ($missing.Count -gt 0) {
    Write-Host "[ERROR] uplay_r2\write_config.ps1: missing env var(s): $($missing -join ', ')"
    exit 1
}

# ── Step 0: failsafe - the GoldbergUplayR2-* asset pack must be complete ───
# Ships inside adapters\uplay_r2\GoldbergUplayR2-*. If it's missing entirely,
# or missing any file below (e.g. a partial/old download), stop here instead
# of silently producing a broken setup.
$requiredAssetFiles = @(
    'uplay_r2.ini',
    'uplay_r2_loader.dll',
    'uplay_r2_loader64.dll',
    'achievements_schema_example.json',
    'upc_r2.ini',
    'upc_r2_loader.dll',
    'upc_r2_loader64.dll'
)

if (-not $assetsDir -or -not (Test-Path -LiteralPath $assetsDir)) {
    Write-Host "[ERROR] Uplay R2 asset pack (GoldbergUplayR2-*) was not found under: $adapterDir"
    Write-Host "[ERROR] Please redownload the latest Uplay R2 emulator files and place the"
    Write-Host "[ERROR] 'GoldbergUplayR2-*' folder inside adapters\uplay_r2\."
    exit 1
}

$missingAssets = $requiredAssetFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $assetsDir $_)) }
if ($missingAssets.Count -gt 0) {
    Write-Host "[ERROR] The Uplay R2 asset pack at '$assetsDir' is missing required file(s):"
    foreach ($f in $missingAssets) { Write-Host "  - $f" }
    Write-Host "[ERROR] Please redownload the latest Uplay R2 emulator files and replace the"
    Write-Host "[ERROR] 'GoldbergUplayR2-*' folder inside adapters\uplay_r2\ with the complete version."
    exit 1
}

# ── Step 1: back up any pre-existing loader DLLs / INIs in place ──────────
$backupTargets = @('upc_r2_loader.dll', 'upc_r2_loader64.dll', 'uplay_r2_loader.dll', 'uplay_r2_loader64.dll')
foreach ($name in $backupTargets) {
    $p = Join-Path $destination $name
    $bak = "$p.BAK"
    if (-not (Test-Path -LiteralPath $bak) -and (Test-Path -LiteralPath $p)) {
        Rename-Item -LiteralPath $p -NewName "$name.BAK"
    }
}
foreach ($name in @('upc_r2.ini', 'uplay_r2.ini')) {
    $p = Join-Path $destination $name
    $bak = "$p.BAK"
    if (-not (Test-Path -LiteralPath $bak) -and (Test-Path -LiteralPath $p)) {
        Rename-Item -LiteralPath $p -NewName "$name.BAK"
    }
}

# ── Step 2: detect the achievement key prefix from achievements.json ──────
$achievementFile = Join-Path $gameFolder "generate_emu_config\_OUTPUT\$appId\steam_settings\achievements.json"
$achPrefix = ""
if (Test-Path -LiteralPath $achievementFile) {
    try {
        $json = Get-Content -Raw -LiteralPath $achievementFile | ConvertFrom-Json
        $firstName = $json[0].name
        if ($firstName -match '^(.+?)_?\d+$') {
            $achPrefix = $Matches[1] + "_"
        }
    } catch {
        Write-Host "[WARN] Could not auto-detect achievement prefix: $_"
    }
}
if (-not $achPrefix) {
    Write-Host "[INFO] Could not auto-detect achievement key prefix."
    Write-Host "       Open https://steamdb.info/app/$appId/stats/ , find the prefix used"
    Write-Host "       by this game's achievement IDs, then re-run with it if needed."
    $achPrefix = Read-Host "Enter achievement prefix (example: AFOP_Ach_), or leave blank"
} else {
    Write-Host "[INFO] Auto-detected achievement prefix: $achPrefix"
}

# ── Step 3: generate achievements_schema.json (key = <prefix><id>) ────────
$schemaScript = Join-Path $adapterDir "generate_achievements_schema_v3.ps1"
if (Test-Path -LiteralPath $schemaScript) {
    Push-Location $gameFolder
    try {
        & $schemaScript -appID $appId -prefix $achPrefix
    } finally {
        Pop-Location
    }
} else {
    Write-Host "[WARN] generate_achievements_schema_v3.ps1 not found next to adapter - skipping schema generation."
}

# ── Step 4: copy the matching loader DLL + INI (and the schema) from assets ─
$dllName = if ($dllRel) { Split-Path $dllRel -Leaf } else { "" }

$matchedIni = switch -Regex ($dllName) {
    '(?i)^upc_r2_loader(64)?\.dll$'   { 'upc_r2.ini';   break }
    '(?i)^uplay_r2_loader(64)?\.dll$' { 'uplay_r2.ini'; break }
    default { $null }
}

if (-not (Test-Path -LiteralPath $destination)) {
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
}

$filesToCopy = @()
if ($matchedIni) {
    Write-Host "[INFO] Copying required files to $destination (matched: $dllName)..."
    $filesToCopy = @($matchedIni, $dllName)
} else {
    Write-Host "[WARN] Could not determine original loader DLL - copying all variants."
    $filesToCopy = @('upc_r2.ini', 'upc_r2_loader.dll', 'upc_r2_loader64.dll', 'uplay_r2.ini', 'uplay_r2_loader.dll', 'uplay_r2_loader64.dll')
}

if ($assetsDir) {
    foreach ($f in $filesToCopy) {
        $src = Join-Path $assetsDir $f
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination $destination -Force
        }
    }
}

$schemaSrc = Join-Path $gameFolder "achievements_schema.json"
if ((Test-Path -LiteralPath $schemaSrc) -and ($destination -ne $gameFolder)) {
    Copy-Item -LiteralPath $schemaSrc -Destination $destination -Force
}

# ── Step 5: patch the copied INI(s) ────────────────────────────────────────
$achSavePath = Join-Path $appData "GSE Saves\$appId"
$patchScript = Join-Path $adapterDir "patch_ini.ps1"

foreach ($iniName in @('upc_r2.ini', 'uplay_r2.ini')) {
    $iniPath = Join-Path $destination $iniName
    if (Test-Path -LiteralPath $iniPath) {
        $env:AE_INI_PATH       = $iniPath
        $env:AE_ACH_SAVE_PATH  = $achSavePath
        $env:AE_ACH_KEY_PREFIX = $achPrefix
        & $patchScript
    }
}

Write-Host ""
Write-Host "[INFO] achievements_schema.json generated and required files copied."
exit 0
