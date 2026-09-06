# adapters\epic_nemirtingas_epic_emulator\modify_joker_json.ps1
# Jokerverse Achievements config cannot be generated correctly for this
# adapter (retained under its fixed hook name only because
# _Achievement_Enabler.bat's Step 12 calls it by that literal filename for
# every adapter). Instead of writing a Joker JSON ourselves, this:
#
#   1. Creates the empty save-data folder the emulator itself uses:
#        %AppData%\NemirtingasEpicEmu\{EpicId}\{Namespace}
#   2. Watches %AppData%\Achievements\configs\ for a NEW .json file to
#      appear (Jokerverse itself is expected to create it once it notices
#      the game) - polls every 0.1s for up to 10s. Whichever .json file
#      appears or changes during that window is treated as the one for
#      this game.
#   3. Patches that file's "executable" and "process_name" fields, since
#      Jokerverse has no way to know the Launch *.bat / real exe name on
#      its own.
#
# If no new/changed file appears within the 10s window, this logs a
# warning and exits successfully anyway - Jokerverse may simply not be
# running, and that should not fail the overall setup.
#
# EpicId is the fixed placeholder baked into the shipped
# nepice_settings\NemirtingasEpicEmu.json template - see $fixedEpicId below.
# If that template's EpicId is ever changed, this constant must be updated
# to match.
#
#   AE_APP_DATA        - real %AppData% path (already includes \Roaming)
#   AE_EPIC_NAMESPACE  - Epic namespace/sandboxId, resolved in write_config.ps1
#   AE_EXECUTABLE      - full path to the selected launcher (Launch *.bat)
#   AE_PROCESS_NAME    - filename of the game exe

$appDataPath = $env:AE_APP_DATA
$namespace   = $env:AE_EPIC_NAMESPACE
$executable  = $env:AE_EXECUTABLE
$processName = $env:AE_PROCESS_NAME

$missing = @()
if (-not $appDataPath) { $missing += "AE_APP_DATA" }
if (-not $namespace)   { $missing += "AE_EPIC_NAMESPACE" }
if (-not $executable)  { $missing += "AE_EXECUTABLE" }
if (-not $processName) { $missing += "AE_PROCESS_NAME" }

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
