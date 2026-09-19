# adapters\ea_origin_emulator\modify_joker_json.ps1
#
# Jokerverse creates a game's config on its OWN independent detection cycle -
# whenever it next notices no config exists yet for that Steam appid -
# completely decoupled from anything this setup script does. The .json can
# appear well after this script has already finished running, so waiting
# synchronously for it here can never reliably catch it.
#
# So this script:
#   1. Creates the empty save-data folder anadius's own emulator uses:
#        %LocalAppData%\anadius\LSX emu\achievement_watcher\{SteamAppId}
#   2. Launches the SHARED watcher core\common\watch_and_patch_joker_config.ps1
#      as a DETACHED background process (Start-Process -WindowStyle Hidden)
#      and returns immediately. That watcher keeps running independently (up
#      to ~3 minutes) and patches "executable"/"process_name" into whatever
#      config Jokerverse eventually creates for this Steam appid (matched on
#      the "appid" field) - including re-patching if Jokerverse rewrites it
#      again later. Confirmed directly: left unpatched, Jokerverse fills
#      process_name with a naive parse of the Steam manifest's link2ea://...
#      launch URI, producing garbage like "1938010?platform=steam&theme=...".
#
# (The watcher used to live in this adapter folder; it now lives in
# core\common\ and is shared by every adapter, so the local copy is gone.)
#
# The Steam appid comes from _origin_helper_meta.txt, which origin_helper.py
# writes next to anadius.cfg after resolving it via ITAD - this script does
# not re-derive it itself.
#
#   AE_APP_DATA     - real %AppData% path (expanded by cmd)
#   AE_GAME_FOLDER  - game root (where anadius.cfg + the metadata file land)
#   AE_ADAPTER_DIR  - full path to adapters\ea_origin_emulator (this folder)
#   AE_EXECUTABLE   - full path to the selected game exe (find_paths.ps1)
#   AE_PROCESS_NAME - bare filename of that same exe
#
# %LocalAppData% is read directly via $env:LOCALAPPDATA rather than a new
# AE_-prefixed var - PowerShell child processes inherit real Windows
# environment variables automatically, so no orchestrator change is needed
# for this one (unlike AE_APP_DATA, which the orchestrator already passes
# explicitly for other reasons).

param([switch]$CreateFolderOnly)

$appDataPath  = $env:AE_APP_DATA
$gameFolder   = $env:AE_GAME_FOLDER
$adapterDir   = $env:AE_ADAPTER_DIR
$executable   = $env:AE_EXECUTABLE
$processName  = $env:AE_PROCESS_NAME
$localAppData = $env:LOCALAPPDATA

$missing = @()
if (-not $executable)   { $missing += "AE_EXECUTABLE" }
if (-not $localAppData) { $missing += "LOCALAPPDATA (standard Windows env var)" }
if (-not $CreateFolderOnly) {
    # Only needed once we go on to launch the watcher / patch the config.
    if (-not $appDataPath) { $missing += "AE_APP_DATA" }
    if (-not $gameFolder)  { $missing += "AE_GAME_FOLDER" }
    if (-not $adapterDir)  { $missing += "AE_ADAPTER_DIR" }
    if (-not $processName) { $missing += "AE_PROCESS_NAME" }
}

if ($missing.Count -gt 0) {
    Write-Host "[ERROR] ea_origin_emulator\modify_joker_json.ps1: missing env var(s): $($missing -join ', ')"
    exit 1
}

# -- Read origin_helper.py's metadata file for the Steam appid --
# _origin_helper_meta.txt sits next to anadius.cfg, which write_config.ps1
# writes into the SELECTED EXE's own folder (which can be nested arbitrarily
# deep under the game root, e.g. 00_game\target_origin\ex\) - not
# $gameFolder itself, which is just the top-level game root.
$exeDir = Split-Path -Parent $executable
$steamAppId = $null
$metaPath = Join-Path $exeDir "_origin_helper_meta.txt"
if (Test-Path -LiteralPath $metaPath) {
    try {
        foreach ($line in (Get-Content -LiteralPath $metaPath -Encoding UTF8)) {
            if ($line -match '^steam_appid=(.*)$' -and $Matches[1]) { $steamAppId = $Matches[1].Trim() }
        }
    } catch {
        Write-Host "[WARN] Could not read $metaPath : $_"
    }
    # Nothing else reads this file after this point - clean it up rather
    # than leaving it sitting in the user's actual game folder.
    # Leave the meta file in place during the early -CreateFolderOnly pass;
    # the real Step 12 pass reads it again and removes it then.
    if (-not $CreateFolderOnly) {
        try {
            Remove-Item -LiteralPath $metaPath -Force
        } catch {
            Write-Host "[WARN] Could not remove $metaPath : $_"
        }
    }
} else {
    Write-Host "[WARN] $metaPath not found - was write_config.ps1 run first?"
}

if (-not $steamAppId) {
    Write-Host "[WARN] No Steam appid available - the game may not have a cross-listed Steam release,"
    Write-Host "[WARN] or the achievements step was skipped. Falling back to '0'."
    $steamAppId = "0"
} else {
    Write-Host "[INFO] Steam appid from metadata: $steamAppId"
}

$savePath = Join-Path $localAppData "anadius\LSX emu\achievement_watcher\$steamAppId"

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

# -- Launch the shared detached background watcher --
$configsDir    = Join-Path $appDataPath "Achievements\configs"
$commonDir     = Join-Path (Split-Path -Parent (Split-Path -Parent $adapterDir)) "core\common"
$watcherScript = Join-Path $commonDir "watch_and_patch_joker_config.ps1"

if (-not (Test-Path -LiteralPath $watcherScript)) {
    Write-Host "[ERROR] $watcherScript not found - cannot patch Jokerverse's config once it appears."
    exit 1
}

try {
    # A single, explicitly-quoted string rather than an array: Start-Process
    # -ArgumentList's array-to-command-line conversion has known inconsistent
    # quoting behavior across PowerShell versions when a value contains
    # spaces (near-certain here - $executable/$configsDir are real Windows
    # paths). An unquoted space would split that value into multiple
    # arguments in the child process's command line, breaking its own
    # parameter binding.
    $argString = "-NoProfile -ExecutionPolicy Bypass -File `"$watcherScript`" " +
                 "-ConfigsDir `"$configsDir`" -AppId `"$steamAppId`" " +
                 "-Executable `"$executable`" -ProcessName `"$processName`""

    Start-Process -FilePath "powershell.exe" -WindowStyle Hidden -ArgumentList $argString
    Write-Host "[INFO] Launched background watcher for Jokerverse config (appid $steamAppId) - it will patch"
    Write-Host "[INFO] executable/process_name whenever Jokerverse creates or rewrites that config, for up to 3 minutes."
} catch {
    Write-Host "[ERROR] Failed to launch background watcher: $_"
    exit 1
}
