# adapters\gog_universelan\generate_achievement_percentages.ps1
# GOG has no public global-unlock-percentage API equivalent to Steam's
# ISteamUserStats/GetGlobalAchievementPercentagesForApp, so this hook is a
# deliberate no-op. Keeps the same call signature as the other adapters so
# the orchestrator never has to branch on AE_ADAPTER_ID.

param(
    [Parameter(Mandatory = $true)]
    [string]$AppId,

    [Parameter(Mandatory = $true)]
    [string]$AchievementsJsonPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputRoot
)

Write-Host "[INFO] achievement percentages skipped - no global unlock-percentage API exists for GOG."
exit 0
