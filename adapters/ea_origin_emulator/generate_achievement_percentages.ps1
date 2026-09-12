param(
    [Parameter(Mandatory = $true)]
    [string]$AppId,

    [Parameter(Mandatory = $true)]
    [string]$AchievementsJsonPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputRoot,

    [switch]$InjectInPlace
)

$apiUrl = "https://api.steampowered.com/ISteamUserStats/GetGlobalAchievementPercentagesForApp/v0002/?gameid=$AppId"

if (-not (Test-Path -LiteralPath $AchievementsJsonPath)) {
    Write-Host "[WARN] achievement percentages skipped - achievements.json not found: $AchievementsJsonPath"
    exit 0
}

try {
    $localAchievements = Get-Content -LiteralPath $AchievementsJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Host "[WARN] achievement percentages skipped - could not parse achievements.json: $_"
    exit 0
}

if ($localAchievements -isnot [System.Collections.IEnumerable] -or $localAchievements -is [string]) {
    $localAchievements = @($localAchievements)
}

try {
    $response = Invoke-RestMethod -Uri $apiUrl -Method Get
} catch {
    Write-Host "[WARN] achievement percentages skipped - could not fetch Steam API data: $_"
    exit 0
}

$remoteAchievements = $response.achievementpercentages.achievements
if (-not $remoteAchievements) {
    Write-Host "[WARN] achievement percentages skipped - Steam API returned no achievements."
    exit 0
}

$percentByName = @{}
foreach ($item in $remoteAchievements) {
    if (-not $item.name) { continue }

    $percent = $null
    if ($null -ne $item.percent) {
        $percent = [double]::Parse(
            [string]$item.percent,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    }

    $percentByName[$item.name] = $percent
}

$outputAchievements = @()
foreach ($achievement in $localAchievements) {
    if (-not $achievement.name) { continue }

    if (-not $percentByName.ContainsKey($achievement.name)) { continue }

    $outputAchievements += [PSCustomObject]@{
        name    = $achievement.name
        percent = $percentByName[$achievement.name]
    }
    $achievement | Add-Member -MemberType NoteProperty -Name unlock_percentage -Value $percentByName[$achievement.name] -Force
}

if ($InjectInPlace) {
    try {
        $json = $localAchievements | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($AchievementsJsonPath, $json, [System.Text.UTF8Encoding]::new($false))
        Write-Host "[INFO] unlock_percentage injected into: $AchievementsJsonPath"
    } catch {
        Write-Host "[WARN] failed to write unlock_percentage in place: $_"
    }
}

if (-not $OutputRoot) { exit 0 }

if ($outputAchievements.Count -eq 0) {
    Write-Host "[WARN] achievement percentages skipped - no matching achievements found between Steam API and achievements.json."
    exit 0
}

$outputDir = Join-Path $OutputRoot "$AppId"
if (-not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$outputFile = Join-Path $outputDir "achievementpercentages.json"
$payload = [PSCustomObject]@{
    appid        = $AppId
    source       = "steam-global-achievement-percentages"
    updatedAt    = [DateTime]::UtcNow.ToString("o")
    achievements = $outputAchievements
}

try {
    $json = $payload | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($outputFile, $json, [System.Text.UTF8Encoding]::new($false))
    Write-Host ""
    Write-Host "[INFO] achievement percentages written to: $outputFile"
} catch {
    Write-Host ""
    Write-Host "[WARN] achievement percentages skipped - could not write output file: $_"
    exit 0
}
