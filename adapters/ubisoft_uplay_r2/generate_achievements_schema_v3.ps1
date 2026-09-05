param (
    [string]$appID,
    [string]$prefix = ""
)

if (-not $appID) {
    $appID = Read-Host "Add meg a Steam AppID-t"
}

# Location of achievement file
$achievementFile = ".\generate_emu_config\_OUTPUT\$appID\steam_settings\achievements.json"

if (Test-Path $achievementFile) {
    $achievements = Get-Content -Raw -Path $achievementFile | ConvertFrom-Json

    $achievementList = @()

    foreach ($achievement in $achievements) {
        if ($achievement.name -match '\d+$') {
            $id = [int]$matches[0]
            $description = $achievement.description.english

            $achievementData = [PSCustomObject]@{
                id          = $id
                displayName = $achievement.displayName.english
                description = $description
                earned      = 0
            }
            $achievementList += $achievementData
        }
    }

    $sortedList = $achievementList | Sort-Object id

    $orderedAchievements = [ordered]@{}

    foreach ($a in $sortedList) {
        # If a prefix is supplied the key mirrors what the INI's AchKeyPrefix expects,
        # e.g. "FenyxRising_Ach_42" instead of just "42".
        $key = if ($prefix) { "$prefix$($a.id)" } else { "$($a.id)" }

        $orderedAchievements[$key] = @{
            displayName = $a.displayName
            description = $a.description
            earned      = $a.earned
        }
    }

    $jsonOutput = $orderedAchievements | ConvertTo-Json -Depth 3

    $outputFile = "achievements_schema.json"
    $jsonOutput | Set-Content -Path $outputFile -Encoding UTF8

    Write-Output "Achievements saved to $outputFile (key prefix: '$prefix')"
} else {
    Write-Output "Achievement file not found: $achievementFile"
}
