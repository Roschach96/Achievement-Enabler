@echo off
setlocal EnableDelayedExpansion

REM ============================================================================
REM AchievementEnabler.bat
REM
REM Single entry point that replaces the old separate Goldberg/ColdClient and
REM Uplay R2 semi-auto setup scripts. Shared steps (download tools, detect
REM AppID, fetch the Steam manifest, parse launch args, generate achievement
REM data, Achievement Watcher export, Jokerverse export, cleanup) run exactly
REM once here. Everything that differs between emulators lives in
REM adapters\<id>\ and is invoked through five fixed hooks:
REM
REM   find_paths.ps1                    - locate the game exe + loader DLL
REM   write_config.ps1                  - write the emulator's own config files
REM   modify_joker_json.ps1             - fill in the Jokerverse Achievements JSON
REM   generate_achievement_percentages.ps1 - global unlock % (shared call signature)
REM   make_shortcut.ps1                 - create the desktop shortcut
REM
REM The Steam-schema chain (dummy credentials, steam_appid.txt/Steam Store
REM AppID lookup, SteamCMD manifest fetch, generate_emu_config achievement
REM data) is Steam-only. It is skipped entirely whenever AE_STEAM_SCHEMA=0,
REM which is set right after adapter selection for any non-Steam adapter:
REM   - gog_universelan looks up its own GOG App ID from goggame-*.info
REM     inside modify_joker_json.ps1
REM   - epic_nemirtingas_epic_emulator looks up its Epic namespace/sandboxId
REM     from egdata.app inside write_config.ps1
REM Both handle their own achievement data separately.
REM
REM To support a new emulator later: add adapters\<new_id>\ with those five
REM scripts, an adapter.json (id/name/priority/detect.asset_folder_glob), and
REM a GameSample.json. If it also has no Steam schema, add one line next to
REM the other AE_STEAM_SCHEMA=0 assignments below. Nothing else in this file
REM needs to change.
REM ============================================================================

set "TOOLS_DIR=%~dp0"
pushd "%TOOLS_DIR%"
if errorlevel 1 (
    echo [ERROR] Could not switch to script folder: !TOOLS_DIR!
    pause
    exit /b 1
)
set "gameFolder=%CD%"
set "CORE_DIR=%TOOLS_DIR%core"
set "COMMON_DIR=%CORE_DIR%\common"
set "ADAPTERS_ROOT=%TOOLS_DIR%adapters"

goto :main

REM ============================================================================
:main
REM ============================================================================

echo ========================================
echo    Achievement Enabler
echo ========================================
echo.
echo This tool patches a game folder to enable achievements.
echo.

for /f "delims=" %%T in ('powershell -NoProfile -Command "(Get-Item -LiteralPath '%~f0').LastWriteTimeUtc.ToString('o')"') do set "SCRIPT_MTIME=%%T"

REM ========================================
REM Kick off the update check in the background - non-blocking.
REM Once a %AE_STATE_DIR%\<tag>\ marker folder exists, compares against
REM that tag's position in the release list. Until then (first run, no
REM marker yet), falls back to comparing this .bat file's own last-modified
REM date against each release's publish date.
REM ========================================
set "AE_STATE_DIR=%SystemDrive%\steamcmd\_AchievementEnabler"
if not exist "%AE_STATE_DIR%" md "%AE_STATE_DIR%" >nul 2>&1

REM ========================================
REM Backup folder: where the updater copies the latest downloaded
REM release so the script always knows the "current version" is whatever
REM sits in %AE_STATE_DIR%. Asked once, then cached in a config file.
REM ========================================
set "AE_BACKUP_CONFIG=%AE_STATE_DIR%\backup_folder.cfg"
set "AE_BACKUP_DIR="
if exist "%AE_BACKUP_CONFIG%" (
    for /f "usebackq delims=" %%B in ("%AE_BACKUP_CONFIG%") do set "AE_BACKUP_DIR=%%B"
)
if not defined AE_BACKUP_DIR (
    echo.
    set /p "AE_BACKUP_DIR=Enter the Backup folder for Achievement Enabler (used to keep/update your copy of the script): "
    if not defined AE_BACKUP_DIR (
        echo [ERROR] A Backup folder is required. Rerun the script and provide one.
        pause
        exit /b 1
    )
    call :SaveBackupDir
)
goto :after_backup_dir_setup

:SaveBackupDir
if not exist "!AE_BACKUP_DIR!" md "!AE_BACKUP_DIR!" >nul 2>&1
>"%AE_BACKUP_CONFIG%" echo !AE_BACKUP_DIR!
exit /b 0
:after_backup_dir_setup

set "UPDATE_RESULT_CMD=%AE_STATE_DIR%\ae_update_check_result.cmd"
set "UPDATE_CHANGELOG_FILE=%AE_STATE_DIR%\ae_update_changelog.txt"
set "UPDATE_LOG=%AE_STATE_DIR%\ae_update_check.log"
if exist "%UPDATE_RESULT_CMD%" del /Q "%UPDATE_RESULT_CMD%" >nul 2>&1
set "UPDATE_SKIP_FILE=%AE_STATE_DIR%\Achievement Enabler skipped versions.txt"

REM Current installed tag = the newest %AE_STATE_DIR%\<tag>\ marker folder
REM that exists on disk (tags sort latest-first by folder LastWriteTime,
REM since a marker is only ever created for a tag just seen/skipped).
REM No marker folders yet -> "unknown", so check_update.py falls back to
REM comparing --current-mtime against each release's publish date instead
REM (old method, used only until the first marker folder is created).
set "AE_CURRENT_TAG=unknown"
for /f "delims=" %%D in ('dir /B /AD /O:-D "%AE_STATE_DIR%" 2^>nul') do (
    if not defined AE_CURRENT_TAG_FOUND (
        set "AE_CURRENT_TAG=%%D"
        set "AE_CURRENT_TAG_FOUND=1"
    )
)

REM ========================================
REM First run: no %AE_STATE_DIR%\<tag>\ folder exists yet, so there is no
REM baseline to compare against. Rather than starting from "unknown" and
REM only catching up on the NEXT run, fetch the latest release right now
REM (synchronously - this has to finish before anything below can rely on
REM a known-current script version) and apply it, so this run already has
REM a real starting point on disk.
REM ========================================
if not defined AE_CURRENT_TAG_FOUND (
    echo.
    echo [INFO] No installed version on record yet - fetching the latest release to establish one...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; try { $h=@{'User-Agent'='AchievementEnablerSetup'}; $r=Invoke-RestMethod -Headers $h -Uri 'https://api.github.com/repos/Roschach96/Achievement-Enabler/releases/latest'; Write-Output $r.tag_name } catch { exit 1 }" >"%TEMP%\ae_bootstrap_tag.txt" 2>nul
    set "AE_BOOTSTRAP_QUERY_OK=!errorlevel!"
    if "!AE_BOOTSTRAP_QUERY_OK!"=="0" call :ApplyBootstrap
    if not "!AE_BOOTSTRAP_QUERY_OK!"=="0" echo [WARN] Could not reach GitHub to determine the latest release. Continuing with "unknown" - will retry next run.
    del "%TEMP%\ae_bootstrap_tag.txt" >nul 2>&1
)
goto :after_bootstrap

:ApplyBootstrap
set /p "AE_BOOTSTRAP_TAG=" <"%TEMP%\ae_bootstrap_tag.txt"
if not defined AE_BOOTSTRAP_TAG exit /b 0
call "%COMMON_DIR%\download_helpers.bat" FetchSelfUpdate "!AE_BOOTSTRAP_TAG!" "!AE_STATE_DIR!" "!AE_BACKUP_DIR!"
if errorlevel 1 (
    echo [WARN] Bootstrap download of !AE_BOOTSTRAP_TAG! failed. Continuing with "unknown" - will retry next run.
) else (
    set "AE_CURRENT_TAG=!AE_BOOTSTRAP_TAG!"
    echo [INFO] Established !AE_BOOTSTRAP_TAG! as the current version. Copied to Backup folder: !AE_BACKUP_DIR!
)
exit /b 0
:after_bootstrap

set "UC_PY="
set "UC_PY_ARG="
where py >nul 2>&1 && (set "UC_PY=py" & set "UC_PY_ARG=-3")
if not defined UC_PY (
    where python >nul 2>&1 && set "UC_PY=python"
)
set "UC_STARTED=0"
if defined UC_PY (
    start "" /B "%UC_PY%" %UC_PY_ARG% "%COMMON_DIR%\check_update.py" --current-tag "%AE_CURRENT_TAG%" --current-mtime "%SCRIPT_MTIME%" --result-file "%UPDATE_RESULT_CMD%" --changelog-file "%UPDATE_CHANGELOG_FILE%" --skip-file "%UPDATE_SKIP_FILE%" >"%UPDATE_LOG%" 2>&1
    set "UC_STARTED=1"
)
set "UC_PY="
set "UC_PY_ARG="

if not exist "%SystemDrive%\steamcmd" mkdir "%SystemDrive%\steamcmd"

if not exist "%AE_STATE_DIR%\AntivirusWarningDisplayed.txt" (
    copy /b NUL "%AE_STATE_DIR%\AntivirusWarningDisplayed.txt" >nul
    echo.
    echo [WARNING] Please add %SystemDrive%\steamcmd and all folders that contain your games to your Antivirus exception list.
    echo [WARNING] This warning will not be displayed again.
    echo [WARNING] After the above steps, rerun the script.
    echo.
    pause
    exit /b 1
)

REM ========================================
REM STEP 1: Pick an adapter (Goldberg / Uplay R2 / whatever else is installed)
REM ========================================
echo Detecting which emulator adapter applies to this game...
if exist "%gameFolder%\_ae_adapter.cmd" del /Q "%gameFolder%\_ae_adapter.cmd"
powershell -NoProfile -ExecutionPolicy Bypass -File "%COMMON_DIR%\select_adapter.ps1" -AdaptersRoot "%ADAPTERS_ROOT%" -CoreRoot "%CORE_DIR%" -GameFolder "%gameFolder%"
if not exist "%gameFolder%\_ae_adapter.cmd" (
    echo [ERROR] Could not determine an adapter to use. Aborting.
    pause
    exit /b 1
)
call "%gameFolder%\_ae_adapter.cmd"
del /Q "%gameFolder%\_ae_adapter.cmd"
echo [INFO] Using adapter: %AE_ADAPTER_NAME%  (id: %AE_ADAPTER_ID%)
echo.

REM ========================================
REM Non-Steam adapters (no Steam schema/manifest to fetch - they resolve
REM their own App ID and achievement data independently) are listed here
REM once. Every downstream Steam-only step gates on AE_STEAM_SCHEMA instead
REM of repeating an adapter-id check, so adding another non-Steam adapter
REM later only requires editing this one line.
REM ========================================
set "AE_STEAM_SCHEMA=1"
if "%AE_ADAPTER_ID%"=="gog_universelan" set "AE_STEAM_SCHEMA=0"
if "%AE_ADAPTER_ID%"=="epic_nemirtingas_epic_emulator" set "AE_STEAM_SCHEMA=0"
if "%AE_ADAPTER_ID%"=="ea_origin_emulator" set "AE_STEAM_SCHEMA=0"

REM ========================================
REM STEP 1b: Automatic crack-state pre-flight checks (no user prompt)
REM Search excludes core\ and adapters\ - our own shipped ubisoft_uplay_r2
REM asset pack contains template copies of uplay_r2.ini/upc_r2.ini, which
REM would otherwise always false-positive this check.
REM ========================================
if "%AE_ADAPTER_ID%"=="ubisoft_uplay_r2" (
    set "AE_CRACK_FOUND="
    for /f "delims=" %%F in ('dir /s /b uplay_r2.ini upc_r2.ini 2^>nul ^| findstr /I /V /C:"\adapters\" /C:"\core\"') do set "AE_CRACK_FOUND=1"
    if not defined AE_CRACK_FOUND (
        echo [ERROR] uplay_r2.ini / upc_r2.ini not found in the game folder.
        echo [ERROR] This Ubisoft game does not appear to be cracked yet.
        echo [ERROR] Please apply the crack files, then rerun this script.
        pause
        exit /b 1
    )
    echo [INFO] Crack files detected ^(uplay_r2.ini / upc_r2.ini^) - proceeding.
    echo.
)
if "%AE_ADAPTER_ID%"=="ubisoft_uplay_r1" (
    set "AE_CRACK_FOUND="
    for /f "delims=" %%F in ('dir /s /b uplay_r1.ini upc_r1.ini 2^>nul ^| findstr /I /V /C:"\adapters\" /C:"\core\"') do set "AE_CRACK_FOUND=1"
    if not defined AE_CRACK_FOUND (
        echo [ERROR] uplay_r1.ini / upc_r1.ini not found in the game folder.
        echo [ERROR] This Ubisoft game does not appear to be cracked yet.
        echo [ERROR] Please apply the crack files, then rerun this script.
        pause
        exit /b 1
    )
    echo [INFO] Crack files detected ^(uplay_r1.ini / upc_r1.ini^) - proceeding.
    echo.
)
set "VOICES38=0"
if "%AE_ADAPTER_ID%"=="steam_coldclient" (
    set "AE_VOICES38_FOUND="
    for /f "delims=" %%F in ('dir /s /b voices38.dll 2^>nul ^| findstr /I /V /C:"\adapters\" /C:"\core\"') do set "AE_VOICES38_FOUND=1"
    if defined AE_VOICES38_FOUND (
        echo [ERROR] voices38.dll found in the game folder.
        echo [ERROR] Please reinstall this game, then rerun this script.
        pause
        exit /b 1
    )
    echo.
    echo Do you want to use the script for a Clean Steam Files game or for a voices38 release game?
    echo   1 - Clean Steam Files
    echo   2 - voices38 release
    echo.
    choice /C 12 /N /M "Select an option (1-2): "
    if errorlevel 2 set "VOICES38=1"
    echo.
)

REM ========================================
REM STEP 2: Download/extract shared tooling (GBE Fork release + GSE Tools)
REM Steam-only (Goldberg loader/generate_interfaces + generate_emu_config) -
REM skipped entirely for gog_universelan, which uses none of it.
REM ========================================
set "GBE_CACHE_DIR=%SystemDrive%\steamcmd\_GBE fork"
if "%AE_STEAM_SCHEMA%"=="0" goto :skip_core_tools

echo Fetching shared emulator tooling (GBE Fork + GSE Tools)...
call "%COMMON_DIR%\download_helpers.bat" FetchCoreTools "%gameFolder%" "%GBE_CACHE_DIR%"
if errorlevel 1 (
    echo [ERROR] Failed to fetch required tooling. Aborting.
    pause
    exit /b 1
)
echo.

REM ========================================
REM One-time warning: GSE Tools 2026_02_16 ships a broken generate_emu_config.exe
REM ========================================
if "%GSE_TAG%"=="2026_02_16" (
    if not exist "%AE_STATE_DIR%\GenerateEmuConfig_2026_02_16_Warning.txt" (
        copy /b NUL "%AE_STATE_DIR%\GenerateEmuConfig_2026_02_16_Warning.txt" >nul
        echo.
        echo [WARNING] The cached GSE Tools version ^(2026_02_16^) ships a generate_emu_config.exe
        echo [WARNING] that needs to be replaced before achievement data can be generated correctly.
        echo [WARNING] Replace this file with a fixed version:
        echo [WARNING]   %SystemDrive%\steamcmd\_GBE fork\gse_fork_tools\2026_02_16\generate_emu_config\generate_emu_config.exe
        echo [WARNING] This warning will not be displayed again.
        echo.
        echo   1 - Roschach96's version
        echo   2 - CHESIRE's version
        echo   3 - Both
        choice /C 123 /N /M "Which link do you want to open? (1-3): "
        if errorlevel 3 (
            start "" "https://cs.rin.ru/forum/viewtopic.php?p=3539220#p3539220"
            start "" "https://cs.rin.ru/forum/viewtopic.php?p=3548848#p3548848"
        ) else if errorlevel 2 (
            start "" "https://cs.rin.ru/forum/viewtopic.php?p=3548848#p3548848"
        ) else (
            start "" "https://cs.rin.ru/forum/viewtopic.php?p=3539220#p3539220"
        )
        echo.
        echo Please replace the file, then rerun this script.
        pause
        exit /b 1
    )
)
:skip_core_tools

REM ========================================
REM STEP 3: Dummy Steam credentials for generate_emu_config
REM (Steam-schema only - GOG has no Steam achievement schema to fetch, so
REM gog_universelan skips this entirely and needs no dummy_account.txt.)
REM ========================================
set "GSE_CFG_USERNAME="
set "GSE_CFG_PASSWORD="
if "%AE_STEAM_SCHEMA%"=="0" goto :skip_dummy_creds

set "dummyCredsFile=%TOOLS_DIR%dummy_account.txt"
if not exist "%dummyCredsFile%" (
    echo.
    echo [ERROR] dummy_account.txt not found: !dummyCredsFile!
    echo [ERROR] Create this file next to the script with:
    echo         Line 1: a dummy Steam account username
    echo         Line 2: a dummy Steam account password
    echo.
    pause
    exit /b 1
)
set "_credLine=0"
for /f "usebackq delims=" %%A in ("%dummyCredsFile%") do (
    set /a _credLine+=1
    if "!_credLine!"=="1" set "GSE_CFG_USERNAME=%%A"
    if "!_credLine!"=="2" set "GSE_CFG_PASSWORD=%%A"
)
if not defined GSE_CFG_USERNAME (
    echo [ERROR] Line 1 ^(username^) missing or empty in dummy_account.txt
    pause
    exit /b 1
)
if not defined GSE_CFG_PASSWORD (
    echo [ERROR] Line 2 ^(password^) missing or empty in dummy_account.txt
    pause
    exit /b 1
)
echo Dummy account environment variables are ready.
echo.
:skip_dummy_creds

REM ========================================
REM STEP 4: Detect game name + Steam AppID
REM (Steam-only - gog_universelan gets its GOG App ID independently, inside
REM modify_joker_json.ps1, from the game's own goggame-*.info file.)
REM ========================================
for %%I in ("%gameFolder%") do set "gameName=%%~nxI"
echo [INFO] Game name set to folder name: %gameName%
echo.

set "gameAppID="
set "LAUNCH_ARGS="

if "%AE_STEAM_SCHEMA%"=="0" goto :skip_steam_appid

set "foundAppIDFile="
if exist "%gameFolder%\steam_appid.txt" (
    set "foundAppIDFile=%gameFolder%\steam_appid.txt"
)

if not defined foundAppIDFile (
    echo [INFO] Searching for steam_appid.txt near game executables...
    set "AE_GAME_FOLDER=%gameFolder%"
    for /f "delims=" %%F in ('powershell -NoProfile -Command ^
        "$found = $null;" ^
        "$exeDirs = Get-ChildItem -LiteralPath $env:AE_GAME_FOLDER -Filter '*.exe' -Recurse -Depth 4 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty DirectoryName -Unique;" ^
        "$exeDirs = $exeDirs | Where-Object { $_ -notmatch 'release|generate_emu_config|parse_achievements_schema|parse_controller_vdf|_ColdClient|GoldbergUplayR2' };" ^
        "foreach ($dir in $exeDirs) {" ^
        "  $c = Join-Path $dir 'steam_appid.txt';" ^
        "  if (Test-Path $c) { $found = $c; break };" ^
        "  $sub = Get-ChildItem -Path $dir -Filter 'steam_appid.txt' -Depth 1 -ErrorAction SilentlyContinue | Select-Object -First 1;" ^
        "  if ($sub) { $found = $sub.FullName; break }" ^
        "};" ^
        "if ($found) { $found }"') do set "foundAppIDFile=%%F"
)

if defined foundAppIDFile (
    echo [INFO] Found steam_appid.txt at: !foundAppIDFile!
    set /p gameAppID=<"!foundAppIDFile!"
    for /f "tokens=* delims= " %%A in ("!gameAppID!") do set "gameAppID=%%A"
    echo [INFO] AppID detected: !gameAppID!
    echo.
) else (
    echo [INFO] No steam_appid.txt found - searching Steam Store for a matching AppID...
    echo.
    if exist "%gameFolder%\_ae_appid.cmd" del /Q "%gameFolder%\_ae_appid.cmd"
    powershell -NoProfile -ExecutionPolicy Bypass -File "%COMMON_DIR%\shared_find_appid.ps1" -GameName "%gameName%"
    if exist "%gameFolder%\_ae_appid.cmd" (
        call "%gameFolder%\_ae_appid.cmd"
        del /Q "%gameFolder%\_ae_appid.cmd"
    )
    if not defined gameAppID (
        echo.
        set /p gameAppID=Could not auto-detect an AppID - enter it manually:
        echo.
    )
)

REM ========================================
REM STEP 5: Fetch the Steam manifest, parse launch args
REM ========================================
set "manifestFile=%gameFolder%\%gameAppID%_manifest.txt"
set "steamcmdDir=%SystemDrive%\steamcmd"
set "steamcmdExe=%steamcmdDir%\steamcmd.exe"

if not exist "%steamcmdExe%" (
    echo Downloading SteamCMD...
    powershell -Command "$progressPreference = 'silentlyContinue'; Invoke-WebRequest -Uri 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip' -OutFile 'steamcmd.zip'"
    if errorlevel 1 ( echo [ERROR] Failed to download SteamCMD & pause & exit /b 1 )
    echo Extracting SteamCMD...
    powershell -Command "Expand-Archive -LiteralPath 'steamcmd.zip' -DestinationPath '%steamcmdDir%' -Force"
    if errorlevel 1 ( echo [ERROR] Extraction failed & pause & exit /b 1 )
    del /Q "steamcmd.zip" >nul 2>&1
) else (
    echo [INFO] SteamCMD already installed at %steamcmdDir% - skipping download.
)

echo [INFO] Fetching Steam manifest for AppID %gameAppID%...
powershell -NoProfile -Command "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $out = & '%steamcmdExe%' +login anonymous +app_info_update 1 +app_info_print %gameAppID% +quit 2>&1; [System.IO.File]::WriteAllLines('%manifestFile%', $out, [System.Text.UTF8Encoding]::new($false))"

if exist "%manifestFile%" (
    echo [INFO] Parsing launch arguments from manifest...
    powershell -NoProfile -ExecutionPolicy Bypass -File "%COMMON_DIR%\shared_parse_launch_args.ps1" %gameAppID%
) else (
    echo [WARN] Manifest file not found - launch args will be skipped.
)
if exist "%gameFolder%\_ae_launch_args.cmd" (
    call "%gameFolder%\_ae_launch_args.cmd"
    del /Q "%gameFolder%\_ae_launch_args.cmd"
)
echo.
echo Steam AppID: %gameAppID%
echo.
:skip_steam_appid

REM ========================================
REM STEP 6: Adapter hook - find_paths.ps1
REM ========================================
echo Running %AE_ADAPTER_NAME% path detection...
set "AE_MANIFEST_FILE=%manifestFile%"
if exist "%gameFolder%\_ae_vars.cmd" del /Q "%gameFolder%\_ae_vars.cmd"
powershell -NoProfile -ExecutionPolicy Bypass -File "%AE_ADAPTER_DIR%\find_paths.ps1"
if not exist "%gameFolder%\_ae_vars.cmd" (
    echo [ERROR] !AE_ADAPTER_NAME! find_paths.ps1 did not produce _ae_vars.cmd
    pause
    exit /b 1
)
call "%gameFolder%\_ae_vars.cmd"
del /Q "%gameFolder%\_ae_vars.cmd"

if "%EXE_REL%"=="" (
    for %%F in ("%gameFolder%\*.exe") do (
        if not defined SELECTED_EXE set "SELECTED_EXE=%%~fF"
    )
) else (
    set "SELECTED_EXE=%gameFolder%\%EXE_REL%"
)

if "%DLL_FOLDER_REL%"=="" (
    set "destination=%gameFolder%"
) else (
    set "destination=%gameFolder%\%DLL_FOLDER_REL%"
)

for %%F in ("%SELECTED_EXE%") do set "processName=%%~nxF"

echo.

REM ========================================
REM STEP 7: (Goldberg-family only) generate_interfaces
REM Runs directly in cmd context - spawning this tool via PowerShell
REM Start-Process is known to crash it (0xC0000409), so it must NOT be
REM moved into an adapter's .ps1 file.
REM ========================================
set "AE_INTERFACES_GENERATED=0"
if "%AE_ADAPTER_ID%"=="steam_coldclient" (
if defined DLL_REL (
    if exist "%DLL_REL%" (
        set "GEN_INTERFACES_EXE="
        for /f "delims=" %%G in ('dir /s /b "release\generate_interfaces_x64.exe" 2^>nul') do if not defined GEN_INTERFACES_EXE set "GEN_INTERFACES_EXE=%%G"
        if defined GEN_INTERFACES_EXE (
            echo Running generate_interfaces...
            "!GEN_INTERFACES_EXE!" "%DLL_REL%"
            if exist "%gameFolder%\steam_interfaces.txt" set "AE_INTERFACES_GENERATED=1"
        ) else (
            echo [WARN] generate_interfaces_x64.exe not found anywhere under release\ - skipping steam_interfaces.txt.
        )
    )
)
)
echo.

REM ========================================
REM STEP 8: Update the SteamLadder top-owners cache in the background
REM (fallback achievement-percentage source when a game has no regular data -
REM Steam-only, skipped for gog_universelan, which never runs
REM generate_emu_config and has no use for this cache.)
REM ========================================
set "TOP_OWNERS_STARTED=0"
set "TOP_OWNERS_UPDATED="
if "%AE_STEAM_SCHEMA%"=="0" goto :skip_top_owners

set "TOP_OWNERS_RESULT_CMD=%AE_STATE_DIR%\ae_top_owners_result.cmd"
set "TOP_OWNERS_CACHE_FILE=%AE_STATE_DIR%\top_owners_ids.txt"
set "TOP_OWNERS_TEMP_FILE=%AE_STATE_DIR%\top_owners_ids.new.txt"
set "TOP_OWNERS_LOG=%AE_STATE_DIR%\ae_top_owners_update.log"
if exist "%TOP_OWNERS_RESULT_CMD%" del /Q "%TOP_OWNERS_RESULT_CMD%" >nul 2>&1
if exist "%TOP_OWNERS_TEMP_FILE%" del /Q "%TOP_OWNERS_TEMP_FILE%" >nul 2>&1
set "COMMON_SCRIPT=%COMMON_DIR%\update_top_owners.py"
echo [INFO] Refreshing the SteamLadder top-owners cache in the background...
set "PY_EXE="
set "PY_VER_ARG="
where py >nul 2>&1 && set "PY_EXE=py" && set "PY_VER_ARG=-3"
if not defined PY_EXE (
    where python >nul 2>&1 && set "PY_EXE=python"
)
if not defined PY_EXE (
    set "GSE_BASE_LIST_TAG="
    set "GSE_FORK_TOOLS_DIR_CHECK=%SystemDrive%\steamcmd\_GBE fork\gse_fork_tools"
    if exist "%GSE_FORK_TOOLS_DIR_CHECK%" (
        for /f "delims=" %%D in ('dir /b /ad /o-n "%GSE_FORK_TOOLS_DIR_CHECK%" 2^>nul') do (
            if not defined GSE_BASE_LIST_TAG set "GSE_BASE_LIST_TAG=%%D"
        )
    )
    echo [WARN] Python was not found.
    echo [WARN] Python is needed here to fetch the SteamLadder top-owners list,
    if defined GSE_BASE_LIST_TAG (
        echo [WARN] Without it, the script will use the base list from
        echo [WARN] gse_fork_tools instead, which only contains games up to
        echo [WARN] %GSE_BASE_LIST_TAG%.
    ) else (
        echo [WARN] Without it, the script will use the base list from
        echo [WARN] gse_fork_tools instead, which only contains games up to
        echo [WARN] whatever date that copy of gse_fork_tools was released.
    )
    echo [WARN] Install Python from https://www.python.org/downloads/ 
    echo [WARN] Be sure to select "Add python.exe to PATH" while installing,
    echo [WARN] then rerun the script to enable this feature.
    echo [WARN] Alternatively, you can follow this guide:
    echo [WARN] https://cs.rin.ru/forum/viewtopic.php?p=3491938#p3491938
    echo [WARN] Press Y to open that guide in your browser, or N to continue without it.
    choice /C YN /N >nul
    if not errorlevel 2 start "" "https://cs.rin.ru/forum/viewtopic.php?p=3491938#p3491938"
) else (
    set "TOP_OWNERS_PY=%PY_EXE%"
    set "TOP_OWNERS_PY_ARG=%PY_VER_ARG%"
    start "" /B powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand "JABhACAAPQAgAEAAKAApADsAIABpAGYAIAAoACQAZQBuAHYAOgBUAE8AUABfAE8AVwBOAEUAUgBTAF8AUABZAF8AQQBSAEcAKQAgAHsAIAAkAGEAIAArAD0AIAAkAGUAbgB2ADoAVABPAFAAXwBPAFcATgBFAFIAUwBfAFAAWQBfAEEAUgBHACAAfQA7ACAAJABhACAAKwA9ACAAQAAoACQAZQBuAHYAOgBDAE8ATQBNAE8ATgBfAFMAQwBSAEkAUABUACwAIAAnAC0ALQB0AHgAdAAtAG8AdQB0AHAAdQB0ACcALAAgACQAZQBuAHYAOgBUAE8AUABfAE8AVwBOAEUAUgBTAF8AVABFAE0AUABfAEYASQBMAEUAKQA7ACAAJgAgACQAZQBuAHYAOgBUAE8AUABfAE8AVwBOAEUAUgBTAF8AUABZACAAQABhADsAIAAkAGUAeABpAHQAQwBvAGQAZQAgAD0AIAAkAEwAQQBTAFQARQBYAEkAVABDAE8ARABFADsAIABpAGYAIAAoACQAZQB4AGkAdABDAG8AZABlACAALQBlAHEAIAAwACAALQBhAG4AZAAgACgAVABlAHMAdAAtAFAAYQB0AGgAIAAtAEwAaQB0AGUAcgBhAGwAUABhAHQAaAAgACQAZQBuAHYAOgBUAE8AUABfAE8AVwBOAEUAUgBTAF8AVABFAE0AUABfAEYASQBMAEUAKQApACAAewAgAE0AbwB2AGUALQBJAHQAZQBtACAALQBMAGkAdABlAHIAYQBsAFAAYQB0AGgAIAAkAGUAbgB2ADoAVABPAFAAXwBPAFcATgBFAFIAUwBfAFQARQBNAFAAXwBGAEkATABFACAALQBEAGUAcwB0AGkAbgBhAHQAaQBvAG4AIAAkAGUAbgB2ADoAVABPAFAAXwBPAFcATgBFAFIAUwBfAEMAQQBDAEgARQBfAEYASQBMAEUAIAAtAEYAbwByAGMAZQA7ACAAWwBJAE8ALgBGAGkAbABlAF0AOgA6AFcAcgBpAHQAZQBBAGwAbABUAGUAeAB0ACgAJABlAG4AdgA6AFQATwBQAF8ATwBXAE4ARQBSAFMAXwBSAEUAUwBVAEwAVABfAEMATQBEACwAIAAnAHMAZQB0ACAAVABPAFAAXwBPAFcATgBFAFIAUwBfAFUAUABEAEEAVABFAEQAPQAxACcALAAgAFsAVABlAHgAdAAuAEUAbgBjAG8AZABpAG4AZwBdADoAOgBBAFMAQwBJAEkAKQAgAH0AIABlAGwAcwBlACAAewAgAFsASQBPAC4ARgBpAGwAZQBdADoAOgBXAHIAaQB0AGUAQQBsAGwAVABlAHgAdAAoACQAZQBuAHYAOgBUAE8AUABfAE8AVwBOAEUAUgBTAF8AUgBFAFMAVQBMAFQAXwBDAE0ARAAsACAAJwBzAGUAdAAgAFQATwBQAF8ATwBXAE4ARQBSAFMAXwBVAFAARABBAFQARQBfAEYAQQBJAEwARQBEAD0AMQAnACwAIABbAFQAZQB4AHQALgBFAG4AYwBvAGQAaQBuAGcAXQA6ADoAQQBTAEMASQBJACkAIAB9AA==" >"%TOP_OWNERS_LOG%" 2>&1
    set "TOP_OWNERS_STARTED=1"
)
echo.
:skip_top_owners

REM ========================================
REM STEP 9: Generate achievement data (Steam-schema only - skipped for
REM gog_universelan, which has no Steam achievement schema to fetch and
REM handles achievements separately.)
REM ========================================
if "%AE_STEAM_SCHEMA%"=="0" goto :skip_gen_emu_config

call generate_emu_config\generate_emu_config -acw %gameAppID%

set "AE_ACHIEVEMENTS_MISSING=0"
if not exist "generate_emu_config\_OUTPUT\%gameAppID%\steam_settings\achievements.json" set "AE_ACHIEVEMENTS_MISSING=1"

if "%AE_ACHIEVEMENTS_MISSING%"=="1" (
    echo [INFO] No achievement data found. Waiting up to 30 seconds for the SteamLadder fallback list...
    if "%TOP_OWNERS_STARTED%"=="1" (
        powershell -NoProfile -Command "$until = [DateTime]::UtcNow.AddSeconds(30); while (-not (Test-Path -LiteralPath $env:TOP_OWNERS_RESULT_CMD) -and [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 500 }; if (Test-Path -LiteralPath $env:TOP_OWNERS_RESULT_CMD) { exit 0 }; exit 1"
        if not errorlevel 1 if exist "%TOP_OWNERS_RESULT_CMD%" call "%TOP_OWNERS_RESULT_CMD%"
    )
) else (
    REM Achievements were already found - don't block the run for this.
    REM Grab the result only if it happens to be ready already; if not,
    REM it'll be picked up non-blocking at Step 14 near the end.
    if "%TOP_OWNERS_STARTED%"=="1" if exist "%TOP_OWNERS_RESULT_CMD%" call "%TOP_OWNERS_RESULT_CMD%"
)

    if defined TOP_OWNERS_UPDATED if exist "%TOP_OWNERS_CACHE_FILE%" (
        copy /Y "%TOP_OWNERS_CACHE_FILE%" "generate_emu_config\top_owners_ids.txt" >nul
        set "GSE_FORK_TOOLS_DIR=%SystemDrive%\steamcmd\_GBE fork\gse_fork_tools"
    if exist "!GSE_FORK_TOOLS_DIR!" (
        for /d %%D in ("!GSE_FORK_TOOLS_DIR!\*") do (
                if exist "%%D\generate_emu_config" copy /Y "%TOP_OWNERS_CACHE_FILE%" "%%D\generate_emu_config\top_owners_ids.txt" >nul 2>&1
            )
        )
    echo [INFO] SteamLadder top-owners cache refreshed.
)

if defined TOP_OWNERS_UPDATED (
    if "%AE_ACHIEVEMENTS_MISSING%"=="1" (
        echo [INFO] SteamLadder list is ready; retrying achievement generation with the fallback list.
        call generate_emu_config\generate_emu_config -acw %gameAppID%
    )
) else (
    if "%AE_ACHIEVEMENTS_MISSING%"=="1" echo [WARN] SteamLadder fallback list was not ready; continuing without it.
)

REM Unzip extra_acw.zip if present (used both for Achievement Watcher export below
REM and by the adapter for its own achievement-data copy)
set "outputDir=generate_emu_config\_OUTPUT\%gameAppID%\steam_misc\extra_acw"
set "zipFile=%outputDir%\extra_acw.zip"
set "acwExtractDir=%outputDir%\_extracted"
if exist "%zipFile%" (
    echo Extracting extra_acw.zip...
    powershell -Command "Expand-Archive -LiteralPath '%zipFile%' -DestinationPath '%acwExtractDir%' -Force"
)
:skip_gen_emu_config
echo.

REM ========================================
REM STEP 10: Adapter hook - write_config.ps1
REM Every env var below is provided unconditionally; each adapter reads only
REM the subset it needs, so this block never has to branch on AE_ADAPTER_ID.
REM ========================================
echo Writing %AE_ADAPTER_NAME% configuration...
set "AE_GAME_FOLDER=%gameFolder%"
set "AE_GAME_NAME=%gameName%"
set "AE_APP_ID=%gameAppID%"
set "AE_LAUNCH_ARGS=%LAUNCH_ARGS%"
set "AE_APPDATA=%AppData%"
set "AE_APP_DATA=%AppData%"
set "AE_COLD_CLIENT_PATH=%gameFolder%\_ColdClient"
set "AE_LOADER_EXE=%LOADER_EXE%"
set "AE_EXE_PATH_RELATIVE=%ExePathRelative%"
set "AE_GBE_TAG=%GBE_TAG%"
set "AE_DLL_REL=%DLL_REL%"
set "AE_DESTINATION=%destination%"
set "AE_EXE_PATH=%SELECTED_EXE%"

if exist "%gameFolder%\_ae_final_exe.cmd" del /Q "%gameFolder%\_ae_final_exe.cmd"
if exist "%gameFolder%\_ae_missing_stubs.cmd" del /Q "%gameFolder%\_ae_missing_stubs.cmd"
powershell -NoProfile -ExecutionPolicy Bypass -File "%AE_ADAPTER_DIR%\write_config.ps1"
if errorlevel 1 (
    echo [WARN] !AE_ADAPTER_NAME! write_config.ps1 reported an error - check output above.
)
set "AE_FINAL_EXECUTABLE="
if exist "%gameFolder%\_ae_final_exe.cmd" (
    call "%gameFolder%\_ae_final_exe.cmd"
    del /Q "%gameFolder%\_ae_final_exe.cmd"
)
if not defined AE_FINAL_EXECUTABLE set "AE_FINAL_EXECUTABLE=%SELECTED_EXE%"

set "AE_MISSING_STUBS="
if exist "%gameFolder%\_ae_missing_stubs.cmd" (
    call "%gameFolder%\_ae_missing_stubs.cmd"
    del /Q "%gameFolder%\_ae_missing_stubs.cmd"
)
if defined AE_MISSING_STUBS (
    echo.
    echo [WARNING] The following SteamStub-avoider DLL^(s^) are missing from:
    echo [WARNING]   .\adapters\steam_coldclient\
    echo [WARNING]   %AE_MISSING_STUBS%
    echo [WARNING] Without them, some games protected by SteamStub
    echo [WARNING] may fail to launch correctly.
    echo [WARNING] Please add the missing file^(s^) to that folder, then rerun
    echo [WARNING] this script so they get copied into _ColdClient\extra_dlls.
    echo.
    pause
)
echo.

REM ========================================
REM STEP 11: Achievement Watcher export (Steam-only - Achievement Watcher
REM tracks Steam achievement caches, so this is skipped for gog_universelan)
REM ========================================
if "%AE_STEAM_SCHEMA%"=="0" goto :skip_acw
if not exist "%AppData%\Achievement Watcher\steam_cache\schema" (
    echo Achievement Watcher schema folder not found, skipping.
    goto :skip_acw
)
set "sourceSchemaRoot=%acwExtractDir%\steam_cache\schema"
set "targetSchemaRoot=%AppData%\Achievement Watcher\steam_cache\schema"
if not exist "%sourceSchemaRoot%" (
    echo Source schema folder not found: %sourceSchemaRoot%
    goto :skip_acw
)
for /D %%T in ("%targetSchemaRoot%\*") do (
    set "langFolder=%%~nxT"
    set "targetFolder=%%~fT"
    set "sourceFolder=%sourceSchemaRoot%\!langFolder!"
    if exist "!sourceFolder!" (
        copy /Y "!sourceFolder!\*.db" "!targetFolder!" >nul
    ) else (
        set "fallbackFolder=%sourceSchemaRoot%\english"
        if exist "!fallbackFolder!" (
            copy /Y "!fallbackFolder!\*.db" "!targetFolder!" >nul
        )
    )
)
echo Achievement Watcher schema files updated.
:skip_acw
echo.

REM ========================================
REM STEP 12: Jokerverse Achievements export (shared, if the app is installed)
REM ========================================
if not exist "%AppData%\Achievements\" (
    echo Achievements app folder not found in AppData, skipping Jokerverse export.
    goto :skip_joker
)

set "targetDir=%AppData%\Achievements\configs"
if "%AE_ADAPTER_ID%"=="gog_universelan" (
    set "targetJsonPath=%targetDir%\%gameName% (GOG).json"
) else if "%AE_ADAPTER_ID%"=="epic_nemirtingas_epic_emulator" (
    set "targetJsonPath=%targetDir%\%gameName%.json"
) else (
set "targetJsonPath=%targetDir%\%gameName%.json"
)
if exist "%targetJsonPath%" del /Q "%targetJsonPath%"

set "AE_SOURCE_JSON=%AE_ADAPTER_DIR%\GameSample.json"
set "AE_DEST_JSON=%targetJsonPath%"
set "AE_EXECUTABLE=%AE_FINAL_EXECUTABLE%"
set "AE_ARGUMENTS=%LAUNCH_ARGS%"
set "AE_PROCESS_NAME=%processName%"
set "AE_MANIFEST_FILE=%manifestFile%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%AE_ADAPTER_DIR%\modify_joker_json.ps1"
if errorlevel 1 (
    echo [WARN] !AE_ADAPTER_NAME! modify_joker_json.ps1 reported an error - check output above.
)
echo [INFO] Config written to: %targetJsonPath%
echo.

if "%AE_STEAM_SCHEMA%"=="0" goto :skip_steam_joker

set "gseTarget=%AppData%\Achievements\configs\schema\steam\%gameAppID%"
if exist "generate_emu_config\_OUTPUT\%gameAppID%\steam_settings\" (
    if not exist "%gseTarget%" mkdir "%gseTarget%"
    xcopy "generate_emu_config\_OUTPUT\%gameAppID%\steam_settings\achievements.json" "%gseTarget%\" /I /Y >nul
    xcopy "generate_emu_config\_OUTPUT\%gameAppID%\steam_settings\img" "%gseTarget%\img\" /E /I /Y >nul

    set "achievementsJsonPath=%gameFolder%\generate_emu_config\_OUTPUT\%gameAppID%\steam_settings\achievements.json"
    powershell -NoProfile -ExecutionPolicy Bypass -File "%AE_ADAPTER_DIR%\generate_achievement_percentages.ps1" -AppId "%gameAppID%" -AchievementsJsonPath "!achievementsJsonPath!" -OutputRoot "%AppData%\Achievements\configs\schema\steam"
)
:skip_steam_joker
echo.

REM ========================================
REM STEP 13: Desktop shortcut (adapter hook)
REM ========================================
echo Creating desktop shortcut...
set "AE_EXE_PATH=%SELECTED_EXE%"
set "AE_DESTINATION=%destination%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%AE_ADAPTER_DIR%\make_shortcut.ps1"
echo.

REM ========================================
REM STEP 13b: voices38 crack re-application window (steam_coldclient only)
REM Renames the loader DLL out of the way, waits for the user to (re)apply
REM the crack, then removes the crack files and restores the loader DLL.
REM ========================================
if "%VOICES38%"=="1" (
    for %%N in ("%DLL_REL%") do set "SelectedDllName=%%~nxN"
    if defined SelectedDllName (
        if exist "%destination%\!SelectedDllName!" ren "%destination%\!SelectedDllName!" "!SelectedDllName!.BAK"
        echo.
        echo [ACTION REQUIRED] Apply the crack files now.
        pause
        if exist "%destination%\!SelectedDllName!" del /Q "%destination%\!SelectedDllName!"
        if exist "%destination%\steam_settings" rmdir /S /Q "%destination%\steam_settings"
        if exist "%destination%\!SelectedDllName!.BAK" ren "%destination%\!SelectedDllName!.BAK" "!SelectedDllName!"
        echo [INFO] Loader restored from backup.
        echo.
    )
)

REM ========================================
REM STEP 14: Collect background update-check result
REM ========================================
if not defined TOP_OWNERS_UPDATED if "%TOP_OWNERS_STARTED%"=="1" if exist "%TOP_OWNERS_RESULT_CMD%" (
    call "%TOP_OWNERS_RESULT_CMD%"
    if defined TOP_OWNERS_UPDATED if exist "%TOP_OWNERS_CACHE_FILE%" (
        copy /Y "%TOP_OWNERS_CACHE_FILE%" "generate_emu_config\top_owners_ids.txt" >nul
        set "GSE_FORK_TOOLS_DIR=%SystemDrive%\steamcmd\_GBE fork\gse_fork_tools"
        if exist "!GSE_FORK_TOOLS_DIR!" (
            for /d %%D in ("!GSE_FORK_TOOLS_DIR!\*") do (
                if exist "%%D\generate_emu_config" copy /Y "%TOP_OWNERS_CACHE_FILE%" "%%D\generate_emu_config\top_owners_ids.txt" >nul 2>&1
            )
        )
        echo [INFO] SteamLadder top-owners cache refreshed.
    )
)
if "%UC_STARTED%"=="1" (
    if exist "%UPDATE_RESULT_CMD%" (
        call "%UPDATE_RESULT_CMD%"
        del "%UPDATE_RESULT_CMD%" >nul 2>&1
    )
)
if defined UPDATE_AVAILABLE (
    echo.
    echo [UPDATE] !UPDATE_COUNT! release^(s^) newer than this script were found:
    if defined CHANGELOG_FILE if exist "!CHANGELOG_FILE!" (
        echo.
        type "!CHANGELOG_FILE!"
        echo -----------------------------
    )
    choice /C YNS /N /M "Download and update now? (Y)es, (N)o, or (S)kip these versions: "
    set "AE_UPDATE_CHOICE=!errorlevel!"
    if "!AE_UPDATE_CHOICE!"=="3" call :SkipUpdateVersions
    if "!AE_UPDATE_CHOICE!"=="1" call :ApplyUpdate
)
goto :after_update_check

:SkipUpdateVersions
for %%D in ("!UPDATE_SKIP_FILE!") do if not exist "%%~dpD" md "%%~dpD" >nul 2>&1
for %%T in (!UPDATE_TAGS!) do >>"!UPDATE_SKIP_FILE!" echo %%T
echo [UPDATE] These versions will no longer be shown. Newer releases will still be checked.
exit /b 0

:ApplyUpdate
REM Newest tag is the first one in UPDATE_TAGS (latest-first order).
for /f "tokens=1" %%T in ("!UPDATE_TAGS!") do set "AE_NEW_TAG=%%T"
call "%COMMON_DIR%\download_helpers.bat" FetchSelfUpdate "!AE_NEW_TAG!" "!AE_STATE_DIR!" "!AE_BACKUP_DIR!"
if errorlevel 1 (
    echo [ERROR] Update download failed. Opening releases page instead.
    start "" "!REMOTE_URL!"
) else (
    echo [UPDATE] Updated to !AE_NEW_TAG! and copied to Backup folder: !AE_BACKUP_DIR!
)
exit /b 0
:after_update_check

REM ========================================
REM STEP 15: Final cleanup - only the patched game + shortcut should remain
REM ========================================
echo.
echo Cleaning up setup files and folders...

if exist "release"                                  rmdir /S /Q "release"
if exist "generate_emu_config"                      rmdir /S /Q "generate_emu_config"
if exist "parse_achievements_schema"                rmdir /S /Q "parse_achievements_schema"
if exist "parse_controller_vdf"                     rmdir /S /Q "parse_controller_vdf"

if exist "%gameAppID%_manifest.txt"                 del /Q "%gameAppID%_manifest.txt"
if exist "%gameAppID%_launch_args_debug.log"        del /Q "%gameAppID%_launch_args_debug.log"

if defined AE_ASSETS_DIR if exist "%AE_ASSETS_DIR%" rmdir /S /Q "%AE_ASSETS_DIR%"

if exist "dummy_account.txt"                        del /Q "dummy_account.txt"
if exist "dummy_account.txt.example"                del /Q "dummy_account.txt.example"
if exist "LICENSE"                                  del /Q "LICENSE"
if exist "README.md"                                del /Q "README.md"
if exist "%AE_STATE_DIR%\ae_top_owners_update.log"  del /Q "%AE_STATE_DIR%\ae_top_owners_update.log"
if exist "%AE_STATE_DIR%\ae_update_check.log"       del /Q "%AE_STATE_DIR%\ae_update_check.log"
if exist "%AE_STATE_DIR%\ae_top_owners_result.cmd"  del /Q "%AE_STATE_DIR%\ae_top_owners_result.cmd"

if exist "%CORE_DIR%"                               rmdir /S /Q "%CORE_DIR%"
if exist "%ADAPTERS_ROOT%"                          rmdir /S /Q "%ADAPTERS_ROOT%"

echo Cleanup complete.
echo.
echo ========================================
echo SETUP COMPLETE
echo ========================================
echo.
echo Launch the game from the desktop shortcut that was just created.
echo.

popd
pause

REM Self-delete last, once the summary has been shown.
del /Q "%~f0" >nul 2>&1
