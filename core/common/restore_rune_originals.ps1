# restore_rune_originals.ps1
# RUNE releases ship the original (clean) Steam files renamed to .rne next to
# the cracked ones, e.g.:
#   steam_api64.dll (cracked)  +  steam_api64.rne (original)
#   Resonance.exe   (cracked)  +  Resonance.rne   (original)
# For every .rne found recursively, the cracked counterpart (same base name,
# same folder) is renamed to .crk and the .rne takes back the counterpart's
# extension - restoring the Clean Steam Files layout. steam_emu.ini is deleted.
#
# Exit code: 0 = ok (incl. nothing found), 1 = one or more swaps failed.

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$GameFolder
)

$excludeRx = '\\(adapters|core)\\'
$preferExt = @('.exe', '.dll')
$failed = 0
$swapped = 0

$rneFiles = Get-ChildItem -LiteralPath $GameFolder -Recurse -File -Filter '*.rne' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch $excludeRx }

if (-not $rneFiles) { exit 0 }

Write-Host "[INFO] RUNE release detected - restoring original files..."

foreach ($rne in $rneFiles) {
    $base = [IO.Path]::GetFileNameWithoutExtension($rne.Name)
    $candidates = @(Get-ChildItem -LiteralPath $rne.DirectoryName -File -ErrorAction SilentlyContinue |
        Where-Object {
            [IO.Path]::GetFileNameWithoutExtension($_.Name) -ieq $base -and
            $_.Extension -notin @('.rne', '.crk')
        })

    if ($candidates.Count -eq 0) {
        Write-Host "[WARNING] No counterpart found for $($rne.FullName) - skipped."
        $failed++; continue
    }

    $target = $null
    if ($candidates.Count -eq 1) {
        $target = $candidates[0]
    } else {
        foreach ($ext in $preferExt) {
            $target = $candidates | Where-Object { $_.Extension -ieq $ext } | Select-Object -First 1
            if ($target) { break }
        }
    }
    if (-not $target) {
        Write-Host "[WARNING] Multiple counterparts for $($rne.FullName) ($(($candidates.Name) -join ', ')) - skipped."
        $failed++; continue
    }

    $crkPath = Join-Path $rne.DirectoryName ($base + '.crk')
    if (Test-Path -LiteralPath $crkPath) {
        Write-Host "[WARNING] $crkPath already exists - skipped $($rne.Name)."
        $failed++; continue
    }

    $origName = $target.Name
    try {
        Rename-Item -LiteralPath $target.FullName -NewName ($base + '.crk') -ErrorAction Stop
        try {
            Rename-Item -LiteralPath $rne.FullName -NewName $origName -ErrorAction Stop
        } catch {
            # roll back so the game is left in its original state
            Rename-Item -LiteralPath $crkPath -NewName $origName -ErrorAction SilentlyContinue
            throw
        }
        Write-Host "  $origName -> $base.crk ; $($rne.Name) -> $origName"
        $swapped++
    } catch {
        Write-Host "[WARNING] Failed to swap $($rne.FullName): $($_.Exception.Message)"
        $failed++
    }
}

# RUNE's emulator config is not needed once the originals are back.
Get-ChildItem -LiteralPath $GameFolder -Recurse -File -Filter 'steam_emu.ini' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch $excludeRx } |
    ForEach-Object {
        try {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
            Write-Host "  Deleted $($_.FullName)"
        } catch {
            Write-Host "[WARNING] Failed to delete $($_.FullName): $($_.Exception.Message)"
            $failed++
        }
    }

Write-Host "[INFO] RUNE restore: $swapped swapped, $failed failed."
if ($failed -gt 0) { exit 1 }
exit 0
