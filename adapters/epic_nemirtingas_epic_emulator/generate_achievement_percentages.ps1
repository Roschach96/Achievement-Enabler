# adapters\epic_nemirtingas_epic_emulator\generate_achievement_percentages.ps1
# Epic has no public global-unlock-percentage API equivalent to Steam's
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

Write-Host "[INFO] achievement percentages skipped - no global unlock-percentage API exists for Epic."
exit 0
