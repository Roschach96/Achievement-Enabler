@echo off
setlocal EnableExtensions

title Epic Achievements All-in-One

set "SELF=%~f0"
set "SCRIPT_DIR=%~dp0"
set "PSFILE=%TEMP%\epic_achievements_%RANDOM%%RANDOM%.ps1"
set "MARKER_LINE="

for /f "tokens=1 delims=:" %%A in ('findstr /n /b /c:":__POWERSHELL__" "%SELF%"') do (
    set "MARKER_LINE=%%A"
    goto :marker_found
)

:marker_not_found
echo(
echo Embedded PowerShell marker not found.
echo(
pause
exit /b 1

:marker_found
set /a SKIP_LINES=MARKER_LINE

more +%SKIP_LINES% "%SELF%" > "%PSFILE%"
if errorlevel 1 (
    echo(
    echo Failed to extract embedded PowerShell script.
    echo(
    pause
    exit /b 1
)

set "SCRIPT_DIR=%SCRIPT_DIR%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%PSFILE%" %*
set "EXITCODE=%ERRORLEVEL%"

del "%PSFILE%" >nul 2>nul

if "%~1"=="" (
echo(
echo Press any key to close...
pause >nul
)
exit /b %EXITCODE%

:__POWERSHELL__
$ErrorActionPreference = 'Stop'

function Get-SafeString {
    param($Value)
    if ($null -eq $Value) { return '' }
    return [string]$Value
}

function Get-SafeBool {
    param($Value)
    if ($null -eq $Value) { return $false }
    return [bool]$Value
}

function Get-ExtensionFromUrl {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return '.png'
    }

    try {
        $uri = [System.Uri]$Url
        $ext = [System.IO.Path]::GetExtension($uri.AbsolutePath)
        if ([string]::IsNullOrWhiteSpace($ext)) {
            return '.png'
        }
        return $ext
    }
    catch {
        return '.png'
    }
}

function Download-Image {
    param(
        [string]$Url,
        [string]$OutputBaseName,
        [string]$ImagesDir
    )

    if ([string]::IsNullOrWhiteSpace($Url) -or [string]::IsNullOrWhiteSpace($OutputBaseName)) {
        return
    }

    $ext = Get-ExtensionFromUrl -Url $Url
    $filePath = Join-Path $ImagesDir ($OutputBaseName + $ext)

    if (Test-Path -LiteralPath $filePath) {
        return
    }

    try {
        Invoke-WebRequest -Uri $Url -OutFile $filePath -UseBasicParsing
    }
    catch {
        Write-Host ('Failed to download image: ' + $Url)
    }
}

function Get-LocaleAchievementsMap {
    param(
        [object]$RootData,
        [string]$Locale
    )

    $map = @{}

    if ($null -eq $RootData.locales) { return $map }

    $localeNode = $RootData.locales.$Locale
    if ($null -eq $localeNode) { return $map }
    if (-not $localeNode.success) { return $map }

    $payload = $localeNode.payload
    if ($null -eq $payload) { return $map }

    $achievements = $payload.achievements
    if ($null -eq $achievements) { return $map }

    foreach ($item in $achievements) {
        if ($null -eq $item) { continue }

        $achievement = $item.achievement
        if ($null -eq $achievement) { continue }

        $name = Get-SafeString $achievement.name
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $map[$name] = $achievement
    }

    return $map
}

function Get-LocaleAchievementsList {
    param(
        [object]$RootData,
        [string]$Locale
    )

    if ($null -eq $RootData.locales) { return @() }

    $localeNode = $RootData.locales.$Locale
    if ($null -eq $localeNode) { return @() }
    if (-not $localeNode.success) { return @() }

    $payload = $localeNode.payload
    if ($null -eq $payload) { return @() }

    $achievements = $payload.achievements
    if ($null -eq $achievements) { return @() }

    return @($achievements)
}

function Build-OutputTranslationMap {
    param(
        [string]$DefaultValue,
        [hashtable]$SourceByLocale
    )

    $map = [ordered]@{}
    $map['de'] = Get-SafeString $SourceByLocale['de']
    $map['default'] = $DefaultValue
    $map['en'] = Get-SafeString $SourceByLocale['en']
    $map['es-ES'] = Get-SafeString $SourceByLocale['es-ES']
    $map['fr'] = Get-SafeString $SourceByLocale['fr']
    $map['it'] = Get-SafeString $SourceByLocale['it']
    $map['ja'] = Get-SafeString $SourceByLocale['ja']
    $map['pt-BR'] = Get-SafeString $SourceByLocale['pt-BR']
    $map['ru'] = Get-SafeString $SourceByLocale['ru']
    $map['zh'] = Get-SafeString $SourceByLocale['zh-CN']
    return $map
}

function Format-JsonTwoSpaces {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Json
    )

    $sb = New-Object System.Text.StringBuilder
    $indent = 0
    $inString = $false
    $escape = $false

    function Get-NextNonWhitespaceIndex {
        param(
            [string]$Text,
            [int]$StartIndex
        )

        for ($j = $StartIndex; $j -lt $Text.Length; $j++) {
            if (-not [char]::IsWhiteSpace($Text[$j])) {
                return $j
            }
        }

        return -1
    }

    for ($i = 0; $i -lt $Json.Length; $i++) {
        $ch = $Json[$i]

        if ($inString) {
            [void]$sb.Append($ch)

            if ($escape) {
                $escape = $false
                continue
            }

            if ($ch -eq '\') {
                $escape = $true
                continue
            }

            if ($ch -eq '"') {
                $inString = $false
            }

            continue
        }

        if ([char]::IsWhiteSpace($ch)) {
            continue
        }

        if ($ch -eq '"') {
            $inString = $true
            [void]$sb.Append($ch)
            continue
        }

        if ($ch -eq '{') {
            $nextIndex = Get-NextNonWhitespaceIndex -Text $Json -StartIndex ($i + 1)

            if ($nextIndex -ge 0 -and $Json[$nextIndex] -eq '}') {
                [void]$sb.Append('{}')
                $i = $nextIndex
                continue
            }

            [void]$sb.Append('{')
            [void]$sb.Append("`r`n")
            $indent++
            [void]$sb.Append((' ' * ($indent * 2)))
            continue
        }

        if ($ch -eq '[') {
            $nextIndex = Get-NextNonWhitespaceIndex -Text $Json -StartIndex ($i + 1)

            if ($nextIndex -ge 0 -and $Json[$nextIndex] -eq ']') {
                [void]$sb.Append('[]')
                $i = $nextIndex
                continue
            }

            [void]$sb.Append('[')
            [void]$sb.Append("`r`n")
            $indent++
            [void]$sb.Append((' ' * ($indent * 2)))
            continue
        }

        if ($ch -eq '}') {
            [void]$sb.Append("`r`n")
            $indent--
            [void]$sb.Append((' ' * ($indent * 2)))
            [void]$sb.Append('}')
            continue
        }

        if ($ch -eq ']') {
            [void]$sb.Append("`r`n")
            $indent--
            [void]$sb.Append((' ' * ($indent * 2)))
            [void]$sb.Append(']')
            continue
        }

        if ($ch -eq ',') {
            [void]$sb.Append(',')
            [void]$sb.Append("`r`n")
            [void]$sb.Append((' ' * ($indent * 2)))
            continue
        }

        if ($ch -eq ':') {
            [void]$sb.Append(': ')
            continue
        }

        [void]$sb.Append($ch)
    }

    return $sb.ToString()
}

$scriptDir = $env:SCRIPT_DIR
if ([string]::IsNullOrWhiteSpace($scriptDir)) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$outputDir = Join-Path $scriptDir 'epic_output'
$imagesDir = Join-Path $outputDir 'achievements_images'
$achievementsDbPath = Join-Path $outputDir 'achievements_db.json'

$fetchLocales = @(
    'en',
    'fr',
    'de',
    'it',
    'ja',
    'ko',
    'pl',
    'pt-BR',
    'ru',
    'es-ES',
    'es-MX',
    'zh-CN',
    'zh-TW'
)

$namespace = $args[0]

if ([string]::IsNullOrWhiteSpace($namespace)) {
$namespace = Read-Host 'Enter Namespace / sandboxId / Epic AppId'
}

if ([string]::IsNullOrWhiteSpace($namespace)) {
    Write-Host ''
    Write-Host 'Invalid namespace.'
    exit 1
}

New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
New-Item -ItemType Directory -Force -Path $imagesDir | Out-Null

$result = [ordered]@{
    namespace = $namespace
    fetchedAt = (Get-Date).ToString('o')
    locales   = [ordered]@{}
}

foreach ($locale in $fetchLocales) {
    Write-Host ('Fetching ' + $locale + '...')

    $url = 'https://api.epicgames.dev/epic/achievements/v1/public/achievements/product/' + $namespace + '/locale/' + $locale + '?includeAchievements=true'

    try {
        $response = Invoke-WebRequest -Uri $url -Method Get -Headers @{ Accept = 'application/json' } -UseBasicParsing

        $payload = $null
        try {
            $payload = $response.Content | ConvertFrom-Json
        }
        catch {
            $payload = $response.Content
        }

        $result.locales[$locale] = [ordered]@{
            success    = $true
            status     = [int]$response.StatusCode
            statusText = $response.StatusDescription
            url        = $url
            payload    = $payload
        }
    }
    catch {
        $statusCode = $null
        $statusText = 'REQUEST_FAILED'
        $payload = $null

        if ($_.Exception.Response -ne $null) {
            try { $statusCode = [int]$_.Exception.Response.StatusCode.value__ } catch {}
            try { $statusText = [string]$_.Exception.Response.StatusDescription } catch {}

            try {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream -ne $null) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $rawBody = $reader.ReadToEnd()
                    $reader.Close()

                    try {
                        $payload = $rawBody | ConvertFrom-Json
                    }
                    catch {
                        $payload = $rawBody
                    }
                }
            }
            catch {}
        }
        else {
            $statusText = $_.Exception.Message
        }

        $result.locales[$locale] = [ordered]@{
            success    = $false
            status     = $statusCode
            statusText = $statusText
            url        = $url
            payload    = $payload
        }
    }
}

Write-Host ''
Write-Host 'Converting achievements...'
Write-Host ''

$localeMaps = @{}
foreach ($locale in $fetchLocales) {
    $localeMaps[$locale] = Get-LocaleAchievementsMap -RootData $result -Locale $locale
}

$baseLocale = 'en'
$baseAchievementsList = Get-LocaleAchievementsList -RootData $result -Locale $baseLocale

if ($null -eq $baseAchievementsList -or $baseAchievementsList.Count -eq 0) {
    foreach ($locale in $fetchLocales) {
        $candidateList = Get-LocaleAchievementsList -RootData $result -Locale $locale
        if ($null -ne $candidateList -and $candidateList.Count -gt 0) {
            $baseLocale = $locale
            $baseAchievementsList = $candidateList
            break
        }
    }
}

if ($null -eq $baseAchievementsList -or $baseAchievementsList.Count -eq 0) {
    Write-Host 'No achievements found in any locale.'
    exit 1
}

$outputData = New-Object System.Collections.Generic.List[object]

foreach ($baseItem in $baseAchievementsList) {
    if ($null -eq $baseItem) { continue }

    $achievementBase = $baseItem.achievement
    if ($null -eq $achievementBase) { continue }

    $achievementId = Get-SafeString $achievementBase.name
    if ([string]::IsNullOrWhiteSpace($achievementId)) { continue }

    $unlockedDisplayNameSource = @{}
    $unlockedDescriptionSource = @{}
    $lockedDisplayNameSource = @{}
    $lockedDescriptionSource = @{}

    foreach ($locale in $fetchLocales) {
        $achievementLocale = $localeMaps[$locale][$achievementId]
        if ($null -eq $achievementLocale) { continue }

        $unlockedDisplayNameSource[$locale] = Get-SafeString $achievementLocale.unlockedDisplayName
        $unlockedDescriptionSource[$locale] = Get-SafeString $achievementLocale.unlockedDescription
        $lockedDisplayNameSource[$locale] = Get-SafeString $achievementLocale.lockedDisplayName
        $lockedDescriptionSource[$locale] = Get-SafeString $achievementLocale.lockedDescription
    }

    $unlockedDisplayName = Build-OutputTranslationMap -DefaultValue (Get-SafeString $achievementBase.unlockedDisplayName) -SourceByLocale $unlockedDisplayNameSource
    $unlockedDescription = Build-OutputTranslationMap -DefaultValue (Get-SafeString $achievementBase.unlockedDescription) -SourceByLocale $unlockedDescriptionSource
    $lockedDisplayName = Build-OutputTranslationMap -DefaultValue (Get-SafeString $achievementBase.lockedDisplayName) -SourceByLocale $lockedDisplayNameSource
    $lockedDescription = Build-OutputTranslationMap -DefaultValue (Get-SafeString $achievementBase.lockedDescription) -SourceByLocale $lockedDescriptionSource

    $statsThresholds = @()
    if ($null -ne $achievementBase.statThresholds) {
        foreach ($prop in $achievementBase.statThresholds.PSObject.Properties) {
            $statsThresholds += [ordered]@{
                Name = $prop.Name
                Threshold = $prop.Value
            }
        }
    }

    $entry = [ordered]@{
        AchievementId = $achievementId
        UnlockedDisplayName = $unlockedDisplayName
        UnlockedDescription = $unlockedDescription
        LockedDisplayName = $lockedDisplayName
        LockedDescription = $lockedDescription
        FlavorText = [ordered]@{
            default = (Get-SafeString $achievementBase.flavorText)
        }
        UnlockedIconUrl = $achievementId
        LockedIconUrl = ($achievementId + '_locked')
        IsHidden = Get-SafeBool $achievementBase.hidden
        StatsThresholds = $statsThresholds
    }

    $outputData.Add($entry)

    Download-Image -Url (Get-SafeString $achievementBase.unlockedIconLink) -OutputBaseName $achievementId -ImagesDir $imagesDir
    Download-Image -Url (Get-SafeString $achievementBase.lockedIconLink) -OutputBaseName ($achievementId + '_locked') -ImagesDir $imagesDir
}

$compactJson = $outputData | ConvertTo-Json -Depth 20 -Compress
$finalJson = Format-JsonTwoSpaces -Json $compactJson
[System.IO.File]::WriteAllText($achievementsDbPath, $finalJson, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ('Saved converted JSON: ' + $achievementsDbPath)
Write-Host ('Saved images in: ' + $imagesDir)
Write-Host ''
Write-Host ('Done. Total achievements: ' + $outputData.Count)