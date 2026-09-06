# adapters\epic_nemirtingas_epic_emulator\find_paths.ps1
# Executable and EOSSDK loader DLL finder for the Epic (Nemirtingas Epic
# Emulator) adapter.
#
# EXE SELECTION PRIORITY (Unreal "Shipping" convention, then folder-name,
# then full manual list). Installer/uninstaller stubs (unins000.exe,
# Uninstall*.exe) are excluded from every tier's candidate list up front.
# Whenever exactly one candidate remains at any tier, it is auto-selected -
# a numbered prompt only appears when a genuine choice exists:
#   1. Exactly one "*Shipping*.exe" -> auto-select
#   2. Multiple Shipping matches -> numbered list
#   3. No Shipping matches, exactly one exe matches the folder name -> auto-select
#   4. No Shipping matches, multiple folder-name matches -> numbered list
#   5. No matches at all, exactly one exe remains overall -> auto-select
#   6. No matches at all, multiple exes remain -> numbered list
#
# Writes: _ae_vars.cmd in the game root with EXE_REL, DLL_REL,
#         DLL_FOLDER_REL, ExePathRelative

$gameRoot       = (Get-Location).Path
$excludePattern = 'nepice_settings|release|generate_emu_config|epic_output|adapters|core|parse_achievements_schema|parse_controller_vdf'
# Installer/uninstaller stubs are never the game's real executable - never
# offer them as a selectable candidate at any tier.
$exeExcludePattern = '(?i)^unins\d*\.exe$|(?i)^uninstall.*\.exe$'

function Get-RelPath($fullPath) {
    if ($fullPath -eq $gameRoot) { return "" }
    if ($fullPath.StartsWith($gameRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath.Substring($gameRoot.Length + 1)
    }
    return $fullPath
}

Write-Host ""
Write-Host "Searching for executable files..."
Write-Host ""

$allExes = Get-ChildItem -Path $gameRoot -Recurse -Filter *.exe -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch $excludePattern -and $_.Name -notmatch $exeExcludePattern }

if ($allExes.Count -eq 0) {
    Write-Host "[ERROR] No .exe files found in the game folder!"
    exit 1
}

$selectedExe   = $null
$shippingExes  = @($allExes | Where-Object { $_.Name -match 'Shipping' })

if ($shippingExes.Count -eq 1) {
    $selectedExe = $shippingExes[0]
    Write-Host "[+] Auto-selected Shipping match: $(Get-RelPath $selectedExe.FullName)"

} elseif ($shippingExes.Count -gt 1) {
    Write-Host "Multiple Shipping executables found:"
    for ($i = 0; $i -lt $shippingExes.Count; $i++) {
        Write-Host "  $($i+1)) $(Get-RelPath $shippingExes[$i].FullName)"
    }
    Write-Host ""
    do { [string]$c = Read-Host "Select Shipping executable (1-$($shippingExes.Count))" }
    while ($c -notmatch '^\d+$' -or [int]$c -lt 1 -or [int]$c -gt $shippingExes.Count)
    $selectedExe = $shippingExes[[int]$c - 1]
    Write-Host "[+] Selected: $(Get-RelPath $selectedExe.FullName)"

} else {
    $folderName    = Split-Path -Leaf $gameRoot
    $folderMatches = @($allExes | Where-Object { $_.FullName -match [regex]::Escape($folderName) })

    if ($folderMatches.Count -eq 1) {
        $selectedExe = $folderMatches[0]
        Write-Host "[+] Auto-selected match: $(Get-RelPath $selectedExe.FullName)"

    } elseif ($folderMatches.Count -gt 1) {
        Write-Host "Multiple executables match the folder name `"$folderName`":"
        for ($i = 0; $i -lt $folderMatches.Count; $i++) {
            Write-Host "  $($i+1)) $(Get-RelPath $folderMatches[$i].FullName)"
        }
        Write-Host ""
        do { [string]$c = Read-Host "Select executable (1-$($folderMatches.Count))" }
        while ($c -notmatch '^\d+$' -or [int]$c -lt 1 -or [int]$c -gt $folderMatches.Count)
        $selectedExe = $folderMatches[[int]$c - 1]
        Write-Host "[+] Selected: $(Get-RelPath $selectedExe.FullName)"

    } else {
        if ($allExes.Count -eq 1) {
            $selectedExe = $allExes[0]
            Write-Host "[!] No folder-name matches found, but only one executable exists - auto-selecting it."
            Write-Host "[+] Auto-selected: $(Get-RelPath $selectedExe.FullName)"
        } else {
            Write-Host "[!] No folder-name matches found. Listing all available executables:"
            Write-Host ""
            for ($i = 0; $i -lt $allExes.Count; $i++) {
                Write-Host "  $($i+1)) $(Get-RelPath $allExes[$i].FullName)"
            }
            Write-Host ""
            do { [string]$c = Read-Host "Select executable (1-$($allExes.Count))" }
            while ($c -notmatch '^\d+$' -or [int]$c -lt 1 -or [int]$c -gt $allExes.Count)
            $selectedExe = $allExes[[int]$c - 1]
            Write-Host "[+] Selected: $(Get-RelPath $selectedExe.FullName)"
        }
    }
}

Write-Host ""
Write-Host "Searching for EOSSDK loader DLL files..."
Write-Host ""

$allDlls = Get-ChildItem -Path $gameRoot -Recurse -Force -ErrorAction SilentlyContinue |
    Where-Object {
        ($_.Name -ieq 'EOSSDK-Win64-Shipping.dll' -or $_.Name -ieq 'EOSSDK-Win32-Shipping.dll') -and
        ($_.FullName -notmatch $excludePattern)
    }

$selectedDll = $null

if ($allDlls.Count -eq 0) {
    Write-Host "[!] Warning: No EOSSDK-Win64-Shipping.dll / EOSSDK-Win32-Shipping.dll found!"
} elseif ($allDlls.Count -eq 1) {
    Write-Host "[+] Found only one EOSSDK loader DLL: $(Get-RelPath $allDlls[0].FullName)"
    $selectedDll = $allDlls[0]
} else {
    Write-Host "Found $($allDlls.Count) EOSSDK loader DLL files. Please select manually:"
    Write-Host ""
    for ($i = 0; $i -lt $allDlls.Count; $i++) {
        Write-Host "  $($i+1)) $(Get-RelPath $allDlls[$i].FullName)"
    }
    Write-Host ""
    do { [string]$c = Read-Host "Select DLL (1-$($allDlls.Count))" }
    while ($c -notmatch '^\d+$' -or [int]$c -lt 1 -or [int]$c -gt $allDlls.Count)
    $selectedDll = $allDlls[[int]$c - 1]
    Write-Host "[+] Selected: $(Get-RelPath $selectedDll.FullName)"
}

$exeRel          = if ($selectedExe) { Get-RelPath $selectedExe.FullName }      else { "" }
$dllRel          = if ($selectedDll) { Get-RelPath $selectedDll.FullName }      else { "" }
$dllFolderRel    = if ($selectedDll) { Get-RelPath $selectedDll.DirectoryName } else { "" }
$exePathRelative = if ($selectedExe -and $exeRel -ne "") { "..\" + $exeRel }    else { "" }

Write-Host ""
Write-Host "========================================"
Write-Host "CONFIGURATION SUMMARY"
Write-Host "========================================"
Write-Host ""
Write-Host "Executable : $($selectedExe.FullName)"
if ($selectedDll) {
    Write-Host "DLL Folder : $($selectedDll.DirectoryName)"
} else {
    Write-Host "DLL Folder : Not found"
}

$lines = @(
    "set `"EXE_REL=$exeRel`"",
    "set `"DLL_REL=$dllRel`"",
    "set `"DLL_FOLDER_REL=$dllFolderRel`"",
    "set `"ExePathRelative=$exePathRelative`""
)
[System.IO.File]::WriteAllLines(
    (Join-Path $gameRoot "_ae_vars.cmd"),
    $lines,
    [System.Text.Encoding]::ASCII
)
