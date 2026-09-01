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
REM To support a new emulator later: add adapters\<new_id>\ with those five
REM scripts, an adapter.json (id/name/priority/detect.asset_folder_glob), and
REM a GameSample.json. Nothing in this file needs to change.
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

for /f "delims=" %%V in ('powershell -NoProfile -Command "$n='%~n0'; $ms=[regex]::Matches($n,'_V(\d+)'); if ($ms.Count -gt 0) { $ms[$ms.Count-1].Groups[1].Value } else { '0' }"') do set "SCRIPT_VER=%%V"

echo ========================================
echo    Achievement Enabler
echo ========================================
echo.
echo This tool patches a game folder to run through a Goldberg-style Steam
echo emulator (or Uplay R2, auto-detected) and enable achievements.
echo.

REM ========================================
REM Kick off the update check in the background - non-blocking.
REM ========================================
set "AE_STATE_DIR=%SystemDrive%\steamcmd\_GBE fork\AchievementEnabler"
if not exist "%AE_STATE_DIR%" md "%AE_STATE_DIR%" >nul 2>&1
set "UPDATE_RESULT_CMD=%AE_STATE_DIR%\ae_update_check_result.cmd"
set "UPDATE_CHANGELOG_FILE=%AE_STATE_DIR%\ae_update_changelog.txt"
set "UPDATE_LOG=%AE_STATE_DIR%\ae_update_check.log"
set "UPDATE_SKIP_FILE=%AE_STATE_DIR%\Achievement Enabler skipped versions.txt"
if exist "%UPDATE_RESULT_CMD%" del /Q "%UPDATE_RESULT_CMD%" >nul 2>&1
set "UC_PY="
set "UC_PY_ARG="
where py >nul 2>&1 && (set "UC_PY=py" & set "UC_PY_ARG=-3")
if not defined UC_PY (
    where python >nul 2>&1 && set "UC_PY=python"
)
set "UC_STARTED=0"
if defined UC_PY (
    start "" /B "%UC_PY%" %UC_PY_ARG% "%COMMON_DIR%\check_update.py" --current-version %SCRIPT_VER% --result-file "%UPDATE_RESULT_CMD%" --changelog-file "%UPDATE_CHANGELOG_FILE%" >"%UPDATE_LOG%" 2>&1
    set "UC_STARTED=1"
)
set "UC_PY="
set "UC_PY_ARG="

if not exist "%SystemDrive%\steamcmd" mkdir "%SystemDrive%\steamcmd"

if not exist "%SystemDrive%\steamcmd\AntivirusWarningDisplayed.txt" (
    copy /b NUL "%SystemDrive%\steamcmd\AntivirusWarningDisplayed.txt" >nul
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
REM STEP 1b: Automatic crack-state pre-flight checks (no user prompt)
REM Search excludes core\ and adapters\ - our own shipped uplay_r2 asset
REM pack contains template copies of uplay_r2.ini/upc_r2.ini, which would
REM otherwise always false-positive this check.
REM ========================================
if "%AE_ADAPTER_ID%"=="uplay_r2" (
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
if "%AE_ADAPTER_ID%"=="uplay_r1" (
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
REM Both adapters consume these two folders regardless of which is selected.
REM ========================================
set "GBE_CACHE_DIR=%SystemDrive%\steamcmd\_GBE fork"
echo Fetching shared emulator tooling (GBE Fork + GSE Tools)...
call "%COMMON_DIR%\download_helpers.bat" FetchCoreTools "%gameFolder%" "%GBE_CACHE_DIR%"
if errorlevel 1 (
    echo [ERROR] Failed to fetch required tooling. Aborting.
    pause
    exit /b 1
)
echo.

REM ========================================
REM STEP 3: Dummy Steam credentials for generate_emu_config
REM ========================================
set "GSE_CFG_USERNAME="
set "GSE_CFG_PASSWORD="
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

REM ========================================
REM STEP 4: Detect game name + Steam AppID
REM ========================================
for %%I in ("%gameFolder%") do set "gameName=%%~nxI"
echo [INFO] Game name set to folder name: %gameName%
echo.

set "gameAppID="
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
set "LAUNCH_ARGS="
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
REM (fallback achievement-percentage source when a game has no regular data)
REM ========================================
set "TOP_OWNERS_RESULT_CMD=%AE_STATE_DIR%\ae_top_owners_result.cmd"
set "TOP_OWNERS_CACHE_FILE=%AE_STATE_DIR%\top_owners_ids.txt"
set "TOP_OWNERS_TEMP_FILE=%AE_STATE_DIR%\top_owners_ids.new.txt"
set "TOP_OWNERS_LOG=%AE_STATE_DIR%\ae_top_owners_update.log"
if exist "%TOP_OWNERS_RESULT_CMD%" del /Q "%TOP_OWNERS_RESULT_CMD%" >nul 2>&1
if exist "%TOP_OWNERS_TEMP_FILE%" del /Q "%TOP_OWNERS_TEMP_FILE%" >nul 2>&1
set "TOP_OWNERS_STARTED=0"
set "TOP_OWNERS_UPDATED="
set "COMMON_SCRIPT=%COMMON_DIR%\update_top_owners.py"
echo [INFO] Refreshing the SteamLadder top-owners cache in the background...
set "PY_EXE="
set "PY_VER_ARG="
where py >nul 2>&1 && set "PY_EXE=py" && set "PY_VER_ARG=-3"
if not defined PY_EXE (
    where python >nul 2>&1 && set "PY_EXE=python"
)
if defined PY_EXE (
    set "TOP_OWNERS_PY=%PY_EXE%"
    set "TOP_OWNERS_PY_ARG=%PY_VER_ARG%"
    start "" /B powershell -NoProfile -ExecutionPolicy Bypass -Command "$a = @(); if ($env:TOP_OWNERS_PY_ARG) { $a += $env:TOP_OWNERS_PY_ARG }; $a += @($env:COMMON_SCRIPT, '--txt-output', $env:TOP_OWNERS_TEMP_FILE); & $env:TOP_OWNERS_PY @a; $exitCode = $LASTEXITCODE; if ($exitCode -eq 0 -and (Test-Path -LiteralPath $env:TOP_OWNERS_TEMP_FILE)) { Move-Item -LiteralPath $env:TOP_OWNERS_TEMP_FILE -Destination $env:TOP_OWNERS_CACHE_FILE -Force; [IO.File]::WriteAllText($env:TOP_OWNERS_RESULT_CMD, 'set TOP_OWNERS_UPDATED=1', [Text.Encoding]::ASCII) } else { [IO.File]::WriteAllText($env:TOP_OWNERS_RESULT_CMD, 'set TOP_OWNERS_UPDATE_FAILED=1', [Text.Encoding]::ASCII) }" >"%TOP_OWNERS_LOG%" 2>&1
    set "TOP_OWNERS_STARTED=1"
) else (
    echo [WARN] Python was not found. SteamLadder fallback will be unavailable.
)
echo.

if exist "%TOP_OWNERS_CACHE_FILE%" (
    if not exist "generate_emu_config" mkdir "generate_emu_config"
    copy /Y "%TOP_OWNERS_CACHE_FILE%" "generate_emu_config\top_owners_ids.txt" >nul
    echo [INFO] Using cached SteamLadder top-owners list.
) else (
    echo [INFO] No cached SteamLadder top-owners list is available yet.
)
echo.

REM ========================================
REM STEP 9: Generate achievement data (shared - both adapters read this)
REM ========================================
call generate_emu_config\generate_emu_config -acw %gameAppID%

if not exist "generate_emu_config\_OUTPUT\%gameAppID%\steam_settings\achievements.json" (
    echo [INFO] No achievement data found. Waiting up to 30 seconds for the SteamLadder fallback list...
    if "%TOP_OWNERS_STARTED%"=="1" (
        powershell -NoProfile -Command "$until = [DateTime]::UtcNow.AddSeconds(30); while (-not (Test-Path -LiteralPath $env:TOP_OWNERS_RESULT_CMD) -and [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 500 }; if (Test-Path -LiteralPath $env:TOP_OWNERS_RESULT_CMD) { exit 0 }; exit 1"
        if not errorlevel 1 if exist "%TOP_OWNERS_RESULT_CMD%" call "%TOP_OWNERS_RESULT_CMD%"
    )
    if defined TOP_OWNERS_UPDATED if exist "%TOP_OWNERS_CACHE_FILE%" (
        copy /Y "%TOP_OWNERS_CACHE_FILE%" "generate_emu_config\top_owners_ids.txt" >nul
        echo [INFO] SteamLadder list is ready; retrying achievement generation with the fallback list.
        call generate_emu_config\generate_emu_config -acw %gameAppID%
    ) else (
        echo [WARN] SteamLadder fallback list was not ready; continuing without it.
    )
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
echo.

REM ========================================
REM STEP 11: Achievement Watcher export (shared, if the folder exists locally)
REM ========================================
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
set "targetJsonPath=%targetDir%\%gameName%.json"
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
echo [INFO] %gameName%.json written to: %targetDir%
echo.

set "gseTarget=%AppData%\Achievements\configs\schema\steam\%gameAppID%"
if exist "generate_emu_config\_OUTPUT\%gameAppID%\steam_settings\" (
    if not exist "%gseTarget%" mkdir "%gseTarget%"
    xcopy "generate_emu_config\_OUTPUT\%gameAppID%\steam_settings\achievements.json" "%gseTarget%\" /I /Y >nul
    xcopy "generate_emu_config\_OUTPUT\%gameAppID%\steam_settings\img" "%gseTarget%\img\" /E /I /Y >nul

    set "achievementsJsonPath=%gameFolder%\generate_emu_config\_OUTPUT\%gameAppID%\steam_settings\achievements.json"
    powershell -NoProfile -ExecutionPolicy Bypass -File "%AE_ADAPTER_DIR%\generate_achievement_percentages.ps1" -AppId "%gameAppID%" -AchievementsJsonPath "!achievementsJsonPath!" -OutputRoot "%AppData%\Achievements\configs\schema\steam"
)
:skip_joker
echo.

REM ========================================
REM STEP 13: Desktop shortcut (adapter hook)
REM ========================================
echo Creating desktop shortcut...
set "AE_EXE_PATH=%SELECTED_EXE%"
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
if "%UC_STARTED%"=="1" (
    if exist "%UPDATE_RESULT_CMD%" (
        call "%UPDATE_RESULT_CMD%"
        del "%UPDATE_RESULT_CMD%" >nul 2>&1
    )
)
if defined REMOTE_VER (
    if !REMOTE_VER! GTR !SCRIPT_VER! (
        findstr /X /C:"!REMOTE_VER!" "!UPDATE_SKIP_FILE!" >nul 2>&1
        if not errorlevel 1 (
            echo [UPDATE] V!REMOTE_VER! was previously skipped.
        ) else (
            echo.
            echo [UPDATE] A newer version is available: V!REMOTE_VER! ^(you have V!SCRIPT_VER!^)
            if defined CHANGELOG_FILE if exist "!CHANGELOG_FILE!" (
                echo.
                echo -------- What's new --------
                type "!CHANGELOG_FILE!"
                echo -----------------------------
            )
            choice /C YNS /N /M "Open download page? (Y)es, (N)o, or (S)kip V!REMOTE_VER!"
            if errorlevel 3 (
                for %%D in ("!UPDATE_SKIP_FILE!") do if not exist "%%~dpD" md "%%~dpD" >nul 2>&1
                >>"!UPDATE_SKIP_FILE!" echo !REMOTE_VER!
            ) else if not errorlevel 2 (
                start "" "!REMOTE_URL!"
            )
        )
    )
)

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