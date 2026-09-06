# adapters\epic_nemirtingas_epic_emulator\deploy_nemir_epic_emu.ps1
# Backs up the game's existing EOSSDK loader DLL (whatever crack/loader
# find_paths.ps1 found already in place) to <name>.BAK on first run, then
# deploys the matching _no_network variant from the downloaded release in
# its place. Also copies nepice_settings config (NemirtingasEpicEmu.json +
# achievements_db.json + achievement images, if write_config.ps1's
# achievements fetch step succeeded) into the game folder, patches
# NemirtingasEpicEmu.json's AppId with the Epic namespace, and
# writes/renames the Launch *.bat exchange-code launcher.
#
# Dot-sourced by write_config.ps1 - defines Invoke-DeployNemirEpicEmu only.

function Invoke-DeployNemirEpicEmu {
    param(
        [Parameter(Mandatory)][string]$GameRoot,
        [Parameter(Mandatory)][string]$SourceReleaseDir,
        [Parameter(Mandatory)][string]$AdapterDir,
        [Parameter(Mandatory)][string]$GameName,
        [Parameter(Mandatory)][string]$Namespace,
        [string]$DllFolderRel = '',
        [string]$ExeRel = '',
        [string]$ExistingDllRel = '',
        [string]$AchievementsOutputDir = ''
    )

    $ErrorActionPreference = 'Stop'

    $destination = if ($DllFolderRel) { Join-Path $GameRoot $DllFolderRel } else { $GameRoot }
    if (-not (Test-Path -LiteralPath $destination)) {
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
    }

    # ---- Determine which bitness/variant to deploy ---------------------------
    # ExistingDllRel is whatever loader DLL find_paths.ps1 found already
    # sitting in the game folder (e.g. a crack's EOSSDK-Win64-Shipping.dll).
    # Use its filename to pick the matching bitness, defaulting to Win64 if
    # nothing was found (fresh install, no prior loader).
    $existingDllName = if ($ExistingDllRel) { Split-Path -Leaf $ExistingDllRel } else { '' }
    $isWin32 = $existingDllName -match '(?i)Win32'
    $plainName      = if ($isWin32) { 'EOSSDK-Win32-Shipping.dll' }              else { 'EOSSDK-Win64-Shipping.dll' }
    $noNetworkName  = if ($isWin32) { 'EOSSDK-Win32-Shipping.dll_no_network' }   else { 'EOSSDK-Win64-Shipping.dll_no_network' }
    if (-not $existingDllName) { $existingDllName = $plainName }

    # ---- Back up the existing loader DLL (first run only) ---------------------
    $existingDllPath = Join-Path $destination $existingDllName
    $bakPath = "$existingDllPath.BAK"
    if (Test-Path -LiteralPath $existingDllPath) {
        if (-not (Test-Path -LiteralPath $bakPath)) {
            Rename-Item -LiteralPath $existingDllPath -NewName "$existingDllName.BAK"
            Write-Host "[INFO] Backed up existing loader: $existingDllName -> $existingDllName.BAK"
        } else {
            Write-Host "[INFO] Backup already exists ($existingDllName.BAK) - leaving it as-is, removing current loader before deploying replacement."
            Remove-Item -LiteralPath $existingDllPath -Force
        }
    } elseif (Test-Path -LiteralPath $bakPath) {
        Write-Host "[INFO] Backup already exists ($existingDllName.BAK) - no current loader to remove."
    }

    # ---- Copy the _no_network loader DLL --------------------------------------
    # SourceReleaseDir contains ALL variant subfolders (plain / _no_network /
    # _nucleuscoop x Win64/Win32/Linux/LinuxArm64/Mac), since
    # download_nemir_epic_emu.ps1 fetches every asset by default. Target the
    # exact _no_network variant folder for the detected bitness.
    $noNetworkVariantDir = Join-Path $SourceReleaseDir "$plainName`_no_network"
    $dllSource = Get-ChildItem -LiteralPath $noNetworkVariantDir -Filter $noNetworkName -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $dllSource) {
        # Fallback: recursive search, in case SourceReleaseDir is a single
        # variant folder directly (a caller passed a narrower -AssetPattern
        # to the downloader) rather than the full release root.
        $dllSource = Get-ChildItem -LiteralPath $SourceReleaseDir -Filter $noNetworkName -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }
    if ($dllSource) {
        Copy-Item -LiteralPath $dllSource.FullName -Destination $existingDllPath -Force
        Write-Host "[INFO] Deployed $noNetworkName as $existingDllName to: $destination"
    } else {
        Write-Host "[WARN] No $noNetworkName found under: $SourceReleaseDir"
    }

    # ---- Copy NemirtingasEpicEmu.json template into place ---------------------
    $settingsSrc = $AdapterDir
    $settingsDst = Join-Path $destination 'nepice_settings'
    if (Test-Path -LiteralPath (Join-Path $settingsSrc 'NemirtingasEpicEmu.json')) {
        if (-not (Test-Path -LiteralPath $settingsDst)) {
            New-Item -ItemType Directory -Path $settingsDst -Force | Out-Null
        }
        Copy-Item -LiteralPath (Join-Path $settingsSrc 'NemirtingasEpicEmu.json') -Destination $settingsDst -Force
        Write-Host "[INFO] Copied NemirtingasEpicEmu.json to: $settingsDst"
    }

    # ---- Copy achievements_db.json + achievement images into nepice_settings -
    # AchievementsOutputDir is jokerverse_fetch_epic_achievements.bat's own
    # "epic_output" folder (achievements_db.json + achievements_images\),
    # produced by write_config.ps1 calling that .bat with the resolved
    # namespace. Empty/missing means the fetch didn't run or failed - skip
    # quietly, the rest of the deploy still succeeds without achievement data.
    if ($AchievementsOutputDir -and (Test-Path -LiteralPath $AchievementsOutputDir)) {
        if (-not (Test-Path -LiteralPath $settingsDst)) {
            New-Item -ItemType Directory -Path $settingsDst -Force | Out-Null
        }

        $achievementsDbSrc = Join-Path $AchievementsOutputDir 'achievements_db.json'
        if (Test-Path -LiteralPath $achievementsDbSrc) {
            Copy-Item -LiteralPath $achievementsDbSrc -Destination $settingsDst -Force
            Write-Host "[INFO] Copied achievements_db.json to: $settingsDst"
        } else {
            Write-Host "[WARN] achievements_db.json not found under: $AchievementsOutputDir"
        }

        $imagesSrc = Join-Path $AchievementsOutputDir 'achievements_images'
        if (Test-Path -LiteralPath $imagesSrc) {
            $imagesDst = Join-Path $settingsDst 'achievements_images'
            if (-not (Test-Path -LiteralPath $imagesDst)) {
                New-Item -ItemType Directory -Path $imagesDst -Force | Out-Null
            }
            Copy-Item -Path (Join-Path $imagesSrc '*') -Destination $imagesDst -Recurse -Force
            Write-Host "[INFO] Copied achievement images to: $imagesDst"
        } else {
            Write-Host "[WARN] achievements_images folder not found under: $AchievementsOutputDir"
        }
    } else {
        Write-Host "[INFO] No achievements data to copy (fetch step did not run or produced nothing)."
    }

    # ---- Patch NemirtingasEpicEmu.json: AppId = namespace --------------------
    $jsonPath = Join-Path $settingsDst 'NemirtingasEpicEmu.json'
    if (Test-Path -LiteralPath $jsonPath) {
        $json = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
        $json.EOSEmu.Application.AppId = $Namespace
        $output = $json | ConvertTo-Json -Depth 20
        [System.IO.File]::WriteAllText($jsonPath, $output, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "[INFO] Updated AppId in: $jsonPath"
    } else {
        Write-Host "[WARN] NemirtingasEpicEmu.json not found at: $jsonPath"
    }

    # ---- Write the Launch *.bat exchange-code launcher next to the exe -------
    $exeName = if ($ExeRel) { $ExeRel } else { '' }
    $exeDir  = if ($ExeRel) { Join-Path $GameRoot (Split-Path -Parent $ExeRel) } else { $GameRoot }
    if ([string]::IsNullOrWhiteSpace($exeDir)) { $exeDir = $GameRoot }
    $exeLeaf = if ($ExeRel) { Split-Path -Leaf $ExeRel } else { '' }

    $invalidFileChars = [IO.Path]::GetInvalidFileNameChars()
    $safeGameName = ($GameName.ToCharArray() | ForEach-Object {
        if ($invalidFileChars -contains $_) { '_' } else { $_ }
    }) -join ''

    $launchPath = Join-Path $exeDir "Launch $safeGameName.bat"
    $launchContent = @"
@echo off
cd /d "%~dp0"
start /b "$GameName" "$exeLeaf" -AUTH_LOGIN=unused -AUTH_PASSWORD=cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd -AUTH_TYPE=exchangecode -epicapp=$Namespace -epicenv=Prod -EpicPortal -epicusername="Player" -epicuserid=4340353b292a150000e7d9b5a47b6343 -epicsandboxid=$Namespace -epiclocale=en
"@
    [System.IO.File]::WriteAllText($launchPath, $launchContent, (New-Object System.Text.ASCIIEncoding))
    Write-Host "[INFO] Wrote launcher: $launchPath"

    return [PSCustomObject]@{
        Destination = $destination
        LaunchBat   = $launchPath
    }
}