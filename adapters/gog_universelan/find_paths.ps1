# adapters\gog_universelan\find_paths.ps1
# Unicode-safe executable and Galaxy loader DLL finder for the GOG
# UniverseLAN adapter.
#
# EXE SELECTION PRIORITY:
#   1. A "Launch *.lnk" shortcut in the game root -> resolve its target
#      -> auto-select if the target exists on disk
#   2. Only 1 .exe in total -> auto-select
#   3. Interactive numbered list
#
# GOG installs (unlike SteamCMD ones) always ship a "Launch <Game>.lnk"
# shortcut directly in the install root pointing at the real game exe, so
# that's used here instead of manifest parsing.
#
# Writes: _ae_vars.cmd in the game root with EXE_REL, DLL_REL,
#         DLL_FOLDER_REL, ExePathRelative

$gameRoot       = (Get-Location).Path
$excludePattern = 'REDGalaxy'

function Get-RelPath($fullPath) {
    if ($fullPath -eq $gameRoot) { return "" }
    if ($fullPath.StartsWith($gameRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath.Substring($gameRoot.Length + 1)
    }
    return $fullPath
}

function Resolve-ShortcutTarget([string]$lnkPath) {
    try {
        $shell = New-Object -ComObject WScript.Shell
        $link  = $shell.CreateShortcut($lnkPath)
        return $link.TargetPath
    } catch {
        Write-Host "[WARN] Could not resolve shortcut '$lnkPath': $_"
        return $null
    }
}

Write-Host ""
Write-Host "Searching for executable files..."
Write-Host ""

$allExes = Get-ChildItem -Path $gameRoot -Recurse -Filter *.exe -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch $excludePattern }

$selectedExe = $null

# 1. "Launch *.lnk" in the game root - GOG's own shortcut to the real exe.
$launchLnk = Get-ChildItem -LiteralPath $gameRoot -Filter 'Launch *.lnk' -File -ErrorAction SilentlyContinue |
    Select-Object -First 1

if ($launchLnk) {
    Write-Host "[INFO] Found GOG launch shortcut: $($launchLnk.Name)"
    $target = Resolve-ShortcutTarget $launchLnk.FullName
    if ($target -and (Test-Path -LiteralPath $target)) {
        $selectedExe = Get-Item -LiteralPath $target
        Write-Host "[+] Auto-selected from shortcut target: $(Get-RelPath $selectedExe.FullName)"
    } else {
        Write-Host "[WARN] Shortcut target not found on disk ('$target') - falling through to selection."
    }
} else {
    Write-Host "[INFO] No 'Launch *.lnk' shortcut found in game root - falling through to selection."
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

Write-Host ""
Write-Host "Searching for Galaxy loader DLL files..."
Write-Host ""

$allDlls = Get-ChildItem -Path $gameRoot -Recurse -Force -ErrorAction SilentlyContinue |
    Where-Object {
        ($_.Name -ieq 'Galaxy.dll' -or $_.Name -ieq 'Galaxy64.dll') -and
        ($_.FullName -notmatch $excludePattern)
    }

$selectedDll = $null

if ($allDlls.Count -eq 0) {
    Write-Host "[!] Warning: No Galaxy.dll / Galaxy64.dll found!"
} elseif ($allDlls.Count -eq 1) {
    Write-Host "[+] Found only one Galaxy loader DLL: $(Get-RelPath $allDlls[0].FullName)"
    $selectedDll = $allDlls[0]
} else {
    Write-Host "Found $($allDlls.Count) Galaxy loader DLL files. Please select manually:"
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
