# adapters\gog_universelan\write_config.ps1
#
# Runs the find -> download -> deploy UniverseLAN pipeline (the three
# functions this adapter's own find_galaxy_dll.ps1, download_universelan.ps1
# and deploy_universelan.ps1 define) against the game folder.
#
#   AE_GAME_FOLDER - game root (deploy stage reads its own goggame-<id>.info
#                    file from here - the GOG App ID is never passed in)

$ErrorActionPreference = 'Stop'

$gameFolder = $env:AE_GAME_FOLDER
$adapterDir = $env:AE_ADAPTER_DIR

if (-not $adapterDir) { $adapterDir = $PSScriptRoot }

$missing = @()
if (-not $gameFolder) { $missing += "AE_GAME_FOLDER" }
if ($missing.Count -gt 0) {
    Write-Host "[ERROR] gog_universelan\write_config.ps1: missing env var(s): $($missing -join ', ')"
    exit 1
}

. (Join-Path $adapterDir 'find_galaxy_dll.ps1')
. (Join-Path $adapterDir 'download_universelan.ps1')
. (Join-Path $adapterDir 'deploy_universelan.ps1')

$propertiesFile  = Join-Path $gameFolder 'GalaxyDllProperties.txt'
$universeLanRoot = Join-Path $env:SystemDrive 'steamcmd\_GOG\UniverseLAN'

Invoke-FindGalaxyDll -SearchRoot $gameFolder
Write-Host ""
Invoke-DownloadUniverseLan -CacheRoot $universeLanRoot
Write-Host ""
Invoke-DeployUniverseLan -GameRoot $gameFolder -PropertiesFile $propertiesFile -UniverseLANRoot $universeLanRoot

Remove-Item -LiteralPath $propertiesFile -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "[INFO] UniverseLAN setup complete."
exit 0
