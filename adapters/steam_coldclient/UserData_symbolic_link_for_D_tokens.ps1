$OutputEncoding = [System.Text.Encoding]::UTF8

# 1. Path of the script
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# 2. Path of Steam from registry
$steamPath = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Valve\Steam" -ErrorAction SilentlyContinue).InstallPath
if (-not $steamPath) {
    $steamPath = (Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam" -ErrorAction SilentlyContinue).InstallPath
}

# 3. Error handling
if (-not $steamPath) {
    Write-Host "Could not find Steam installation path in the registry." -ForegroundColor Red
    exit 1
}

# 4. Setting paths
$sourcePath = Join-Path $steamPath "userdata"
$targetPath = Join-Path $scriptDir "userdata"

# 4b. Validate source exists BEFORE touching anything at the target.
#     A junction to a nonexistent target "succeeds" but Test-Path on it
#     returns $false, which used to be reported as a generic failure.
if (-not (Test-Path -LiteralPath $sourcePath)) {
    Write-Host "Steam userdata folder does not exist yet:" -ForegroundColor Red
    Write-Host "  $sourcePath" -ForegroundColor Red
    Write-Host "Log into Steam locally at least once, then run this again." -ForegroundColor Red
    exit 1
}

# 5. Handle whatever is currently at targetPath, safely.
if (Test-Path -LiteralPath $targetPath) {
    $existingItem = Get-Item -LiteralPath $targetPath -Force

    if ($existingItem.LinkType) {
        # Already a reparse point (junction/symlink) - safe to remove directly,
        # this does NOT touch whatever it points to.
        Remove-Item -LiteralPath $targetPath -Force
    } else {
        # Real folder, not a link. Probably save data written here before the
        # link was set up. Do NOT silently delete it - rename it instead.
        $backupName = "userdata_backup_" + (Get-Date -Format "yyyyMMdd_HHmmss")
        $backupPath = Join-Path $scriptDir $backupName
        Write-Host "WARNING: '$targetPath' is a real folder, not a link." -ForegroundColor Yellow
        Write-Host "Renaming it to '$backupName' instead of deleting it." -ForegroundColor Yellow
        Rename-Item -LiteralPath $targetPath -NewName $backupName
    }
}

# 6. Creating the junction - using the native cmdlet instead of
#    "cmd /c mklink", which avoids manually building a quoted command
#    line for a native process (the previous approach embedded literal
#    quote characters inside the path string, which PowerShell then
#    re-quoted again when invoking cmd.exe - corrupting the command
#    line for any path containing spaces, like this one).
try {
    New-Item -ItemType Junction -Path $targetPath -Target $sourcePath -ErrorAction Stop | Out-Null
} catch {
    Write-Host "Failed to create junction: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# 7. Verify using LinkType on the actual filesystem entry - this is the
#    only check that can't lie (Test-Path follows the reparse point and
#    can false-negative on a dangling junction).
$createdItem = Get-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
if ($createdItem -and $createdItem.LinkType -eq "Junction") {
    Write-Host "Symbolic link created successfully:"
    Write-Host "`t$targetPath -> $sourcePath"
    exit 0
} else {
    Write-Host "New-Item reported success but the junction was not found at the expected path." -ForegroundColor Red
    exit 1
}
