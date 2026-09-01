# adapters\steam_coldclient\find_paths.ps1
# Unicode-safe executable and Steam API DLL finder for the Goldberg adapter.
#
# EXE SELECTION PRIORITY:
#   1. *Shipping*.exe found -> auto-select (multiple -> pick among those)
#   2. Only 1 .exe in total -> auto-select
#   3. Manifest default Windows launch entry -> auto-select if found on disk
#   4. Interactive numbered list
#
# Reads:  AE_MANIFEST_FILE (env var, optional)
# Writes: _ae_vars.cmd in the game root with EXE_REL, DLL_REL, DLL_FOLDER_REL,
#         ExePathRelative, LOADER_EXE

$gameRoot       = (Get-Location).Path
$excludePattern = 'release|generate_emu_config|parse_achievements_schema|parse_controller_vdf|_ColdClient'
$manifestFile   = $env:AE_MANIFEST_FILE

function Get-RelPath($fullPath) {
    if ($fullPath -eq $gameRoot) { return "" }
    if ($fullPath.StartsWith($gameRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath.Substring($gameRoot.Length + 1)
    }
    return $fullPath
}

function Get-Block([string]$src, [int]$startPos) {
    $depth  = 0
    $inside = $false
    $begin  = -1
    for ($i = $startPos; $i -lt $src.Length; $i++) {
        $c = $src[$i]
        if ($c -eq '{') {
            if (-not $inside) { $inside = $true; $begin = $i + 1 }
            $depth++
        } elseif ($c -eq '}') {
            $depth--
            if ($depth -eq 0) { return $src.Substring($begin, $i - $begin) }
        }
    }
    return $null
}

function Get-KVString([string]$block, [string]$key) {
    $q       = '"'
    $pattern = "(?m)^[ \t]*$q" + [regex]::Escape($key) + "$q[ \t]+$q([^$q]*?)$q\r?$"
    $m = [regex]::Match($block, $pattern)
    if ($m.Success) { return $m.Groups[1].Value } else { return $null }
}

Write-Host ""
Write-Host "Searching for executable files..."
Write-Host ""

$allExes = Get-ChildItem -Path $gameRoot -Recurse -Filter *.exe -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch $excludePattern }

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
    if ($manifestFile -and (Test-Path -LiteralPath $manifestFile)) {
        Write-Host "[INFO] Checking manifest for default Windows launch executable..."

        $raw = [System.IO.File]::ReadAllBytes($manifestFile)
        if ($raw.Length -ge 2 -and $raw[0] -eq 0xFF -and $raw[1] -eq 0xFE) {
            $text = [System.Text.Encoding]::Unicode.GetString($raw, 2, $raw.Length - 2)
        } elseif ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF) {
            $text = [System.Text.Encoding]::UTF8.GetString($raw, 3, $raw.Length - 3)
        } else {
            $text = [System.Text.Encoding]::UTF8.GetString($raw)
        }

        $launchMatch = [regex]::Match($text, '(?m)^[ \t]*"launch"[ \t]*\r?$')

        if ($launchMatch.Success) {
            $launchBlock = Get-Block $text ($launchMatch.Index + $launchMatch.Length)

            if ($launchBlock) {
                $entryRegex = [regex]'(?m)^[ \t]*"(\d+)"[ \t]*\r?$'
                $entries    = $entryRegex.Matches($launchBlock)

                $manifestExeRel = $null

                foreach ($em in ($entries | Sort-Object { [int]$_.Groups[1].Value })) {
                    $idx        = $em.Groups[1].Value
                    $entryBlock = Get-Block $launchBlock ($em.Index + $em.Length)
                    if (-not $entryBlock) { continue }

                    $configMatch = [regex]::Match($entryBlock, '(?m)^[ \t]*"config"[ \t]*\r?$')
                    $oslist = $null
                    if ($configMatch.Success) {
                        $cfgBlock = Get-Block $entryBlock ($configMatch.Index + $configMatch.Length)
                        if ($cfgBlock) { $oslist = Get-KVString $cfgBlock "oslist" }
                    }
                    if (-not $oslist) { $oslist = Get-KVString $entryBlock "oslist" }

                    $type       = Get-KVString $entryBlock "type"
                    $executable = Get-KVString $entryBlock "executable"

                    Write-Host "[debug] Entry $idx : oslist='$oslist'  type='$type'  executable='$executable'"

                    if ($oslist -and $oslist -notmatch 'windows') {
                        Write-Host "[debug] Entry $idx : skipped (non-Windows)"
                        continue
                    }
                    if ($type -and $type -ne "default") {
                        Write-Host "[debug] Entry $idx : skipped (type is '$type')"
                        continue
                    }
                    if (-not $executable -or $executable -notmatch '\.exe$') {
                        Write-Host "[debug] Entry $idx : skipped (no valid executable)"
                        continue
                    }

                    $manifestExeRel = $executable -replace '/', '\'
                    Write-Host "[INFO] Manifest default launch exe: $manifestExeRel"
                    break
                }

                if ($manifestExeRel) {
                    $manifestExeName = Split-Path $manifestExeRel -Leaf
                    $fullPath        = Join-Path $gameRoot $manifestExeRel

                    $candidates = @()
                    $byPath = $allExes | Where-Object { $_.FullName -eq $fullPath } | Select-Object -First 1
                    if ($byPath) { $candidates += $byPath }
                    $byName = $allExes | Where-Object { $_.Name -eq $manifestExeName -and $_.FullName -ne $fullPath }
                    $candidates += $byName

                    if ($candidates.Count -eq 0) {
                        Write-Host "[INFO] Manifest exe '$manifestExeName' not found on disk - falling through to selection."
                    } else {
                        $binariesCandidate = $candidates | Where-Object { $_.FullName -match 'Binaries' } | Select-Object -First 1

                        if ($binariesCandidate) {
                            $selectedExe = $binariesCandidate
                            Write-Host "[+] Auto-selected from manifest (Binaries folder preferred): $(Get-RelPath $selectedExe.FullName)"
                        } elseif ($byPath) {
                            $selectedExe = $byPath
                            Write-Host "[+] Auto-selected from manifest (exact path): $(Get-RelPath $selectedExe.FullName)"
                        } else {
                            $selectedExe = $byName | Select-Object -First 1
                            Write-Host "[+] Auto-selected from manifest (by filename): $(Get-RelPath $selectedExe.FullName)"
                        }
                    }
                } else {
                    Write-Host "[INFO] No default Windows launch entry in manifest - falling through to selection."
                }
            } else {
                Write-Host "[INFO] Could not parse launch block - falling through to selection."
            }
        } else {
            Write-Host "[INFO] No 'launch' section found in manifest - falling through to selection."
        }
    } else {
        Write-Host "[INFO] No manifest file available - falling through to selection."
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
Write-Host "Searching for Steam API DLL files (excluding setup folders)..."
Write-Host ""

$allDlls = Get-ChildItem -Path $gameRoot -Recurse -ErrorAction SilentlyContinue |
    Where-Object {
        ($_.Name -eq 'steam_api.dll' -or $_.Name -eq 'steam_api64.dll') -and
        ($_.FullName -notmatch $excludePattern)
    }

$selectedDll = $null

if ($allDlls.Count -eq 0) {
    Write-Host "[!] Warning: No Steam API DLLs found!"
} else {
    $binaryDll = $allDlls | Where-Object { $_.DirectoryName -match 'Binary|Binaries' } | Select-Object -First 1

    if ($binaryDll) {
        Write-Host "Found $($allDlls.Count) Steam API file(s)."
        Write-Host "[+] Auto-selected (Binary folder detected): $(Get-RelPath $binaryDll.FullName)"
        $selectedDll = $binaryDll
    } elseif ($allDlls.Count -eq 1) {
        Write-Host "Found 1 Steam API file(s)."
        Write-Host "[+] Found only one Steam API: $(Get-RelPath $allDlls[0].FullName)"
        $selectedDll = $allDlls[0]
    } else {
        Write-Host "Found $($allDlls.Count) Steam API files. No Binary folder prioritized. Please select manually:"
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
}

$loaderExe = 'steamclient_loader_x64.exe'
if ($selectedDll -and $selectedDll.Name -eq 'steam_api.dll') {
    $loaderExe = 'steamclient_loader_x86.exe'
    Write-Host "[INFO] steam_api.dll detected - using steamclient_loader_x86.exe"
} else {
    Write-Host "[INFO] steam_api64.dll detected - using steamclient_loader_x64.exe"
}

$exeRel          = if ($selectedExe) { Get-RelPath $selectedExe.FullName }      else { "" }
$dllRel          = if ($selectedDll) { Get-RelPath $selectedDll.FullName }      else { "" }
$dllFolderRel    = if ($selectedDll) { Get-RelPath $selectedDll.DirectoryName } else { "" }
$exePathRelative = if ($selectedExe) { "..\" + $exeRel }                        else { "" }

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
Write-Host "Loader     : $loaderExe"

$lines = @(
    "set `"EXE_REL=$exeRel`"",
    "set `"DLL_REL=$dllRel`"",
    "set `"DLL_FOLDER_REL=$dllFolderRel`"",
    "set `"ExePathRelative=$exePathRelative`"",
    "set `"LOADER_EXE=$loaderExe`""
)
[System.IO.File]::WriteAllLines(
    (Join-Path $gameRoot "_ae_vars.cmd"),
    $lines,
    [System.Text.Encoding]::ASCII
)
