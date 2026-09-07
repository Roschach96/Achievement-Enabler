@echo off
REM download_helpers.bat
REM
REM Shared subroutines called from AchievementEnabler.bat as a normal batch
REM invocation with a mode name as the first argument - NOT via the
REM "call file.bat :Label" cross-file label-jump trick, which is unreliable
REM when the calling path contains spaces:
REM
REM   call "core\common\download_helpers.bat" FetchCoreTools GameFolder CacheDir
REM
REM No setlocal here on purpose: FetchCoreTools sets GBE_TAG/GSE_TAG/etc.
REM in the CALLER's environment, exactly like the original monolithic scripts did.

set "DH_MODE=%~1"
if /I "%DH_MODE%"=="FetchCoreTools" goto :FetchCoreTools
if /I "%DH_MODE%"=="FetchSelfUpdate" goto :FetchSelfUpdate
echo [ERROR] download_helpers.bat: unknown mode "%DH_MODE%"
exit /b 1

REM :DownloadGitHubAsset is an internal-only helper used by :FetchCoreTools
REM (plain same-file "call :DownloadGitHubAsset arg1 arg2 arg3 arg4") - it is
REM NOT reachable through the external mode dispatch above, so its %~1-%~4
REM below are unshifted.
:DownloadGitHubAsset
set "DL_OWNER=%~1"
set "DL_REPO=%~2"
set "DL_ASSET=%~3"
set "DL_CACHE_ROOT=%~4"
set "DL_RESULT_CMD=%TEMP%\gbe_download_result_%RANDOM%.cmd"
set "DL_SELECTED_PATH="
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference = 'Stop'; $progressPreference = 'silentlyContinue'; $headers = @{ 'User-Agent' = 'AchievementEnablerSetup' }; $owner = $env:DL_OWNER; $repo = $env:DL_REPO; $asset = $env:DL_ASSET; $root = $env:DL_CACHE_ROOT; $resultCmd = $env:DL_RESULT_CMD; $repoDir = Join-Path $root $repo; if (-not (Test-Path -LiteralPath $repoDir)) { New-Item -ItemType Directory -Path $repoDir -Force | Out-Null }; function Set-Selected($path) { $q = [char]34; Set-Content -LiteralPath $resultCmd -Value ('set ' + $q + 'DL_SELECTED_PATH=' + $path + $q) -Encoding ASCII }; function Get-ReleasePath($release) { $tag = if ($release.tag_name) { $release.tag_name } else { $release.name }; $safeTag = ($tag.Split([IO.Path]::GetInvalidFileNameChars()) -join '_'); Join-Path (Join-Path $repoDir $safeTag) $asset }; function Try-Asset($release, $label) { $assetInfo = $release.assets | Where-Object { $_.name -eq $asset } | Select-Object -First 1; if (-not $assetInfo) { Write-Host ('[WARN] Asset {0} not found in {1} release {2}.' -f $asset, $label, $release.tag_name); return $false }; $out = Get-ReleasePath $release; $outDir = Split-Path -Parent $out; $tmp = $out + '.download'; if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }; Write-Host ('[INFO] Downloading {0} from {1} release {2}...' -f $asset, $label, $release.tag_name); Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; try { Invoke-WebRequest -Headers $headers -Uri $assetInfo.browser_download_url -OutFile $tmp; if ((Test-Path -LiteralPath $tmp) -and ((Get-Item -LiteralPath $tmp).Length -gt 0)) { Move-Item -LiteralPath $tmp -Destination $out -Force; Set-Selected $out; Get-ChildItem -LiteralPath $repoDir -Directory | Sort-Object LastWriteTime -Descending | Select-Object -Skip 1 | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue; Write-Host ('[INFO] Removed old cached version: {0}' -f $_.Name) }; return $true } } catch { Write-Host ('[WARN] {0} release download failed: {1}' -f $label, $_.Exception.Message) }; Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; return $false }; try { $latest = Invoke-RestMethod -Headers $headers -Uri ('https://api.github.com/repos/{0}/{1}/releases/latest' -f $owner, $repo); if (Try-Asset $latest 'latest') { exit 0 }; $all = @(Invoke-RestMethod -Headers $headers -Uri ('https://api.github.com/repos/{0}/{1}/releases?per_page=10' -f $owner, $repo)); $previous = @($all | Where-Object { $_.id -ne $latest.id } | Select-Object -First 1); foreach ($release in $previous) { if (Try-Asset $release 'previous') { exit 0 } } } catch { Write-Host ('[WARN] GitHub release lookup failed: {0}' -f $_.Exception.Message) }; $cached = Get-ChildItem -LiteralPath $repoDir -Filter $asset -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if ($cached) { Write-Host ('[WARN] GitHub download failed. Using cached backup: {0}' -f $cached.FullName); Set-Selected $cached.FullName; exit 0 }; Write-Host ('[ERROR] Failed to download {0} from GitHub and no cached backup exists.' -f $asset); exit 1"
set "DL_ERROR=%errorlevel%"
if exist "%DL_RESULT_CMD%" (
    call "%DL_RESULT_CMD%"
    del "%DL_RESULT_CMD%" >nul 2>&1
)
set "DL_OWNER="
set "DL_REPO="
set "DL_ASSET="
set "DL_CACHE_ROOT="
set "DL_RESULT_CMD="
exit /b %DL_ERROR%

REM ==========================================================================
REM :FetchCoreTools  <GameFolder>  <CacheDir>
REM
REM Downloads/extracts GBE Fork ("release\") and GSE Tools ("generate_emu_config\")
REM into <GameFolder>, using <CacheDir> as the persistent GitHub download cache.
REM Both adapters (Goldberg and Uplay R2) consume these same two folders, so
REM this only needs to run once regardless of which adapter is selected.
REM
REM Sets on return: GBE_TAG, GSE_TAG, and errorlevel (0 = ok, 1 = fatal).
REM ==========================================================================
:FetchCoreTools
set "FCT_GAME_FOLDER=%~2"
set "FCT_CACHE_DIR=%~3"

if not exist "%FCT_CACHE_DIR%" (
    mkdir "%FCT_CACHE_DIR%"
    if errorlevel 1 (
        echo [ERROR] Failed to create GitHub download cache: %FCT_CACHE_DIR%
        exit /b 1
    )
)

echo Checking for updates...
set "GBE_SKIP_DL=0"
set "GSE_SKIP_DL=0"
set "GBE_SKIP_EX=0"
set "GSE_SKIP_EX=0"
set "GBE_TAG="
set "GSE_TAG="

set "GBE_CACHE_DIR=%FCT_CACHE_DIR%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$h=@{'User-Agent'='AchievementEnablerSetup'}; $lines=@(); function Get-LatestTag($owner,$repo) { try { $r=Invoke-RestMethod -Headers $h -Uri ('https://api.github.com/repos/{0}/{1}/releases/latest' -f $owner,$repo); $t=if($r.tag_name){$r.tag_name}else{$r.name}; return $t.Split([IO.Path]::GetInvalidFileNameChars()) -join '_' } catch { return $null } }; function Test-CachedTag($root,$repo,$tag,$extractedName) { if(-not $tag){return $false}; $d=Join-Path $root (Join-Path $repo $tag); $extracted=Join-Path $d $extractedName; if(-not(Test-Path -LiteralPath $extracted)){return $false}; return [bool](Get-ChildItem -LiteralPath $extracted -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1) }; $gbeLatest=Get-LatestTag 'Detanup01' 'gbe_fork'; $gseLatest=Get-LatestTag 'alex47exe' 'gse_fork_tools'; $gbeOk=Test-CachedTag $env:GBE_CACHE_DIR 'gbe_fork' $gbeLatest 'release'; $gseOk=Test-CachedTag $env:GBE_CACHE_DIR 'gse_fork_tools' $gseLatest 'generate_emu_config'; Write-Host ('[INFO] GBE Fork  - latest: {0}  cached: {1}' -f $(if($gbeLatest){$gbeLatest}else{'unknown'}),$(if($gbeOk){'yes'}else{'no'})); Write-Host ('[INFO] GSE Tools - latest: {0}  cached: {1}' -f $(if($gseLatest){$gseLatest}else{'unknown'}),$(if($gseOk){'yes'}else{'no'})); if($gbeOk){$lines+='set GBE_SKIP_DL=1'; $lines+='set GBE_SKIP_EX=1'; $lines+=('set GBE_TAG='+$gbeLatest)}; if($gseOk){$lines+='set GSE_SKIP_DL=1'; $lines+='set GSE_SKIP_EX=1'; $lines+=('set GSE_TAG='+$gseLatest)}; if($lines){[System.IO.File]::WriteAllLines($env:TEMP+'\gbe_skip.cmd',$lines,[System.Text.Encoding]::ASCII)}"

if exist "%TEMP%\gbe_skip.cmd" (
    call "%TEMP%\gbe_skip.cmd"
    del "%TEMP%\gbe_skip.cmd" >nul 2>&1
)

if exist "%FCT_CACHE_DIR%\MissingLoader.txt" (
    echo [WARN] MissingLoader.txt found - forcing GBE Fork re-download/re-extract regardless of cached version.
    set "GBE_SKIP_DL=0"
    set "GBE_SKIP_EX=0"
)

if "%GBE_SKIP_DL%"=="1" echo [INFO] GBE Fork is up to date and already cached - skipping.
if "%GSE_SKIP_DL%"=="1" echo [INFO] GSE Tools is up to date and already cached - skipping.

set "SEVENZR_PATH="
if "%GBE_SKIP_EX%"=="1" if "%GSE_SKIP_EX%"=="1" goto :fct_skip_7zr
echo Downloading 7zr.exe...
call :DownloadGitHubAsset "ip7z" "7zip" "7zr.exe" "%FCT_CACHE_DIR%"
if errorlevel 1 (
    echo [ERROR] Failed to download 7zr.exe and no cached backup exists
    exit /b 1
)
set "SEVENZR_PATH=%DL_SELECTED_PATH%"
:fct_skip_7zr

if "%GBE_SKIP_DL%"=="0" (
    echo Downloading GBE Fork archive...
    call :DownloadGitHubAsset "Detanup01" "gbe_fork" "emu-win-release.7z" "%FCT_CACHE_DIR%"
    if errorlevel 1 (
        echo [ERROR] Failed to download GBE Fork archive and no cached backup exists
        exit /b 1
    )
    call set "GBE_ARCHIVE_PATH=%%DL_SELECTED_PATH%%"
    call :ExtractGbe
    if errorlevel 1 ( exit /b 1 )
) else (
    echo [INFO] GBE Fork already extracted - using cached files.
)
echo Copying GBE Fork files to game folder...
xcopy "%FCT_CACHE_DIR%\gbe_fork\%GBE_TAG%\release" "%FCT_GAME_FOLDER%\release\" /E /I /Y /Q

if "%GSE_SKIP_DL%"=="0" (
    echo Downloading GSE Tools archive...
    call :DownloadGitHubAsset "alex47exe" "gse_fork_tools" "gen_emu_cfg-Windows-Release.7z" "%FCT_CACHE_DIR%"
    if errorlevel 1 (
        echo [ERROR] Failed to download GSE Tools archive and no cached backup exists
        exit /b 1
    )
    call set "GSE_TOOLS_ARCHIVE_PATH=%%DL_SELECTED_PATH%%"
    call :ExtractGse
    if errorlevel 1 ( exit /b 1 )
) else (
    echo [INFO] GSE Tools already extracted - using cached files.
)
echo Copying GSE Tools files to game folder...
xcopy "%FCT_CACHE_DIR%\gse_fork_tools\%GSE_TAG%\generate_emu_config" "%FCT_GAME_FOLDER%\generate_emu_config\" /E /I /Y /Q

set "MISSING_LOADER="
dir /S /B "%FCT_CACHE_DIR%\gbe_fork\steamclient_loader_x64.exe" >nul 2>&1
if errorlevel 1 set "MISSING_LOADER=%MISSING_LOADER% steamclient_loader_x64.exe"
dir /S /B "%FCT_CACHE_DIR%\gbe_fork\steamclient_loader_x86.exe" >nul 2>&1
if errorlevel 1 set "MISSING_LOADER=%MISSING_LOADER% steamclient_loader_x86.exe"
if defined MISSING_LOADER (
    echo.>"%FCT_CACHE_DIR%\MissingLoader.txt"
    echo [ERROR] Missing component^(s^):%MISSING_LOADER%
    echo [ERROR] Add %SystemDrive%\steamcmd to your Antivirus exception list, then rerun this script.
    exit /b 1
) else (
    if exist "%FCT_CACHE_DIR%\MissingLoader.txt" del /Q "%FCT_CACHE_DIR%\MissingLoader.txt"
)

echo GitHub download cache kept at %FCT_CACHE_DIR%
exit /b 0

REM :ExtractGbe / :ExtractGse are internal-only helpers used by :FetchCoreTools,
REM called via plain same-file "call :Label" (not reachable through the
REM external mode dispatch at the top). Each runs as its own batch statement,
REM so %GBE_ARCHIVE_PATH% / %DL_SELECTED_PATH% etc. are expanded fresh at
REM execution time - avoiding the classic "()-block expands all %VAR% once,
REM before any command inside it runs" trap that caused an empty archive
REM path to be passed to 7-Zip when this logic lived inline inside the
REM if(...) ( ... ) block above.
:ExtractGbe
for %%P in ("%GBE_ARCHIVE_PATH%\..") do set "GBE_TAG=%%~nxP"
echo Extracting GBE Fork to cache...
"%SEVENZR_PATH%" x -y "%GBE_ARCHIVE_PATH%" -o"%FCT_CACHE_DIR%\gbe_fork\%GBE_TAG%"
if errorlevel 1 (
    echo [ERROR] Extraction failed
    exit /b 1
)
del "%GBE_ARCHIVE_PATH%" >nul 2>&1
exit /b 0

:ExtractGse
for %%P in ("%GSE_TOOLS_ARCHIVE_PATH%\..") do set "GSE_TAG=%%~nxP"
echo Extracting GSE Tools to cache...
"%SEVENZR_PATH%" x -y "%GSE_TOOLS_ARCHIVE_PATH%" -o"%FCT_CACHE_DIR%\gse_fork_tools\%GSE_TAG%"
if errorlevel 1 (
    echo [ERROR] Extraction failed
    exit /b 1
)
del "%GSE_TOOLS_ARCHIVE_PATH%" >nul 2>&1
exit /b 0

REM ==========================================================================
REM :FetchSelfUpdate  <Tag>  <AE_STATE_DIR>  <BackupFolder>
REM
REM Downloads the project's own release zip (Roschach96/Achievement-Enabler,
REM tag <Tag>) into <AE_STATE_DIR>\<Tag>\, extracts it there, then mirrors
REM that extracted folder into <BackupFolder>. <AE_STATE_DIR>\<Tag>\ is what
REM the orchestrator's update check treats as "the currently installed
REM version" from then on - same idea as the GBE Fork / GSE Tools caches
REM above, just for the project's own release instead of a dependency's.
REM
REM Sets on return: errorlevel (0 = ok, 1 = fatal).
REM ==========================================================================
:FetchSelfUpdate
set "FSU_TAG=%~2"
set "FSU_STATE_DIR=%~3"
set "FSU_BACKUP_DIR=%~4"

if not defined FSU_TAG (
    echo [ERROR] FetchSelfUpdate: no tag given
    exit /b 1
)

set "FSU_TAG_DIR=%FSU_STATE_DIR%\%FSU_TAG%"
if not exist "%FSU_TAG_DIR%" md "%FSU_TAG_DIR%" >nul 2>&1

set "FSU_ZIP=%FSU_TAG_DIR%\source.zip"
set "FSU_UNZIP=%FSU_TAG_DIR%\_unzip"
set "FSU_PS1=%TEMP%\ae_fetch_self_update.ps1"

REM Written line-by-line with individual >> appends (no enclosing parens)
REM so cmd.exe's block parser never has to deal with PowerShell's own
REM parens/braces at all - only the .ps1 file interprets those.
del "%FSU_PS1%" >nul 2>&1
>>"%FSU_PS1%" echo $ErrorActionPreference = 'Stop'
>>"%FSU_PS1%" echo $progressPreference = 'silentlyContinue'
>>"%FSU_PS1%" echo $h = @{'User-Agent'='AchievementEnablerSetup'}
>>"%FSU_PS1%" echo try {
>>"%FSU_PS1%" echo     $rel = Invoke-RestMethod -Headers $h -Uri (('https://api.github.com/repos/Roschach96/Achievement-Enabler/releases/tags/{0}') -f $env:FSU_TAG)
>>"%FSU_PS1%" echo     $asset = $rel.assets ^| Where-Object { $_.name -like '*.zip' } ^| Select-Object -First 1
>>"%FSU_PS1%" echo     $uri = if ($asset) { $asset.browser_download_url } else { $rel.zipball_url }
>>"%FSU_PS1%" echo     Invoke-WebRequest -Headers $h -Uri $uri -OutFile $env:FSU_ZIP
>>"%FSU_PS1%" echo     Expand-Archive -LiteralPath $env:FSU_ZIP -DestinationPath $env:FSU_UNZIP -Force
>>"%FSU_PS1%" echo } catch {
>>"%FSU_PS1%" echo     Write-Host ('[ERROR] ' + $_.Exception.Message)
>>"%FSU_PS1%" echo     exit 1
>>"%FSU_PS1%" echo }

echo Downloading Achievement Enabler %FSU_TAG%...
powershell -NoProfile -ExecutionPolicy Bypass -File "%FSU_PS1%"
if errorlevel 1 (
    del "%FSU_PS1%" >nul 2>&1
    echo [ERROR] Failed to download or extract release %FSU_TAG%
    exit /b 1
)
del "%FSU_PS1%" >nul 2>&1
del "%FSU_ZIP%" >nul 2>&1

REM Handle both possible zip shapes: a release asset zip usually has files
REM directly at its root; GitHub's auto-generated source zipball wraps
REM everything in a single "Achievement-Enabler-<tag>" folder instead.
set "FSU_WRAPPER="
set "FSU_ENTRY_COUNT="
for /f "delims=" %%C in ('dir /B "%FSU_UNZIP%" 2^>nul ^| find /C /V ""') do set "FSU_ENTRY_COUNT=%%C"
if "%FSU_ENTRY_COUNT%"=="1" (
    for /d %%D in ("%FSU_UNZIP%\*") do set "FSU_WRAPPER=%%D"
)
if defined FSU_WRAPPER (
    xcopy "%FSU_WRAPPER%" "%FSU_TAG_DIR%\" /E /I /Y /Q >nul
) else (
    xcopy "%FSU_UNZIP%" "%FSU_TAG_DIR%\" /E /I /Y /Q >nul
)
rmdir /S /Q "%FSU_UNZIP%" >nul 2>&1

if not defined FSU_BACKUP_DIR goto :fsu_skip_backup_copy
if not exist "%FSU_BACKUP_DIR%" md "%FSU_BACKUP_DIR%" >nul 2>&1
echo Copying to Backup folder: %FSU_BACKUP_DIR%
xcopy "%FSU_TAG_DIR%" "%FSU_BACKUP_DIR%\" /E /I /Y /Q >nul
if errorlevel 1 (
    echo [ERROR] Copy to Backup folder failed
    exit /b 1
)
goto :fsu_backup_copy_done
:fsu_skip_backup_copy
echo [WARN] No Backup folder set - skipping copy step.
:fsu_backup_copy_done

REM Only now that the new version is fully extracted (and copied to the
REM Backup folder, if one is set) do we remove older %FSU_STATE_DIR%\<tag>
REM folders, so a failed download/extract/copy never leaves zero versions
REM on disk.
for /d %%D in ("%FSU_STATE_DIR%\*") do (
    if /I not "%%~nxD"=="%FSU_TAG%" rmdir /S /Q "%%D" >nul 2>&1
)
exit /b 0