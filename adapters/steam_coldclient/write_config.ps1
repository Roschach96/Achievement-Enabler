# adapters\steam_coldclient\write_config.ps1
#
# Builds the _ColdClient folder for one game: copies the base Goldberg
# template, drops in the generated achievement data, injects global unlock
# percentages, patches ColdClientLoader.ini and applies the notification
# (overlay) mode from NotificationSettings.txt.
#
# All inputs come in via env vars set by AchievementEnabler.bat:
#
#   AE_GAME_FOLDER        - game root (where "release" and "generate_emu_config" live)
#   AE_APP_ID             - Steam AppID
#   AE_ADAPTER_DIR        - full path to adapters\steam_coldclient (this folder)
#   AE_COLD_CLIENT_PATH   - full path to the game's _ColdClient folder (destination)
#   AE_LOADER_EXE         - steamclient_loader_x64.exe or steamclient_loader_x86.exe
#   AE_EXE_PATH_RELATIVE  - value to place in ColdClientLoader.ini's Exe=
#   AE_LAUNCH_ARGS        - launch args parsed from the manifest (may be empty)
#   AE_GBE_TAG            - GBE Fork release tag in use
#   AE_GBE_VARIANT        - vs22 or vs26
#   AE_GBE_CACHE_DIR      - %SystemDrive%\steamcmd\_GBE fork
#   AE_STATE_DIR          - %SystemDrive%\steamcmd\_AchievementEnabler

$gameFolder     = $env:AE_GAME_FOLDER
$appId          = $env:AE_APP_ID
$adapterDir     = $env:AE_ADAPTER_DIR
$coldClientPath = $env:AE_COLD_CLIENT_PATH
$loaderExe      = $env:AE_LOADER_EXE
$exeRelative    = $env:AE_EXE_PATH_RELATIVE
$launchArgs     = $env:AE_LAUNCH_ARGS

$missing = @()
if (-not $gameFolder)     { $missing += "AE_GAME_FOLDER" }
if (-not $appId)          { $missing += "AE_APP_ID" }
if (-not $adapterDir)     { $missing += "AE_ADAPTER_DIR" }
if (-not $coldClientPath) { $missing += "AE_COLD_CLIENT_PATH" }

if ($missing.Count -gt 0) {
    Write-Host "[ERROR] steam_coldclient\write_config.ps1: missing env var(s): $($missing -join ', ')"
    exit 1
}

$steamSettings = Join-Path $coldClientPath "steam_settings"
$outputDir = if ($env:AE_GEC_OUT_DIR) { $env:AE_GEC_OUT_DIR } else { Join-Path $gameFolder "generate_emu_config\_OUTPUT\$appId" }

# ── Step 1: fresh _ColdClient scaffold from the GBE Fork template ─────────
if (Test-Path -LiteralPath $coldClientPath) {
    Remove-Item -LiteralPath $coldClientPath -Recurse -Force
}
New-Item -ItemType Directory -Path $coldClientPath -Force | Out-Null

$templateDir = Join-Path $gameFolder "release\steamclient_experimental"
if (Test-Path -LiteralPath $templateDir) {
    Copy-Item -Path (Join-Path $templateDir '*') -Destination $coldClientPath -Recurse -Force
    Write-Host "[INFO] Copied Goldberg base template into: $coldClientPath"
} else {
    Write-Host "[WARN] Base template not found: $templateDir"
}

if ($loaderExe -eq 'steamclient_loader_x64.exe') {
    $unused = Join-Path $coldClientPath 'steamclient_loader_x86.exe'
} else {
    $unused = Join-Path $coldClientPath 'steamclient_loader_x64.exe'
}
if (Test-Path -LiteralPath $unused) {
    Remove-Item -LiteralPath $unused -Force
    Write-Host "[INFO] Deleted unused $(Split-Path -Leaf $unused)"
}

if (-not (Test-Path -LiteralPath $steamSettings)) {
    New-Item -ItemType Directory -Path $steamSettings -Force | Out-Null
}

# ── Step 1b: "SteamStub avoider" DLLs (Goldberg-family only) ───────────────
# steamstub_x32.dll / steamstub_x64.dll ship inside adapters\steam_coldclient\
# (next to this script) - never in the game folder or in a shared template -
# since they're only ever needed for this adapter.
$extraDlls = Join-Path $coldClientPath "extra_dlls"
if (-not (Test-Path -LiteralPath $extraDlls)) {
    New-Item -ItemType Directory -Path $extraDlls -Force | Out-Null
}
$missingStubs = @()
foreach ($stub in @('steamstub_x32.dll', 'steamstub_x64.dll')) {
    $src = Join-Path $adapterDir $stub
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination $extraDlls -Force
        Write-Host "[INFO] Copied $stub into: $extraDlls"
    } else {
        Write-Host "[WARN] $stub not found at: $src (expected inside adapters\steam_coldclient\)"
        $missingStubs += $stub
    }
}

# ── Step 2: relocate steam_interfaces.txt if the orchestrator generated one ─
$interfacesFile = Join-Path $gameFolder "steam_interfaces.txt"
if (Test-Path -LiteralPath $interfacesFile) {
    Move-Item -LiteralPath $interfacesFile -Destination $steamSettings -Force
    Write-Host "[INFO] steam_interfaces.txt moved into: $steamSettings"
}

# ── Step 3: copy generated achievement data from generate_emu_config output ─
if (Test-Path -LiteralPath $outputDir) {
    $srcSettings = Join-Path $outputDir "steam_settings"
    # configs.main.ini / configs.overlay.ini are intentionally NOT copied - overlay
    # behaviour is decided by the notification mode in Step 6.
    $filesToCopy = @('achievements.json', 'configs.app.ini', 'stats.json', 'steam_appid.txt')
    foreach ($f in $filesToCopy) {
        $src = Join-Path $srcSettings $f
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination $steamSettings -Force
        }
    }
    foreach ($dir in @('img', 'controller')) {
        $src = Join-Path $srcSettings $dir
        if (Test-Path -LiteralPath $src) {
            Copy-Item -Path $src -Destination $steamSettings -Recurse -Force
        }
    }
    Write-Host "[INFO] Achievement data copied from: $outputDir"
} else {
    Write-Host "[WARN] generate_emu_config output not found for AppID $appId - achievements may be missing."
}

# ── Step 3b: write the GBE Fork version tag ────────────────────────────────
$gbeTag = $env:AE_GBE_TAG
if ($gbeTag) {
    Set-Content -LiteralPath (Join-Path $coldClientPath 'version.txt') -Value $gbeTag
    Write-Host "[INFO] GBE Fork version written to: $(Join-Path $coldClientPath 'version.txt'): $gbeTag"
} else {
    Write-Host "[WARN] AE_GBE_TAG not set - skipping version.txt"
}

# ── Step 4: inject global unlock percentages into the copied achievements.json ─
$achievementsJson = Join-Path $steamSettings "achievements.json"
$percentScript    = Join-Path $adapterDir "generate_achievement_percentages.ps1"
if ((Test-Path -LiteralPath $achievementsJson) -and (Test-Path -LiteralPath $percentScript)) {
    & $percentScript -AppId $appId -AchievementsJsonPath $achievementsJson -InjectInPlace
}

# ── Step 5: patch ColdClientLoader.ini ─────────────────────────────────────
$iniPath = Join-Path $coldClientPath "ColdClientLoader.ini"

if (Test-Path -LiteralPath $iniPath) {
    try {
        $content = Get-Content -LiteralPath $iniPath
        $content = $content -replace '^Exe=.*', "Exe=$exeRelative"
        $content = $content -replace '^AppId=.*', "AppId=$appId"
        if ($launchArgs) {
            $content = $content -replace '^ExeCommandLine=.*', "ExeCommandLine=$launchArgs"
        }
        Set-Content -LiteralPath $iniPath -Value $content

        $content2 = Get-Content -LiteralPath $iniPath
        if ($content2 -match '^DllsToInjectFolder=$') {
            $content2 = $content2 -replace '^DllsToInjectFolder=$', 'DllsToInjectFolder=extra_dlls'
            Set-Content -LiteralPath $iniPath -Value $content2
            Write-Host "[INFO] DllsToInjectFolder corrected to extra_dlls"
        }

        Write-Host "[INFO] Patched: $iniPath"
    } catch {
        Write-Host "[ERROR] Failed to patch ColdClientLoader.ini: $_"
        exit 1
    }
} else {
    Write-Host "[WARN] ColdClientLoader.ini not found at: $iniPath"
}

# ── Step 6: achievement notification mode (GBE overlay vs Achievements app) ─
# Mode is stored once in %SystemDrive%\steamcmd\_AchievementEnabler\NotificationSettings.txt:
#   1 = Only the Achievements (Jokerverse) app  -> global overlay ini: enable_experimental_overlay=0 (created from EXAMPLE with hook_delay_sec=10 if missing)
#   2 = Both                                    -> global overlay ini: enable_experimental_overlay=1 (created from EXAMPLE with hook_delay_sec=10 if missing)
#   3 = Ask per game                            -> per-game overlay ini in _ColdClient\steam_settings\
# Global ini = %AppData%\GSE Saves\settings\configs.overlay.ini
# Whenever the overlay is on, a second question sets disable_achievement_progress
# (ProgressNotifications=1/0 in the same txt for mode 2; asked per game in mode 3).

function Get-OverlayExampleIni {
    $cacheDir = if ($env:AE_GBE_CACHE_DIR) { $env:AE_GBE_CACHE_DIR } else { Join-Path $env:SystemDrive 'steamcmd\_GBE fork' }
    $tag      = $env:AE_GBE_TAG
    $variant  = $env:AE_GBE_VARIANT
    $candidates = @()
    if ($tag -and $variant) {
        $candidates += Join-Path $cacheDir "gbe_fork\$tag\$variant\release\steam_settings.EXAMPLE\configs.overlay.EXAMPLE.ini"
    }
    $candidates += Join-Path $gameFolder 'release\steam_settings.EXAMPLE\configs.overlay.EXAMPLE.ini'
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    # Last resort: search the cached build (layout may change between GBE releases)
    $root = if ($tag -and $variant) { Join-Path $cacheDir "gbe_fork\$tag\$variant" } else { Join-Path $gameFolder 'release' }
    if (Test-Path -LiteralPath $root) {
        $hit = Get-ChildItem -LiteralPath $root -Recurse -Filter 'configs.overlay.EXAMPLE.ini' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

# UTF-8 without BOM (Windows PowerShell's -Encoding UTF8 adds one).
function Write-IniFile([string]$path, [string[]]$lines) {
    [System.IO.File]::WriteAllLines($path, $lines, (New-Object System.Text.UTF8Encoding($false)))
}

# Sets key=value in an ini line array; adds it under [overlay::general] (or appends) if missing.
function Set-IniValue([string[]]$lines, [string]$key, [string]$value) {
    $pattern = '^\s*' + [regex]::Escape($key) + '\s*='
    if ($lines -match $pattern) {
        return @($lines -replace ($pattern + '.*$'), "$key=$value")
    }
    $idx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -ieq '[overlay::general]') { $idx = $i; break } }
    if ($idx -lt 0) { return $lines + @('[overlay::general]', "$key=$value") }
    $before = @($lines[0..$idx])
    $after  = if ($idx + 1 -lt $lines.Count) { @($lines[($idx + 1)..($lines.Count - 1)]) } else { @() }
    return @($before + "$key=$value" + $after)
}

# Copies configs.overlay.EXAMPLE.ini to $dest with the given overlay value + hook_delay_sec=10.
function New-OverlayIni([string]$dest, [string]$enableValue) {
    $example = Get-OverlayExampleIni
    if (-not $example) {
        Write-Host "[WARN] configs.overlay.EXAMPLE.ini not found in the GBE Fork cache - creating a minimal configs.overlay.ini."
        $lines = @('[overlay::general]')
    } else {
        $lines = @(Get-Content -LiteralPath $example)
    }
    $lines = Set-IniValue $lines 'enable_experimental_overlay' $enableValue
    $lines = Set-IniValue $lines 'hook_delay_sec' '10'
    $dir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Write-IniFile $dest $lines
    Write-Host "[INFO] Created: $dest (enable_experimental_overlay=$enableValue, hook_delay_sec=10)"
}

# Asks whether the GBE overlay should show achievement progress. Returns
# the disable_achievement_progress value ('0' = show, '1' = hide).
function Read-ProgressChoice {
    Write-Host ""
    Write-Host "GBE experimental overlay - achievement progress notifications:"
    Write-Host "  1 - Show progress notifications"
    Write-Host "  2 - Don't show progress notifications"
    & choice.exe /C 12 /N /M "Select an option (1-2): "
    if ($LASTEXITCODE -eq 2) { return '1' } else { return '0' }
}

try {
    $stateDir = if ($env:AE_STATE_DIR) { $env:AE_STATE_DIR } else { Join-Path $env:SystemDrive 'steamcmd\_AchievementEnabler' }
    if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    $notifyFile = Join-Path $stateDir 'NotificationSettings.txt'

    $mode = $null
    $progress = $null   # 1 = show progress notifications, 0 = hide
    if (Test-Path -LiteralPath $notifyFile) {
        $m = Select-String -LiteralPath $notifyFile -Pattern '^\s*NotificationMode\s*=\s*([123])\s*$' | Select-Object -First 1
        if ($m) { $mode = $m.Matches[0].Groups[1].Value }
        $pm = Select-String -LiteralPath $notifyFile -Pattern '^\s*ProgressNotifications\s*=\s*([01])\s*$' | Select-Object -First 1
        if ($pm) { $progress = $pm.Matches[0].Groups[1].Value }
    }
    if (-not $mode) {
        Write-Host ""
        Write-Host "Achievement notifications for Steam (ColdClient) games:"
        Write-Host "  1 - Only the Achievements (Jokerverse) app notifications"
        Write-Host "  2 - Both (Achievements app + GBE experimental overlay)"
        Write-Host "  3 - Ask per game"
        & choice.exe /C 123 /N /M "Select an option (1-3): "
        $mode = [string]$LASTEXITCODE
        if ($mode -notin @('1','2','3')) { $mode = '1' }
        Set-Content -LiteralPath $notifyFile -Encoding ASCII -Value @(
            '# Achievement Enabler - notification mode for Steam (ColdClient) games',
            '# 1 = Only the Achievements (Jokerverse) app notifications',
            '# 2 = Both (Achievements app + GBE experimental overlay)',
            '# 3 = Ask per game',
            '# ProgressNotifications (mode 2 only): 1 = show GBE overlay progress, 0 = hide',
            '# Change the numbers below, or delete this file to be asked again.',
            "NotificationMode=$mode"
        )
        Write-Host "[INFO] Saved notification mode $mode to: $notifyFile"
    }

    $globalDir = Join-Path $env:APPDATA 'GSE Saves\settings'
    $globalIni = Join-Path $globalDir 'configs.overlay.ini'

    switch ($mode) {
        '1' {
            if (Test-Path -LiteralPath $globalIni) {
                $lines = Set-IniValue @(Get-Content -LiteralPath $globalIni) 'enable_experimental_overlay' '0'
                Write-IniFile $globalIni $lines
                Write-Host "[INFO] Notifications: Achievements app only (GBE overlay off) - $globalIni"
            } else {
                New-OverlayIni $globalIni '0'
            }
        }
        '2' {
            if (-not $progress) {
                $disable  = Read-ProgressChoice
                $progress = if ($disable -eq '1') { '0' } else { '1' }
                Add-Content -LiteralPath $notifyFile -Encoding ASCII -Value "ProgressNotifications=$progress"
                Write-Host "[INFO] Saved progress notification choice to: $notifyFile"
            }
            $disable = if ($progress -eq '1') { '0' } else { '1' }
            if (-not (Test-Path -LiteralPath $globalIni)) {
                New-OverlayIni $globalIni '1'
            }
            $lines = Set-IniValue @(Get-Content -LiteralPath $globalIni) 'enable_experimental_overlay' '1'
            $lines = Set-IniValue $lines 'disable_achievement_progress' $disable
            Write-IniFile $globalIni $lines
            Write-Host "[INFO] Notifications: both (GBE overlay on, disable_achievement_progress=$disable) - $globalIni"
        }
        '3' {
            Write-Host ""
            Write-Host "Achievement notifications for this game:"
            Write-Host "  1 - Only the Achievements (Jokerverse) app notifications"
            Write-Host "  2 - Both (Achievements app + GBE experimental overlay)"
            & choice.exe /C 12 /N /M "Select an option (1-2): "
            $enable = if ($LASTEXITCODE -eq 2) { '1' } else { '0' }
            $gameIni = Join-Path $steamSettings 'configs.overlay.ini'
            New-OverlayIni $gameIni $enable
            if ($enable -eq '1') {
                $disable = Read-ProgressChoice
                $lines = Set-IniValue @(Get-Content -LiteralPath $gameIni) 'disable_achievement_progress' $disable
                Write-IniFile $gameIni $lines
                Write-Host "[INFO] disable_achievement_progress=$disable - $gameIni"
            }
        }
    }
} catch {
    Write-Host "[WARN] Could not apply notification settings: $_"
}

# ── Step 7: delete files GBE Fork ships but this project doesn't need ──────
foreach ($leftover in @('dll_injection.EXAMPLE')) {
    $p = Join-Path $coldClientPath $leftover
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
}
$readme = Join-Path $coldClientPath 'README.experimental_steamclient.md'
if (Test-Path -LiteralPath $readme) { Remove-Item -LiteralPath $readme -Force }

# ---------------------------------------------------------------------------
# Step 8 (best-effort, never fatal): Denuvo token recycler -> configs.user.ini
# Finds whichever local Steam account has a Denuvo token for this AppID
# (newest wins) and writes account_steamid into configs.user.ini.
# Wrapped in a function so its early "return"s only skip this optional step -
# they must NOT terminate the whole script, since mandatory steps (the
# UserData symlink, AE_FINAL_EXECUTABLE) run after it.
# ---------------------------------------------------------------------------
function Set-DenuvoConfigsUserIni {
    if (-not (Test-Path -LiteralPath $steamSettings)) {
        Write-Host "[WARN] configs.user.ini skipped - steam_settings folder not found: $steamSettings"
        return
    }

    $steamPath = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Valve\Steam" -ErrorAction SilentlyContinue).InstallPath
    if (-not $steamPath) {
        $steamPath = (Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam" -ErrorAction SilentlyContinue).InstallPath
    }
    if (-not $steamPath) {
        Write-Host "[WARN] configs.user.ini skipped - Steam installation not found in registry."
        return
    }

    $userdataPath = Join-Path $steamPath 'userdata'
    if (-not (Test-Path -LiteralPath $userdataPath)) {
        Write-Host "[WARN] configs.user.ini skipped - userdata folder not found: $userdataPath"
        return
    }

    $best = $null
    $userFolders = Get-ChildItem -LiteralPath $userdataPath -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+$' }

    foreach ($userFolder in $userFolders) {
        $appFolder = Join-Path $userFolder.FullName $appId
        if (-not (Test-Path -LiteralPath $appFolder)) { continue }

        $tokenFile = Get-ChildItem -LiteralPath $appFolder -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -eq '' } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if (-not $tokenFile) { continue }

        if (-not $best -or $tokenFile.LastWriteTime -gt $best.LastWriteTime) {
            $best = [PSCustomObject]@{
                SteamUserId   = $userFolder.Name
                LastWriteTime = $tokenFile.LastWriteTime
            }
        }
    }

    if (-not $best) {
        Write-Host "[INFO] configs.user.ini skipped - no local Denuvo token found for AppID $appId."
        return
    }

    $base      = [uint64]::Parse('76561197960265728')
    $uid       = [uint64]::Parse($best.SteamUserId)
    $steamId64 = ($base + $uid).ToString()

    $iniOutPath = Join-Path $steamSettings 'configs.user.ini'
    $iniContent = "[user::general]`r`naccount_steamid=$steamId64"

    try {
        [System.IO.File]::WriteAllText($iniOutPath, $iniContent, [System.Text.Encoding]::UTF8)
        Write-Host "[INFO] configs.user.ini written with Steam ID64 $steamId64 -> $iniOutPath"
    } catch {
        Write-Host "[WARN] configs.user.ini skipped - failed to write file: $_"
    }
}
Set-DenuvoConfigsUserIni

# ---------------------------------------------------------------------------
# Step 9 (MANDATORY): "UserData symbolic link for D tokens.ps1" - creates a
# junction at _ColdClient\userdata pointing at the real Steam userdata
# folder, so ColdClient can see existing Denuvo tokens/stats on drives other
# than the Steam install drive. Ships inside adapters\steam_coldclient\
# (next to this script); copied into _ColdClient, run from there (it needs
# to run with its own folder as the junction location), then deleted.
# This always runs, independent of whether a Denuvo token was found above.
# ---------------------------------------------------------------------------
$symlinkScriptName = 'UserData_symbolic_link_for_D_tokens.ps1'
$symlinkScriptSrc  = Join-Path $adapterDir $symlinkScriptName
$symlinkScriptDst  = Join-Path $coldClientPath $symlinkScriptName

if (Test-Path -LiteralPath $symlinkScriptSrc) {
    Copy-Item -LiteralPath $symlinkScriptSrc -Destination $symlinkScriptDst -Force
    Write-Host "[INFO] Running UserData symbolic link script..."
    Push-Location $coldClientPath
    try {
        & powershell -ExecutionPolicy Bypass -File $symlinkScriptDst
    } catch {
        Write-Host "[WARN] UserData symbolic link script failed: $_"
    } finally {
        Pop-Location
    }
    Remove-Item -LiteralPath $symlinkScriptDst -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "[WARN] '$symlinkScriptName' not found at: $symlinkScriptSrc (expected inside adapters\steam_coldclient\)"
}

# ---------------------------------------------------------------------------
# Tell the orchestrator what "the executable that actually launches this
# game" is, for use in the Jokerverse export and the desktop shortcut. For
# Goldberg that's the ColdClient loader, not the game's own exe.
# ---------------------------------------------------------------------------
$finalExe = Join-Path $coldClientPath $loaderExe
[System.IO.File]::WriteAllLines(
    (Join-Path $gameFolder "_ae_final_exe.cmd"),
    @("set `"AE_FINAL_EXECUTABLE=$finalExe`""),
    [System.Text.Encoding]::ASCII
)

if ($missingStubs.Count -gt 0) {
    [System.IO.File]::WriteAllLines(
        (Join-Path $gameFolder "_ae_missing_stubs.cmd"),
        @("set `"AE_MISSING_STUBS=$($missingStubs -join ' ')`""),
        [System.Text.Encoding]::ASCII
    )
}

exit 0