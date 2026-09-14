# adapters\ubisoft_uplay_r1\modify_joker_json.ps1
# Jokerverse creates the game's config .json itself, on its own detection
# cycle - so this adapter no longer writes it. Mirroring the Epic/EA
# adapters, this:
#   1. Creates the emulator's own save-data folder (GSE Saves\<appid>).
#   2. Watches %AppData%\Achievements\configs\ for the .json Jokerverse
#      creates and patches "executable"/"process_name" into it - Jokerverse
#      has no way to know the real local launcher/exe on its own.
#
# If no new/changed config appears within the 10s window, this logs a
# warning and exits successfully - Jokerverse may simply not be running,
# and that should not fail the overall setup.
#
#   AE_APP_ID       - Steam AppID
#   AE_APP_DATA     - real %AppData% path (expanded by cmd)
#   AE_EXECUTABLE   - full path to the launcher/loader that starts the game
#   AE_PROCESS_NAME - filename of the game exe (e.g. GameName.exe)

$appId       = $env:AE_APP_ID
$appDataPath = $env:AE_APP_DATA
$executable  = $env:AE_EXECUTABLE
$processName = $env:AE_PROCESS_NAME

$missing = @()
if (-not $appId)       { $missing += "AE_APP_ID" }
if (-not $appDataPath) { $missing += "AE_APP_DATA" }
if (-not $executable)  { $missing += "AE_EXECUTABLE" }
if (-not $processName) { $missing += "AE_PROCESS_NAME" }

if ($missing.Count -gt 0) {
    Write-Host "[ERROR] ubisoft_uplay_r1\modify_joker_json.ps1: missing env var(s): $($missing -join ', ')"
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

# ---- Watch for a new/changed Jokerverse config file --------------------------
$configsDir = Join-Path $appDataPath "Achievements\configs"
if (-not (Test-Path -LiteralPath $configsDir)) {
    Write-Host "[INFO] $configsDir does not exist - Jokerverse is probably not installed. Skipping executable/process_name patch."
    exit 0
}

Write-Host "[INFO] Watching $configsDir for a new Jokerverse config (up to 10s)..."

# Baseline: filename -> LastWriteTimeUtc for everything already there before
# we start watching, so we can tell "new" and "just-modified" apart from
# files that were already sitting there untouched.
$baseline = @{}
Get-ChildItem -LiteralPath $configsDir -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
    $baseline[$_.Name] = $_.LastWriteTimeUtc
}

$targetFile = $null
$elapsedMs  = 0
$pollMs     = 100
$timeoutMs  = 10000

while ($elapsedMs -lt $timeoutMs -and -not $targetFile) {
    Start-Sleep -Milliseconds $pollMs
    $elapsedMs += $pollMs

    $current = Get-ChildItem -LiteralPath $configsDir -Filter '*.json' -File -ErrorAction SilentlyContinue
    foreach ($file in $current) {
        $wasKnown = $baseline.ContainsKey($file.Name)
        $isNew     = -not $wasKnown
        $isChanged = $wasKnown -and ($file.LastWriteTimeUtc -gt $baseline[$file.Name])
        if ($isNew -or $isChanged) {
            $targetFile = $file
            break
        }
    }
}

if (-not $targetFile) {
    Write-Host "[WARN] No new or changed Jokerverse config appeared in $configsDir within 10s - skipping executable/process_name patch."
    exit 0
}

Write-Host "[INFO] Detected Jokerverse config: $($targetFile.FullName)"

try {
    $json = Get-Content -LiteralPath $targetFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $json.executable   = $executable
    $json.process_name = $processName
    $output = $json | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($targetFile.FullName, $output, [System.Text.UTF8Encoding]::new($false))
    Write-Host "[INFO] Patched executable/process_name in: $($targetFile.FullName)"
} catch {
    Write-Host "[ERROR] Failed to patch detected config: $_"
    exit 1
}
