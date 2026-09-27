# check_defender_exclusions.ps1
# Checks whether the given folders are covered by Windows Defender's
# ExclusionPath list (directly or via a parent folder / wildcard), and
# offers to add any missing ones.
#
# Reading/changing ExclusionPath needs admin. If this session isn't elevated,
# the script relaunches ONLY ITSELF elevated (UAC prompt) in -DumpTo mode,
# which optionally adds -AddPaths, then writes the current list to a temp
# file; everything else in AE keeps running as the normal user (so
# %AppData%/%LocalAppData%/mapped drives stay correct).
#
# -Paths    : '|'-separated list of folders (arrays don't survive powershell -File)
# -DumpTo   : internal - elevated child writes ExclusionPath here and exits
# -AddPaths : internal - '|'-separated folders the elevated child adds first
#
# Exit codes:
#   0 = Defender active and every folder is excluded (or was just added)
#   1 = Defender active and at least one folder is still NOT excluded
#   2 = Can't determine: Defender not installed / off, or UAC prompt declined
#   3 = A third-party antivirus is active (name printed) - its exclusion list
#       can't be read, so the user must add the folders there manually
param(
    [string]$Paths,
    [string]$DumpTo,
    [string]$AddPaths
)

function Split-Paths([string]$s) {
    @($s -split '\|' | Where-Object { $_ } | ForEach-Object { $_.Trim().TrimEnd('\') })
}

# ── Elevated child mode: optionally add, then dump the list and quit ──────
if ($DumpTo) {
    try {
        $toAdd = Split-Paths $AddPaths
        if ($toAdd.Count -gt 0) { Add-MpPreference -ExclusionPath $toAdd -ErrorAction Stop }
        $list = @((Get-MpPreference -ErrorAction Stop).ExclusionPath | Where-Object { $_ })
        Set-Content -LiteralPath $DumpTo -Value (@('#OK') + $list) -Encoding UTF8
        exit 0
    } catch { exit 2 }
}

$targets = Split-Paths $Paths

# ── Third-party AV detection via Windows Security Center (non-admin OK;
#    not available on Server SKUs, so failures are ignored). productState
#    bits 12-15 = 1 means the product's real-time protection is on.
try {
    $thirdParty = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop |
        Where-Object { $_.displayName -notmatch 'Defender' -and (($_.productState -shr 12) -band 0xF) -eq 1 } |
        ForEach-Object { $_.displayName } | Sort-Object -Unique)
} catch { $thirdParty = @() }
if ($thirdParty.Count -gt 0) {
    Write-Host ''
    Write-Host ("[WARNING] Active antivirus detected: {0}" -f ($thirdParty -join ', ')) -ForegroundColor Yellow
    Write-Host '[WARNING] AE cannot check or change its exclusion list. Add these folders manually:' -ForegroundColor Yellow
    foreach ($t in $targets) { Write-Host "          $t" -ForegroundColor Yellow }
    Write-Host ''
    exit 3
}

try { $status = Get-MpComputerStatus -ErrorAction Stop } catch { exit 2 }
if (-not $status.AntivirusEnabled) { exit 2 }
# Passive / SxS Passive = a third-party AV is primary; Defender's list is irrelevant.
if ($status.AMRunningMode -and $status.AMRunningMode -notin @('Normal', 'EDR Block Mode')) { exit 2 }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Returns the (optionally updated) exclusion list, or $null if it couldn't be read.
function Get-Exclusions([string[]]$add = @()) {
    if ($isAdmin) {
        try {
            if ($add.Count -gt 0) { Add-MpPreference -ExclusionPath $add -ErrorAction Stop }
            return ,@((Get-MpPreference -ErrorAction Stop).ExclusionPath | Where-Object { $_ })
        } catch { return $null }
    }
    Write-Host '[INFO] Windows Defender needs admin rights for this - please accept the UAC prompt.'
    $dump = Join-Path $env:TEMP ("ae_defender_excl_{0}.txt" -f [guid]::NewGuid().ToString('N'))
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -DumpTo `"$dump`""
    if ($add.Count -gt 0) { $argLine += " -AddPaths `"$($add -join '|')`"" }
    try {
        $p = Start-Process powershell -Verb RunAs -WindowStyle Hidden -Wait -PassThru -ArgumentList $argLine -ErrorAction Stop
    } catch {
        Write-Host '[INFO] Admin prompt declined.'
        return $null
    }
    if ($p.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $dump)) { return $null }
    $raw = @(Get-Content -LiteralPath $dump -Encoding UTF8)
    Remove-Item -LiteralPath $dump -Force -ErrorAction SilentlyContinue
    if ($raw.Count -eq 0 -or $raw[0] -ne '#OK') { return $null }
    return ,@($raw | Select-Object -Skip 1 | Where-Object { $_ })
}

function Get-Missing($exclusions) {
    $ex = @($exclusions | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') })
    @($targets | Where-Object {
        $t = $_
        -not ($ex | Where-Object { $t -like $_ -or $t -like "$_\*" })
    })
}

$exclusions = Get-Exclusions
if ($null -eq $exclusions -or ($exclusions -match '^N/A')) {
    Write-Host '[INFO] Skipping the Defender exclusion check.'
    exit 2
}

$missing = Get-Missing $exclusions
if ($missing.Count -eq 0) { exit 0 }

Write-Host ''
Write-Host '[WARNING] These folders are NOT in the Windows Defender exclusion list:' -ForegroundColor Yellow
foreach ($m in $missing) { Write-Host "          $m" -ForegroundColor Yellow }
Write-Host '[WARNING] Defender may delete or quarantine emulator files placed there.' -ForegroundColor Yellow
Write-Host ''

do { $ans = (Read-Host 'Add them to the exclusion list now? [Y/N]').Trim().ToUpper() } while ($ans -notin @('Y', 'N'))
if ($ans -eq 'N') { exit 1 }

$exclusions = Get-Exclusions $missing
if ($null -eq $exclusions) {
    Write-Host '[ERROR] Could not add the exclusions.' -ForegroundColor Red
    exit 1
}

# Re-verify: a GPO/Intune policy can silently ignore locally added exclusions.
$stillMissing = Get-Missing $exclusions
if ($stillMissing.Count -gt 0) {
    Write-Host '[ERROR] Exclusions were not applied - likely blocked by a system policy. Add them manually:' -ForegroundColor Red
    foreach ($m in $stillMissing) { Write-Host "          $m" -ForegroundColor Red }
    exit 1
}

Write-Host '[INFO] Folders added to the Windows Defender exclusion list.' -ForegroundColor Green
exit 0
