# pixeldrain_gse.ps1
#
# GSE Tools source: CHESIRE's generate_emu_config fork on Pixeldrain
# (replaces the alex47exe/gse_fork_tools GitHub releases).
#
#   -Mode Check     -ListId <id> -ResultCmd <file.cmd>
#       Reads the list, picks the newest .7z and writes to <ResultCmd>:
#         set "GSE_LATEST=<YYYY_MM_DD of its upload date>"
#         set "GSE_PD_ID=<file id>"
#         set "GSE_PD_NAME=<file name>"
#       Exit 1 (and no file) if Pixeldrain is unreachable.
#
#   -Mode Download  -FileId <id> -OutFile <path>
#       Downloads the file (via <path>.download, moved into place on success).

param(
    [Parameter(Mandatory)] [ValidateSet('Check', 'Download')] [string]$Mode,
    [string]$ListId,
    [string]$ResultCmd,
    [string]$FileId,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$headers = @{ 'User-Agent' = 'AchievementEnablerSetup' }

if ($Mode -eq 'Check') {
    try {
        $list  = Invoke-RestMethod -Headers $headers -TimeoutSec 15 -Uri "https://pixeldrain.com/api/list/$ListId"
        $file  = @($list.files) | Where-Object { $_.name -like '*.7z' } |
                 Sort-Object { [datetime]$_.date_upload } -Descending | Select-Object -First 1
        if (-not $file) { throw "No .7z file in Pixeldrain list $ListId." }
        $tag = ([datetime]$file.date_upload).ToUniversalTime().ToString('yyyy_MM_dd')
        $q = [char]34
        [IO.File]::WriteAllLines($ResultCmd, @(
            ('set ' + $q + 'GSE_LATEST=' + $tag + $q),
            ('set ' + $q + 'GSE_PD_ID=' + $file.id + $q),
            ('set ' + $q + 'GSE_PD_NAME=' + $file.name + $q)
        ), [Text.Encoding]::ASCII)
        exit 0
    } catch {
        Write-Host ('[WARN] Pixeldrain lookup failed: ' + $_.Exception.Message)
        exit 1
    }
}

# --- Download ---------------------------------------------------------------
$tmp = $OutFile + '.download'
try {
    $dir = Split-Path -Parent $OutFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest -Headers $headers -Uri "https://pixeldrain.com/api/file/$FileId`?download" -OutFile $tmp
    if (-not (Test-Path -LiteralPath $tmp) -or (Get-Item -LiteralPath $tmp).Length -eq 0) { throw 'Downloaded file is empty.' }
    Move-Item -LiteralPath $tmp -Destination $OutFile -Force
    exit 0
} catch {
    Write-Host ('[ERROR] Pixeldrain download failed: ' + $_.Exception.Message)
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    exit 1
}