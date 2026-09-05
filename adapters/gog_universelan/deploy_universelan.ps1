# deploy_universelan.ps1
#
# Stage 3 of the pipeline. Reads GalaxyDllProperties.txt (produced by
# find_galaxy_dll.ps1) for each Galaxy.dll / Galaxy64.dll entry it
# describes, then:
#
#   1. Picks the matching UniverseLAN build for that dll's GOG Galaxy SDK
#      version FIRST, before touching anything in the game folder:
#        a) Preferred - via the official "Galaxy SDK Backwards
#           Compatibility List" cached by download_universelan.ps1
#           (galaxy_sdk_compat.json under the UniverseLAN cache root),
#           which maps a Galaxy SDK version to the UniverseLAN release
#           that supports it (works offline from the cached copy).
#        b) Fallback - directly comparing the game dll's own
#           FileVersion/ProductVersion against each candidate build's own
#           dll. Used only if (a) fails.
#        c) Last resort - comparing each candidate build FOLDER's own
#           version (parsed from its name) directly against the game's SDK
#           version. Catches builds the compatibility list doesn't know
#           about yet, including a manually added folder named after the
#           exact SDK version it targets, even when its dll's embedded
#           FileVersion resource is mis-stamped relative to its folder name.
#      Version strings are compared by their numeric parts throughout,
#      since UniverseLAN's own dlls report e.g. "1, 152, 6, 0" while GOG's
#      report "1.152.6.0". If NO matching build is found by either method,
#      the entry is skipped entirely - the original dll is left exactly as
#      it was (never renamed), so a game is never left without a working
#      Galaxy(64).dll just because no compatible UniverseLAN build is cached.
#   2. Only once a match is confirmed, renames the original dll in the game
#      folder to "<name>.BAK".
#   3. Copies each piece of that matching build to where it belongs - NOT
#      everything into the game folder:
#        - Galaxy.dll, Galaxy64.dll, UniverseLANServer.exe and
#          UniverseLANServer64.exe go next to the original Galaxy(64).dll
#          (the game folder), same as before.
#        - UniverseLAN.ini goes to %LocalAppData%\UniverseLAN\ (created if
#          missing).
#        - UniverseLANData and UniverseLANServerData go to
#          %LocalAppData%\UniverseLAN\<GOG App ID>\ (created if missing),
#          where <GOG App ID> is read from the game folder's
#          goggame-<id>.info file.
#   4. Cleans up the architecture that isn't needed (based on the bitness of
#      the original file, not on which .BAK happens to exist):
#        - 64-bit original -> delete Galaxy.dll + UniverseLANServer.exe
#        - 32-bit original -> delete Galaxy64.dll + UniverseLANServer64.exe
#
# Note: REDGalaxy.dll / REDGalaxy64.dll are off-limits and are never
# looked for, matched, or touched by this script.
#
# Defines Get-VersionParts, Test-VersionMatch, Get-CachedGalaxySdkCompatTable,
# Find-UniverseLANReleaseForSdkVersion, Get-UniverseLANBuildVersion,
# Get-GogAppId, and Invoke-DeployUniverseLan. Dot-source this file to load
# them; it does nothing on its own when dot-sourced.

function Get-VersionParts {
    # Pulls out the numeric components of a version string regardless of
    # separator style - handles "1.152.6.0" as well as UniverseLAN's own
    # dlls, which report FileVersion/ProductVersion as "1, 152, 6, 0".
    param([string]$VersionString)
    if ([string]::IsNullOrWhiteSpace($VersionString)) { return $null }
    $found = [regex]::Matches($VersionString, '\d+')
    if ($found.Count -eq 0) { return $null }
    $parts = @($found | ForEach-Object { [int]$_.Value })
    while ($parts.Count -lt 4) { $parts += 0 }
    return $parts
}

function Test-VersionMatch {
    param([string]$A, [string]$B)
    if ([string]::IsNullOrWhiteSpace($A) -or [string]::IsNullOrWhiteSpace($B)) { return $false }
    if ($A.Trim() -ieq $B.Trim()) { return $true }
    $pa = Get-VersionParts $A
    $pb = Get-VersionParts $B
    if (-not $pa -or -not $pb) { return $false }
    $len = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $len; $i++) {
        $va = if ($i -lt $pa.Count) { $pa[$i] } else { 0 }
        $vb = if ($i -lt $pb.Count) { $pb[$i] } else { 0 }
        if ($va -ne $vb) { return $false }
    }
    return $true
}

function Get-CachedGalaxySdkCompatTable {
    # Reads the galaxy_sdk_compat.json cached by download_universelan.ps1
    # (Get-GalaxySdkCompatTable). Returns an empty array if it isn't there
    # or can't be parsed - callers fall back to direct FileVersion matching.
    param([string]$UniverseLANRoot)
    $jsonPath = Join-Path $UniverseLANRoot 'galaxy_sdk_compat.json'
    if (-not (Test-Path -LiteralPath $jsonPath)) { return @() }
    try {
        return @(Get-Content -LiteralPath $jsonPath -Encoding UTF8 -Raw | ConvertFrom-Json)
    } catch {
        Write-Host "[WARN] Could not read cached Galaxy SDK compatibility list ($jsonPath): $_"
        return @()
    }
}

function Find-UniverseLANReleaseForSdkVersion {
    # Looks up which UniverseLAN release covers a given GOG Galaxy SDK
    # version, per the compatibility table. Returns the release string
    # (e.g. "1.152.6") or $null if the table has no row for it.
    param($Table, [string]$SdkVersion)
    foreach ($row in $Table) {
        if ([string]::IsNullOrWhiteSpace($row.Release) -or $row.Release -eq '-') { continue }
        foreach ($v in $row.SdkVersions) {
            $clean = ([string]$v).TrimEnd('?').Trim()
            if (Test-VersionMatch -A $clean -B $SdkVersion) {
                return $row.Release
            }
        }
    }
    return $null
}

function Get-UniverseLANBuildVersion {
    # Extracts the release version embedded in a build folder name, e.g.
    # "UniverseLAN-1.152.6-Build-626-x64_x86" -> "1.152.6".
    param([string]$FolderName)
    if ($FolderName -match '^UniverseLAN-(?<ver>[\d.]+)-Build-') {
        return $Matches['ver']
    }
    return $null
}

function Get-GogAppId {
    # Finds the game's GOG App ID from its "goggame-<id>.info" file - checks
    # the game folder itself first, then falls back to a recursive search
    # in case it's nested. Returns $null if no such file is found.
    param([string]$GameFolder)
    $infoFile = Get-ChildItem -LiteralPath $GameFolder -Filter 'goggame-*.info' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $infoFile) {
        $infoFile = Get-ChildItem -LiteralPath $GameFolder -Recurse -Filter 'goggame-*.info' -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }
    if ($infoFile -and $infoFile.Name -match 'goggame-(?<id>\d+)\.info') {
        return $Matches['id']
    }
    return $null
}

function Invoke-DeployUniverseLan {
    param(
        [string]$GameRoot,
        [string]$PropertiesFile,
        [string]$UniverseLANRoot
    )

    if (-not (Test-Path -LiteralPath $PropertiesFile)) {
        Write-Host "[ERROR] Properties file not found: $PropertiesFile"
        return
    }

    if (-not (Test-Path -LiteralPath $UniverseLANRoot)) {
        Write-Host "[ERROR] UniverseLAN cache root not found: $UniverseLANRoot"
        return
    }

    # --- Parse GalaxyDllProperties.txt into entries (Name, FullPath, FileVersion) ---
    $lines   = Get-Content -LiteralPath $PropertiesFile -Encoding UTF8
    $entries = New-Object System.Collections.Generic.List[object]
    $current = $null

    foreach ($line in $lines) {
        if ($line -match '^File\s*:\s*(.+)$') {
            $current = [PSCustomObject]@{ Name = $Matches[1].Trim(); FullPath = $null; FileVersion = $null }
        }
        elseif ($current -and $line -match '^Full path\s*:\s*(.+)$') {
            $current.FullPath = $Matches[1].Trim()
        }
        elseif ($current -and $line -match '^FileVersion\s*:\s*(.+)$') {
            $current.FileVersion = $Matches[1].Trim()
            $entries.Add($current)
            $current = $null
        }
    }

    if ($entries.Count -eq 0) {
        Write-Host "[!] No Galaxy.dll / Galaxy64.dll entries found in: $PropertiesFile"
        return
    }

    $compatTable = Get-CachedGalaxySdkCompatTable -UniverseLANRoot $UniverseLANRoot
    if ($compatTable.Count -gt 0) {
        Write-Host "[INFO] Loaded Galaxy SDK compatibility list ($($compatTable.Count) rows)."
    } else {
        Write-Host "[WARN] No Galaxy SDK compatibility list available - matching will rely on direct dll FileVersion/ProductVersion comparison only."
    }

    Write-Host "Scanning UniverseLAN cache for matching builds: $UniverseLANRoot"
    Write-Host ""

    $unmatched = New-Object System.Collections.Generic.List[object]

    foreach ($entry in $entries) {

        if (-not $entry.FullPath -or -not (Test-Path -LiteralPath $entry.FullPath)) {
            Write-Host "[WARN] $($entry.Name): source file not found on disk ($($entry.FullPath)) - skipping."
            continue
        }

        $dllName   = $entry.Name
        $dllPath   = $entry.FullPath
        # The folder the dll itself lives in - NOT necessarily $GameRoot.
        # Many games put Galaxy(64).dll under a subfolder (e.g. bin\x64)
        # while goggame-*.info and other install-root files stay in
        # $GameRoot. Keep these two distinct - conflating them is exactly
        # what caused the GOG App ID lookup to look in the wrong place.
        $dllFolder = Split-Path -Parent $dllPath
        $bakPath   = "$dllPath.BAK"

        if ($dllName -inotmatch '^Galaxy(?<bits>64)?\.dll$') {
            Write-Host "[WARN] Unrecognized dll name '$dllName' - skipping (only Galaxy.dll / Galaxy64.dll are handled)."
            Write-Host ""
            continue
        }
        $is64 = [bool]$Matches['bits']
        $universeLanDllName = $dllName

        Write-Host "=== $dllName  (FileVersion: $($entry.FileVersion)) ==="
        Write-Host "Dll folder  : $dllFolder"

        # 1. Find the matching UniverseLAN build for this Galaxy SDK version
        #    BEFORE touching anything in the game folder. If nothing matches,
        #    we leave the original dll exactly where it was - no rename, no
        #    copy, no cleanup - so a missing/incompatible UniverseLAN build
        #    never leaves the game without a Galaxy(64).dll to load.
        $candidates = Get-ChildItem -LiteralPath $UniverseLANRoot -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ieq $universeLanDllName }

        $match = $null

        # 1a. Preferred: look up the official compatibility list to find which
        #     UniverseLAN release covers this exact Galaxy SDK version, then
        #     find that release's build folder among the candidates.
        if ($compatTable.Count -gt 0) {
            $releaseFromTable = Find-UniverseLANReleaseForSdkVersion -Table $compatTable -SdkVersion $entry.FileVersion
            if ($releaseFromTable) {
                foreach ($candidate in $candidates) {
                    $folderName = Split-Path -Leaf (Split-Path -Parent $candidate.FullName)
                    $buildVer   = Get-UniverseLANBuildVersion $folderName
                    if ($buildVer -and (Test-VersionMatch -A $buildVer -B $releaseFromTable)) {
                        $match = $candidate
                        break
                    }
                }
                if ($match) {
                    Write-Host "[INFO] Compatibility list: Galaxy SDK $($entry.FileVersion) -> UniverseLAN $releaseFromTable"
                } else {
                    Write-Host "[WARN] Compatibility list says UniverseLAN $releaseFromTable covers Galaxy SDK $($entry.FileVersion), but that build isn't cached under $UniverseLANRoot - falling back to other matching methods."
                }
            } else {
                Write-Host "[WARN] Galaxy SDK $($entry.FileVersion) isn't listed in the compatibility list - falling back to other matching methods."
            }
        }

        # 1b. Fallback: compare each candidate dll's own embedded
        #     FileVersion/ProductVersion directly against the game's dll.
        if (-not $match) {
            foreach ($candidate in $candidates) {
                $vi = $candidate.VersionInfo
                if ((Test-VersionMatch -A $vi.FileVersion -B $entry.FileVersion) -or
                    (Test-VersionMatch -A $vi.ProductVersion -B $entry.FileVersion)) {
                    $match = $candidate
                    break
                }
            }
            if ($match) {
                Write-Host "[INFO] Matched via direct dll version comparison: $($match.FullName)"
            }
        }

        # 1c. Last resort: compare each candidate build FOLDER's own version
        #     (parsed from its name, e.g. "UniverseLAN-1.152.2.1-Build-626-x64_x86"
        #     -> "1.152.2.1") directly against the game's SDK version. This
        #     catches builds the compatibility list doesn't know about yet -
        #     including a custom/manually added folder whose name IS the
        #     exact SDK version it targets, even if the dll's own embedded
        #     FileVersion resource happens to be mis-stamped (seen in the
        #     wild: a folder named "...1.152.2.1..." whose dll reports
        #     FileVersion "1.152.2.0").
        if (-not $match) {
            foreach ($candidate in $candidates) {
                $folderName = Split-Path -Leaf (Split-Path -Parent $candidate.FullName)
                $buildVer   = Get-UniverseLANBuildVersion $folderName
                if ($buildVer -and (Test-VersionMatch -A $buildVer -B $entry.FileVersion)) {
                    $match = $candidate
                    break
                }
            }
            if ($match) {
                Write-Host "[INFO] Matched via build folder name version: $($match.FullName)"
            }
        }

        if (-not $match) {
            Write-Host "[ERROR] No UniverseLAN build found with $universeLanDllName version '$($entry.FileVersion)' under $UniverseLANRoot."
            Write-Host "[ERROR] Leaving $dllName untouched - nothing was renamed, copied, or deleted for this entry."
            if (@($candidates).Count -eq 0) {
                Write-Host "[DIAG] No '$universeLanDllName' files found at all under $UniverseLANRoot."
            } else {
                Write-Host "[DIAG] Candidates found (folder version / FileVersion / ProductVersion) - none matched '$($entry.FileVersion)':"
                foreach ($candidate in $candidates) {
                    $vi         = $candidate.VersionInfo
                    $folderName = Split-Path -Leaf (Split-Path -Parent $candidate.FullName)
                    $buildVer   = Get-UniverseLANBuildVersion $folderName
                    Write-Host "  $($candidate.FullName)"
                    Write-Host "      Folder version : $buildVer"
                    Write-Host "      FileVersion    : $($vi.FileVersion)"
                    Write-Host "      ProductVersion : $($vi.ProductVersion)"
                }
            }
            Write-Host ""
            $unmatched.Add([PSCustomObject]@{
                DllName = $dllName
                Path    = $dllPath
                Version = $entry.FileVersion
            })
            continue
        }

        $sourceFolder = Split-Path -Parent $match.FullName
        Write-Host "[INFO] Matching build found: $sourceFolder"

        # 2. Only now that a matching build is confirmed available, back up
        #    the original dll.
        if (Test-Path -LiteralPath $bakPath) {
            Write-Host "[INFO] $dllName.BAK already exists - skipping rename (assuming already backed up)."
        } else {
            Rename-Item -LiteralPath $dllPath -NewName "$dllName.BAK"
            Write-Host "[INFO] Renamed $dllName -> $dllName.BAK"
        }

        # 3. Copy each piece of the matching build to where it actually
        #    belongs - not everything goes into the game folder:
        #      - the dlls/exes go next to the original Galaxy(64).dll, same
        #        as before;
        #      - UniverseLAN.ini goes to %LocalAppData%\UniverseLAN\;
        #      - UniverseLANData and UniverseLANServerData go to
        #        %LocalAppData%\UniverseLAN\<GOG App ID>\, where the App ID
        #        is read from the game folder's goggame-<id>.info file.
        foreach ($f in @('UniverseLANServer64.exe', 'Galaxy.dll', 'Galaxy64.dll', 'UniverseLANServer.exe')) {
            $src = Join-Path $sourceFolder $f
            if (Test-Path -LiteralPath $src) {
                Copy-Item -LiteralPath $src -Destination $dllFolder -Force
                Write-Host "[INFO] Copied $f -> $dllFolder"
            }
        }

        $localAppDataUniverseLan = Join-Path $env:LOCALAPPDATA 'UniverseLAN'
        $iniSrc = Join-Path $sourceFolder 'UniverseLAN.ini'
        $iniDest = Join-Path $localAppDataUniverseLan 'UniverseLAN.ini'
        if (Test-Path -LiteralPath $iniSrc) {
            if (-not (Test-Path -LiteralPath $localAppDataUniverseLan)) {
                New-Item -ItemType Directory -Path $localAppDataUniverseLan -Force | Out-Null
            }
            if (Test-Path -LiteralPath $iniDest) {
                Write-Host "[INFO] UniverseLAN.ini already exists at $localAppDataUniverseLan - keeping the existing file."
            } else {
                Copy-Item -LiteralPath $iniSrc -Destination $localAppDataUniverseLan
            Write-Host "[INFO] Copied UniverseLAN.ini -> $localAppDataUniverseLan"
            }
        } else {
            Write-Host "[WARN] UniverseLAN.ini not found in $sourceFolder - nothing copied."
        }

        $dataFolderNames = @('UniverseLANData', 'UniverseLANServerData')
        $dataFoldersToCopy = @($dataFolderNames | Where-Object { Test-Path -LiteralPath (Join-Path $sourceFolder $_) })
        if ($dataFoldersToCopy.Count -gt 0) {
            # goggame-*.info lives at the game's install root (where this
            # pipeline is run from), not necessarily next to the dll itself
            # (e.g. a game whose Galaxy64.dll sits under bin\x64).
            $gogAppId = Get-GogAppId -GameFolder $GameRoot
            if ($gogAppId) {
                $appDataTarget = Join-Path $localAppDataUniverseLan $gogAppId
                if (-not (Test-Path -LiteralPath $appDataTarget)) {
                    New-Item -ItemType Directory -Path $appDataTarget -Force | Out-Null
                }
                foreach ($folderName in $dataFoldersToCopy) {
                    $folderSrc  = Join-Path $sourceFolder $folderName
                    $folderDest = Join-Path $appDataTarget $folderName
                    # Merge instead of overwrite: existing files (e.g. an
                    # Achievements.ini holding real unlock/save progress)
                    # must never be clobbered by a re-run of this script -
                    # only files missing at the destination are copied in.
                    $copiedAny = $false
                    $skippedAny = $false
                    Get-ChildItem -LiteralPath $folderSrc -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
                        $relativePath = $_.FullName.Substring($folderSrc.Length).TrimStart('\')
                        $destPath = Join-Path $folderDest $relativePath
                        if (Test-Path -LiteralPath $destPath) {
                            $skippedAny = $true
                        } else {
                            $destDir = Split-Path -Parent $destPath
                            if (-not (Test-Path -LiteralPath $destDir)) {
                                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                            }
                            Copy-Item -LiteralPath $_.FullName -Destination $destPath
                            $copiedAny = $true
                        }
                    }
                    if ($copiedAny) {
                        Write-Host "[INFO] Copied new $folderName file(s) -> $folderDest"
                    }
                    if ($skippedAny) {
                        Write-Host "[INFO] $folderName - existing file(s) at $folderDest left untouched."
                    }
                    if (-not $copiedAny -and -not $skippedAny) {
                        Write-Host "[WARN] $folderName in $sourceFolder is empty - nothing copied."
                    }
                }
            } else {
                Write-Host "[WARN] No goggame-*.info found under $GameRoot - could not determine the GOG App ID."
                Write-Host "[WARN] $($dataFoldersToCopy -join ', ') were NOT copied."
            }
        }

        # 4. Clean up the architecture that's not needed, based on the
        #    original file's bitness (not on which .BAK happens to exist).
        if ($is64) {
            foreach ($f in @('Galaxy.dll', 'UniverseLANServer.exe')) {
                $p = Join-Path $dllFolder $f
                if (Test-Path -LiteralPath $p) {
                    Remove-Item -LiteralPath $p -Force
                    Write-Host "[INFO] Removed unneeded 32-bit file: $f"
                }
            }
        } else {
            foreach ($f in @('Galaxy64.dll', 'UniverseLANServer64.exe')) {
                $p = Join-Path $dllFolder $f
                if (Test-Path -LiteralPath $p) {
                    Remove-Item -LiteralPath $p -Force
                    Write-Host "[INFO] Removed unneeded 64-bit file: $f"
                }
            }
        }

        Write-Host ""
    }

    if ($unmatched.Count -gt 0) {
        Write-Host "======================================================================" -ForegroundColor Yellow
        Write-Host " NO MATCHING UNIVERSELAN VERSION FOUND" -ForegroundColor Yellow
        Write-Host "======================================================================" -ForegroundColor Yellow
        foreach ($u in $unmatched) {
            Write-Host " - $($u.DllName)  (Galaxy SDK version $($u.Version))" -ForegroundColor Yellow
            Write-Host "   Left untouched at: $($u.Path)" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host " None of the cached UniverseLAN builds under $UniverseLANRoot cover the" -ForegroundColor Yellow
        Write-Host " Galaxy SDK version(s) above, and none is listed in the compatibility" -ForegroundColor Yellow
        Write-Host " table either. The original dll(s) were left exactly as they were -" -ForegroundColor Yellow
        Write-Host " nothing was backed up, copied, or deleted, so the game still runs" -ForegroundColor Yellow
        Write-Host " normally through GOG Galaxy (LAN emulation was simply not set up)." -ForegroundColor Yellow
        Write-Host ""
        Write-Host " To fix this: check https://github.com/grasmanek94/UniverseLAN for a" -ForegroundColor Yellow
        Write-Host " newer release/older archived build that covers this SDK version, or" -ForegroundColor Yellow
        Write-Host " re-run once a compatible build has been downloaded." -ForegroundColor Yellow
        Write-Host "======================================================================" -ForegroundColor Yellow
        Write-Warning "No matching UniverseLAN version was found for: $(($unmatched | ForEach-Object { $_.DllName }) -join ', ')"
    }

    Write-Host "[INFO] Done."
}