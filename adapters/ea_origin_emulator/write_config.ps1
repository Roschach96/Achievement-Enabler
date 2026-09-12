# adapters\ea_origin_emulator\write_config.ps1
#
# Hands off to origin_helper.py (+ get_token.py alongside it, both shipped
# inside this adapter folder) to generate anadius.cfg. That tool's own
# interactive prompts run exactly as they do standalone - this hook just
# launches it with the right paths and checks the result.
#
# Once anadius.cfg is written, this also:
#   - Moves anadius.cfg from the game root to sit next to the SELECTED exe
#     (which can be nested arbitrarily deep, e.g.
#     00_game\target_origin\ex\WILD HEARTS.exe) - the emulator needs it
#     right there, not at the top-level game folder.
#   - Copies the matching anadius32.dll / anadius64.dll from this adapter's
#     own "Origin Emulator\" subfolder to that same location, based on the
#     bitness of that specific exe (read from installerdata.xml's own
#     per-launcher <requires64BitOS> flag, matched by filename - falling
#     back to the top-level <buildMetaData><requirements osReqs64Bit>
#     attribute only if no per-launcher entry matches).
#   Both anadius32.dll and anadius64.dll must be placed at
#   adapters\ea_origin_emulator\Origin Emulator\ for the copy step to work -
#   they aren't shipped here, since they're anadius's own emulator binaries.
#   - Runs Origin Unwrapper\origin_unwrapper.py --add-dll <selected exe>
#     (installing its requirements.txt via pip first, if present - pip
#     itself skips anything already installed and satisfied, so this is
#     safe to run on every invocation), then moves whatever "*fixed.exe" it
#     produces - next to _Achievement_Enabler.bat itself, i.e. the
#     orchestrator's own root folder, since that's where origin_unwrapper.py
#     writes it (relative to its current working directory, not its own
#     script location or the input exe's folder - confirmed directly) -
#     over to sit next to the selected exe too. origin_unwrapper.py itself
#     isn't shipped here either - same as the DLLs above, it's anadius's own
#     tool and must be placed at
#     adapters\ea_origin_emulator\Origin Unwrapper\origin_unwrapper.py.
#
# No SteamCMD manifest fetch here: confirmed against a real manifest for an
# EA/Steam-cross-listed game that its "launch" entries are link2ea://... /
# steam2ea://... protocol handlers, not a literal local .exe path - EA
# publishes its Steam listings as a hand-off to the EA App itself. So there
# is no usable executable/arguments to extract from the manifest for this
# adapter's target games; Jokerverse's own real EA-game export (Need for
# Speed Unbound) confirms this too, leaving those three fields blank rather
# than trying to force a value into them.
#
# Denuvo boundary (unchanged from origin_helper.py itself): DenuvoToken is
# never auto-filled here - it stays the "PASTE_..." placeholder
# origin_helper.py already writes, since it's a live credential from the
# user's own EA activation that this hook doesn't try to source or
# generate. DenuvoExeHash/DenuvoDllHash ARE patched in with real SHA-1
# values though - just local file checksums: DenuvoExeHash from the
# "*fixed.exe" origin_unwrapper.py produces (the file that actually gets
# run, not the original pre-patched exe), DenuvoDllHash from dbdata.dll.
#
# All inputs come in via env vars set by AchievementEnabler.bat:
#
#   AE_GAME_FOLDER   - game root (contains __Installer\installerdata.xml)
#   AE_ADAPTER_DIR   - full path to adapters\ea_origin_emulator (this folder)
#   AE_EXE_PATH      - full path to the selected game exe (from find_paths.ps1)

$gameFolder = $env:AE_GAME_FOLDER
$adapterDir = $env:AE_ADAPTER_DIR
$exePath    = $env:AE_EXE_PATH

$missing = @()
if (-not $gameFolder) { $missing += "AE_GAME_FOLDER" }
if (-not $adapterDir) { $missing += "AE_ADAPTER_DIR" }

if ($missing.Count -gt 0) {
    Write-Host "[ERROR] ea_origin_emulator\write_config.ps1: missing env var(s): $($missing -join ', ')"
    exit 1
}

$installerDataPath = Join-Path $gameFolder "__Installer\installerdata.xml"
if (-not (Test-Path -LiteralPath $installerDataPath)) {
    Write-Host "[ERROR] installerdata.xml not found at: $installerDataPath"
    Write-Host "[ERROR] This adapter should only run when that marker file exists."
    exit 1
}

$originHelperScript = Join-Path $adapterDir "origin_helper.py"
$getTokenScript      = Join-Path $adapterDir "get_token.py"
if (-not (Test-Path -LiteralPath $originHelperScript)) {
    Write-Host "[ERROR] origin_helper.py not found at: $originHelperScript"
    Write-Host "[ERROR] It should ship inside adapters\ea_origin_emulator\ alongside this script."
    exit 1
}
if (-not (Test-Path -LiteralPath $getTokenScript)) {
    Write-Host "[WARN] get_token.py not found next to origin_helper.py - the real-EA-profile"
    Write-Host "[WARN] option (choice 1) will fail; the anadius placeholder option (choice 2) still works."
}

# ── Find a Python interpreter (same lookup order used elsewhere in this project) ──
$pyExe = $null
$pyVerArg = $null
if (Get-Command py -ErrorAction SilentlyContinue) {
    $pyExe = "py"
    $pyVerArg = "-3"
} elseif (Get-Command python -ErrorAction SilentlyContinue) {
    $pyExe = "python"
}

if (-not $pyExe) {
    Write-Host "[ERROR] This adapter (EA/Origin - anadius Denuvo/Origin Emulator) requires Python,"
    Write-Host "[ERROR] and it wasn't found (checked 'py' and 'python' on PATH)."
    Write-Host "[ERROR] Install Python from https://www.python.org/downloads/"
    Write-Host "[ERROR] Be sure to select \"Add python.exe to PATH\" while installing, then rerun this script."
    exit 1
}

$exeDir = Split-Path -Parent $exePath
$outputCfgPath = Join-Path $exeDir "anadius.cfg"

Write-Host ""
Write-Host "Handing off to origin_helper.py to generate anadius.cfg..."
Write-Host "(This has its own prompts - SteamDB achievement paste, EA profile choice, etc."
Write-Host " Follow them the same way you would running the script standalone.)"
Write-Host ""

$argList = @()
if ($pyVerArg) { $argList += $pyVerArg }
$argList += $originHelperScript
$argList += $installerDataPath
$argList += "--out"
$argList += $outputCfgPath

& $pyExe @argList
$originHelperExitCode = $LASTEXITCODE

Write-Host ""
if (Test-Path -LiteralPath $outputCfgPath) {
    Write-Host "[INFO] anadius.cfg written to: $outputCfgPath"
} else {
    Write-Host "[WARN] origin_helper.py finished (exit code $originHelperExitCode) but anadius.cfg was not found at:"
    Write-Host "[WARN]   $outputCfgPath"
    Write-Host "[WARN] Check the output above for errors."
}

# ---------------------------------------------------------------------------
# anadius.cfg is written directly into the exe's own folder above (via
# --out) rather than the game root - no separate move step needed. This
# matters beyond just convenience: origin_helper.py itself checks whether
# anadius.cfg ALREADY exists at the --out path before deciding whether to
# do a full rewrite or patch just the Achievements block (preserving any
# manual edits - a real DenuvoToken, custom Entitlements, etc.). If --out
# pointed at the game root while the real, persistent file actually lived
# next to the exe (as an earlier version of this script did, moving it
# there only AFTER origin_helper.py ran), that check would find nothing on
# every subsequent run - the game root copy is empty after the first
# move - and silently do a full rewrite over the user's real file with no
# backup, since the .BAK step lives inside that same check.
#
# Bitness comes from installerdata.xml's own per-launcher
# <requires64BitOS> flag, matched by filename against the selected exe (a
# game can ship separate 32-bit/64-bit launcher entries, so this is more
# precise than the single top-level <buildMetaData><requirements
# osReqs64Bit> attribute) - falling back to that top-level attribute only
# if no per-launcher entry matches.
# ---------------------------------------------------------------------------

$is64Bit = $null
try {
    [xml]$installerXml = Get-Content -LiteralPath $installerDataPath -Raw
    $exeFileName = Split-Path -Leaf $exePath

    foreach ($launcher in $installerXml.SelectNodes("//runtime/launcher")) {
        $filePath = $launcher.filePath
        if ($filePath) {
            # Plain string split rather than Split-Path -Leaf: filePath looks
            # like "[HKEY_LOCAL_MACHINE\...\Install Dir]00_game\...\Game.exe" -
            # a registry-macro prefix that isn't a real path, so this just
            # takes whatever follows the LAST backslash rather than relying
            # on a path cmdlet to make sense of the whole string.
            $parts = $filePath.Trim().Split('\')
            $launcherExeName = $parts[$parts.Length - 1]
            if ($launcherExeName -ieq $exeFileName) {
                $req = $launcher.requires64BitOS
                if ($req) {
                    $is64Bit = ($req.Trim() -eq "1")
                    Write-Host "[INFO] Bitness from installerdata.xml launcher entry for '$exeFileName': $(if ($is64Bit) {'64-bit'} else {'32-bit'})"
                }
                break
            }
        }
    }

    if ($null -eq $is64Bit) {
        $reqNode = $installerXml.SelectSingleNode("//buildMetaData/requirements")
        if ($reqNode -and $reqNode.osReqs64Bit) {
            $is64Bit = ($reqNode.osReqs64Bit -ieq "True")
            Write-Host "[INFO] No per-launcher match for '$exeFileName' - using top-level osReqs64Bit: $(if ($is64Bit) {'64-bit'} else {'32-bit'})"
        }
    }
} catch {
    Write-Host "[WARN] Could not parse installerdata.xml for bitness: $_"
}

if ($null -eq $is64Bit) {
    Write-Host "[WARN] Could not determine game bitness from installerdata.xml - skipping anadius DLL copy."
} else {
    $dllName   = if ($is64Bit) { "anadius64.dll" } else { "anadius32.dll" }
    $dllSource = Join-Path $adapterDir "Origin Emulator\$dllName"
    $dllDest   = Join-Path $exeDir $dllName

    if (-not (Test-Path -LiteralPath $dllSource)) {
        Write-Host "[WARN] $dllSource not found - skipping DLL copy."
        Write-Host "[WARN] Expected it at: adapters\ea_origin_emulator\Origin Emulator\$dllName"
    } else {
        try {
            Copy-Item -LiteralPath $dllSource -Destination $dllDest -Force
            Write-Host "[INFO] Copied $dllName to: $dllDest"
        } catch {
            Write-Host "[WARN] Could not copy $dllName : $_"
        }
    }
}

# ---------------------------------------------------------------------------
# Run origin_unwrapper.py against the selected exe (adds the anadius DLL
# reference into the exe itself, e.g. patching its import table), then move
# whatever "*fixed.exe" it produces over to sit next to the selected exe -
# same folder as anadius.cfg and the DLL above.
#
# origin_unwrapper.py writes its output relative to the process's current
# working directory, not relative to its own script location - and that cwd
# turns out to be wherever _Achievement_Enabler.bat itself lives (confirmed:
# it's not next to origin_unwrapper.py, and not the game/exe folder either).
# Rather than depend on that cwd actually being in effect when this script
# runs (fragile - it can vary by how the orchestrator gets launched), this
# derives the same folder structurally: adapters\ea_origin_emulator is
# always exactly two levels below the orchestrator's own root, regardless
# of runtime cwd state.
# ---------------------------------------------------------------------------
$unwrapperDir    = Join-Path $adapterDir "Origin Unwrapper"
$unwrapperScript = Join-Path $unwrapperDir "origin_unwrapper.py"
$toolsRoot        = Split-Path -Parent (Split-Path -Parent $adapterDir)
$fixedExeDest     = $null

if (-not (Test-Path -LiteralPath $unwrapperScript)) {
    Write-Host "[WARN] origin_unwrapper.py not found at: $unwrapperScript - skipping this step."
} else {
    $requirementsPath = Join-Path $unwrapperDir "requirements.txt"
    if (Test-Path -LiteralPath $requirementsPath) {
        Write-Host ""
        Write-Host "Installing origin_unwrapper.py's requirements (pip skips anything already satisfied)..."

        $pipArgList = @()
        if ($pyVerArg) { $pipArgList += $pyVerArg }
        $pipArgList += "-m"
        $pipArgList += "pip"
        $pipArgList += "install"
        $pipArgList += "-r"
        $pipArgList += $requirementsPath

        & $pyExe @pipArgList
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[WARN] pip install exited with code $LASTEXITCODE - origin_unwrapper.py may fail to run."
        }
    } else {
        Write-Host "[INFO] No requirements.txt found next to origin_unwrapper.py - skipping pip install."
    }

    Write-Host ""
    Write-Host "Running origin_unwrapper.py against the selected exe..."

    # If a .BAK from a previous run already exists, the TRUE original exe
    # lives there - $exePath itself, by now, holds the PREVIOUSLY fixed exe
    # (from that earlier run's swap), not the original. Feeding that back
    # into origin_unwrapper.py would double-patch an already-patched exe,
    # operating on the wrong input entirely - so the .BAK, when present, is
    # what actually gets passed to --add-dll, never $exePath in that case.
    $exeBakPath = "$exePath.BAK"
    $hadExistingBak = Test-Path -LiteralPath $exeBakPath
    $unwrapInput = if ($hadExistingBak) { $exeBakPath } else { $exePath }
    if ($hadExistingBak) {
        Write-Host "[INFO] .BAK already exists - using the true original ($unwrapInput) as the unwrap input, not the currently-fixed exe."
    }

    $unwrapArgList = @()
    if ($pyVerArg) { $unwrapArgList += $pyVerArg }
    $unwrapArgList += $unwrapperScript
    $unwrapArgList += "--add-dll"
    $unwrapArgList += $unwrapInput

    & $pyExe @unwrapArgList
    $unwrapperExitCode = $LASTEXITCODE
    if ($unwrapperExitCode -ne 0) {
        Write-Host "[WARN] origin_unwrapper.py exited with code $unwrapperExitCode - check the output above."
    }

    # origin_unwrapper.py (or something its run triggers - its own internals
    # aren't visible here) can leave a __pycache__ folder in the exe's own
    # directory, i.e. inside the actual game folder. Harmless either way -
    # it's just Python's own bytecode cache, self-regenerating and safe to
    # delete - but a stray dev-tool artifact doesn't belong in the user's
    # game install, so it's removed here regardless of what put it there.
    $strayPycache = Join-Path $exeDir "__pycache__"
    if (Test-Path -LiteralPath $strayPycache) {
        try {
            Remove-Item -LiteralPath $strayPycache -Recurse -Force
            Write-Host "[INFO] Removed stray __pycache__ folder from: $exeDir"
        } catch {
            Write-Host "[WARN] Could not remove $strayPycache : $_"
        }
    }

    $fixedExeCandidates = Get-ChildItem -LiteralPath $toolsRoot -Filter '*fixed.exe' -File -ErrorAction SilentlyContinue
    if (-not $fixedExeCandidates) {
        Write-Host "[WARN] No *fixed.exe found next to _Achievement_Enabler.bat ($toolsRoot) after running it - nothing to swap in."
    } else {
        if ($fixedExeCandidates.Count -gt 1) {
            Write-Host "[WARN] Multiple *fixed.exe files found - using the most recently modified one:"
            $fixedExeCandidates | ForEach-Object { Write-Host "  $($_.Name)  ($($_.LastWriteTime))" }
            $fixedExe = $fixedExeCandidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        } else {
            $fixedExe = $fixedExeCandidates[0]
        }

        # Move the fixed exe into place under the ORIGINAL exe's exact
        # filename, so the game's own shortcut/launcher (which expects that
        # name) ends up running the patched exe. First run: back up the
        # true original (currently at $exePath) as .BAK before overwriting
        # it. Re-run: the .BAK already holds the true original from before -
        # just remove the previously-fixed exe at $exePath and replace it,
        # without touching the existing .BAK at all.
        if (-not $hadExistingBak) {
            try {
                Rename-Item -LiteralPath $exePath -NewName (Split-Path -Leaf $exeBakPath)
                Write-Host "[INFO] Backed up original exe to: $exeBakPath"
            } catch {
                Write-Host "[WARN] Could not back up the original exe to .BAK: $_"
            }
        } else {
            Write-Host "[INFO] Replacing the previously-fixed exe at $exePath - .BAK left as-is."
            if (Test-Path -LiteralPath $exePath) {
                try {
                    Remove-Item -LiteralPath $exePath -Force
                } catch {
                    Write-Host "[WARN] Could not remove the previous fixed exe before replacing it: $_"
                }
            }
        }

        try {
            Move-Item -LiteralPath $fixedExe.FullName -Destination $exePath -Force
            Write-Host "[INFO] $($fixedExe.Name) is now: $exePath"
            $fixedExeDest = $exePath
        } catch {
            Write-Host "[WARN] Could not move $($fixedExe.Name) into place: $_"
            $fixedExeDest = $null
        }
    }
}

# ---------------------------------------------------------------------------
# Patch DenuvoExeHash/DenuvoDllHash into anadius.cfg with real SHA-1 values -
# unlike DenuvoToken (a live credential from the user's own EA activation,
# which this adapter still never sources or generates), these two are just
# checksums of local files the user already has.
#
# DenuvoExeHash is the hash of the "*fixed.exe" origin_unwrapper.py just
# produced (moved to $fixedExeDest above), NOT the original selected exe -
# that patched file is the one that actually gets run, so it's the one
# Denuvo's own check needs to match. If the unwrapper step didn't produce
# one, DenuvoExeHash is left as its placeholder rather than hashing the
# wrong (unpatched) file.
#
# DenuvoDllHash (of dbdata.dll) detects whether the game has since been
# updated - unaffected by the unwrapper step, so it's independent of
# whether a *fixed.exe exists.
#
# Both stay as their placeholder text if the target file can't be found,
# rather than blocking the rest of the setup on it.
# ---------------------------------------------------------------------------
if (Test-Path -LiteralPath $outputCfgPath) {
    $cfgText = Get-Content -LiteralPath $outputCfgPath -Raw -Encoding UTF8

    # Two different reasons there might be nothing to patch, worth telling
    # apart rather than reporting both the same way: the key not existing
    # AT ALL means origin_helper.py found no dbdata.dll for this game (no
    # Denuvo fields were ever written); the key existing but already
    # holding a real value (not the placeholder) means it was already
    # patched on a previous run - dbdata.dll clearly WAS found that time,
    # so blaming a missing dbdata.dll here would be simply wrong.
    $hasExeHashKey = $cfgText.Contains('"DenuvoExeHash"')
    $hasDllHashKey = $cfgText.Contains('"DenuvoDllHash"')
    $needsExeHash  = $cfgText.Contains('"DENUVO_EXE_HASH"')
    $needsDllHash  = $cfgText.Contains('"DENUVO_DLL_HASH"')

    if (-not $hasExeHashKey -and -not $hasDllHashKey) {
        Write-Host "[INFO] anadius.cfg has no Denuvo hash fields (no dbdata.dll found for this game) - nothing to patch."
    } elseif (-not $needsExeHash -and -not $needsDllHash) {
        Write-Host "[INFO] DenuvoExeHash/DenuvoDllHash are already filled in (not placeholders) - nothing new to patch."
    }

    if ($needsExeHash) {
        if ($fixedExeDest -and (Test-Path -LiteralPath $fixedExeDest)) {
            try {
                $exeHash = (Get-FileHash -LiteralPath $fixedExeDest -Algorithm SHA1).Hash
                $cfgText = $cfgText -replace '"DENUVO_EXE_HASH"', "`"$exeHash`""
                Write-Host "[INFO] DenuvoExeHash ($exeHash) computed from: $fixedExeDest"
            } catch {
                Write-Host "[WARN] Could not hash the fixed exe: $_"
            }
        } else {
            Write-Host "[WARN] No *fixed.exe available to hash - leaving DenuvoExeHash as a placeholder."
        }
    }

    if ($needsDllHash) {
        $dbdataDll = Join-Path $exeDir "dbdata.dll"
        if (-not (Test-Path -LiteralPath $dbdataDll)) {
            $found = Get-ChildItem -LiteralPath $gameFolder -Recurse -Filter "dbdata.dll" -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $dbdataDll = $found.FullName }
        }

        if (Test-Path -LiteralPath $dbdataDll) {
            try {
                $dllHash = (Get-FileHash -LiteralPath $dbdataDll -Algorithm SHA1).Hash
                $cfgText = $cfgText -replace '"DENUVO_DLL_HASH"', "`"$dllHash`""
                Write-Host "[INFO] DenuvoDllHash ($dllHash) computed from: $dbdataDll"
            } catch {
                Write-Host "[WARN] Could not hash dbdata.dll : $_"
            }
        } else {
            Write-Host "[WARN] dbdata.dll not found under $gameFolder - leaving DenuvoDllHash as a placeholder."
        }
    }

    if ($needsExeHash -or $needsDllHash) {
        try {
            [System.IO.File]::WriteAllText($outputCfgPath, $cfgText, [System.Text.UTF8Encoding]::new($false))
        } catch {
            Write-Host "[WARN] Could not write hash values back into anadius.cfg: $_"
        }
    }
}

# ---------------------------------------------------------------------------
# Tell the orchestrator what "the executable that actually launches this
# game" is. anadius has no separate loader like ColdClient's - the game's
# own exe is launched directly with anadius.cfg sitting next to it.
# ---------------------------------------------------------------------------
[System.IO.File]::WriteAllLines(
    (Join-Path $gameFolder "_ae_final_exe.cmd"),
    @("set `"AE_FINAL_EXECUTABLE=$exePath`""),
    [System.Text.Encoding]::ASCII
)

exit 0
