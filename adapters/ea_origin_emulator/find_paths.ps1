# adapters\ea_origin_emulator\find_paths.ps1
# Executable finder for EA/Origin games (anadius Denuvo/Origin Emulator).
#
# EXE SELECTION PRIORITY:
#   1. *Shipping*.exe found -> auto-select (multiple -> pick among those)
#   2. Only 1 .exe in total -> auto-select
#   3. Interactive numbered list
#
# No manifest cross-check here (unlike steam_coldclient): confirmed against
# a real SteamCMD manifest for an EA/Steam-cross-listed game (WILD HEARTS,
# appid 1938010) that its "launch" entries are link2ea://... / steam2ea://...
# protocol handlers that hand off to the EA App itself, not a literal local
# .exe path. That's the standard pattern for EA-published games on Steam, so
# the manifest can never help disambiguate the local exe for this adapter's
# actual target games - not worth the SteamCMD round-trip.
#
# There is also no Steam API DLL to locate here - EA/Origin games
# authenticate through EA's own systems, not Steamworks - so
# DLL_REL/DLL_FOLDER_REL/LOADER_EXE are always left empty; the game's own
# exe is launched directly, per anadius.cfg's own model.
#
# Reads:  (none - no manifest to consult for this adapter)
# Writes: _ae_vars.cmd in the game root with EXE_REL, DLL_REL, DLL_FOLDER_REL,
#         ExePathRelative, LOADER_EXE

# This whole adapter depends on Python being installed and on PATH -
# write_config.ps1 (which actually runs origin_helper.py) checks this too,
# but checking here as well means a missing Python is caught immediately,
# before the user goes through exe selection for a run that can't proceed
# anyway.
if (-not (Get-Command py -ErrorAction SilentlyContinue) -and -not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] This adapter (EA/Origin - anadius Denuvo/Origin Emulator) requires Python,"
    Write-Host "[ERROR] and it wasn't found (checked 'py' and 'python' on PATH)."
    Write-Host "[ERROR] Install Python from https://www.python.org/downloads/"
    Write-Host "[ERROR] Be sure to select \"Add python.exe to PATH\" while installing, then rerun this script."
    exit 1
}

$gameRoot = (Get-Location).Path

# Folders that are never part of the actual game, regardless of where
# AE_GAME_FOLDER happens to point for a given run: __Installer (the EA
# installer metadata folder itself), generate_emu_config\/release\ (the
# orchestrator's own shared GSE/GBE-fork toolchain - generate_emu_config.exe
# variants, appid_finder, steamclient_loader templates, etc. - which have
# nothing to do with anadius or this adapter, but can end up sitting
# alongside a game folder in some setups), and __overlay\ (a third-party
# overlay's own injector folder, e.g. overlayinjector.exe - not the game
# either). Matched as exact path segments (bounded by backslashes) so a
# real game folder that merely contains one of these words as part of a
# longer name isn't excluded by accident.
$excludePattern = '\\(__Installer|generate_emu_config|release|__overlay)\\'

# origin_unwrapper.exe (adapters\ea_origin_emulator\Origin Unwrapper\) is
# this adapter's own tool, *_Trial.exe is a trial/demo build some games
# ship alongside the real exe (e.g. "WILD HEARTS_Trial.exe" next to
# "WILD HEARTS.exe"), and UnityCrashHandler64.exe is Unity's own bundled
# crash-reporting utility, not the game itself - none of these are ever
# the game's own exe to select, so all three are excluded by filename
# pattern (checked with -like, so wildcards work) rather than folder,
# since they aren't tied to one specific location the way the
# folder-based exclusions above are.
$excludeExeNamePatterns = @('origin_unwrapper.exe', '*_Trial.exe', 'UnityCrashHandler64.exe')

function Test-ExcludedExeName([string]$name) {
    foreach ($pattern in $excludeExeNamePatterns) {
        if ($name -like $pattern) { return $true }
    }
    return $false
}

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
    Where-Object { $_.FullName -notmatch $excludePattern -and -not (Test-ExcludedExeName $_.Name) }

$selectedExe = $null

$shippingExes = $allExes | Where-Object { $_.Name -match 'Shipping' }

if ($shippingExes.Count -eq 1) {
    $selectedExe = $shippingExes[0]
    Write-Host "[+] Auto-selected Shipping executable: $(Get-RelPath $selectedExe.FullName)"
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
}

if (-not $selectedExe) {
    if ($allExes.Count -eq 0) {
        Write-Host "[ERROR] No .exe files found in the game folder!"
        exit 1
    }
    if ($allExes.Count -eq 1) {
        $selectedExe = $allExes[0]
        Write-Host "[+] Only one executable found - auto-selected: $(Get-RelPath $selectedExe.FullName)"
    }
}

if (-not $selectedExe) {
    Write-Host ""
    Write-Host "[!] Could not auto-detect the main executable. Please select:"
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

$exeRel          = if ($selectedExe) { Get-RelPath $selectedExe.FullName } else { "" }
$exePathRelative = if ($selectedExe) { "..\" + $exeRel }                  else { "" }

Write-Host ""
Write-Host "========================================"
Write-Host "CONFIGURATION SUMMARY"
Write-Host "========================================"
Write-Host ""
Write-Host "Executable : $($selectedExe.FullName)"
Write-Host "Loader     : (none - anadius launches the game exe directly)"

$lines = @(
    "set `"EXE_REL=$exeRel`"",
    "set `"DLL_REL=`"",
    "set `"DLL_FOLDER_REL=`"",
    "set `"ExePathRelative=$exePathRelative`"",
    "set `"LOADER_EXE=`""
)
[System.IO.File]::WriteAllLines(
    (Join-Path $gameRoot "_ae_vars.cmd"),
    $lines,
    [System.Text.Encoding]::ASCII
)
