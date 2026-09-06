# adapters\epic_nemirtingas_epic_emulator\download_nemir_epic_emu.ps1
# Downloads release asset(s) from GitLab's public Releases API
# (Nemirtingas/EpicEmulatorRegistry), with a latest -> cached-backup
# fallback chain.
#
# By default (-AssetPattern '*') downloads EVERY asset in the latest
# release. A single release carries several asset variants (plain /
# _no_network / _nucleuscoop, per architecture/platform). Each variant gets
# its OWN subfolder under the release's tag folder, named after the asset
# with platform tokens stripped (so Win64/Win32 variants of the same flavor
# share one folder) but the extension/suffix preserved (so plain/_no_network/
# _nucleuscoop don't collide). This mirrors download_gitlab_helper.bat's
# :__POWERSHELL__ block exactly - do not flatten these into a single
# per-release folder, and do not strip the extension when building a variant
# folder name (see Get-VariantFolderName for why).
#
# Dot-sourced by write_config.ps1 - defines Invoke-DownloadNemirEpicEmu only.
# Return value: with a wildcard -AssetPattern (the default), returns the
# whole release folder (containing every variant subfolder). With an exact
# filename -AssetPattern, returns just that one variant's folder.

function Invoke-DownloadNemirEpicEmu {
    param(
        [Parameter(Mandatory)][string]$CacheRoot,
        [string]$Project      = 'Nemirtingas%2FEpicEmulatorRegistry',
        [string]$AssetPattern = '*'
    )

    $ErrorActionPreference = 'Stop'
    $progressPreference = 'silentlyContinue'
    $headers = @{ 'User-Agent' = 'AchievementEnablerSetup' }

    if ($Project -match '\s' -or $AssetPattern -match '\s') {
        Write-Host "[ERROR] -Project or -AssetPattern contains whitespace - refusing to proceed (Project='$Project', AssetPattern='$AssetPattern')."
        return $null
    }

    $projectDirName = ($Project -split '%2F')[-1]
    $repoDir = Join-Path $CacheRoot $projectDirName
    if (-not (Test-Path -LiteralPath $repoDir)) {
        New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
    }

    function Get-LatestLinksByName($Release) {
        # GitLab's API has been observed returning inconsistent data for this
        # repo's single aggregated release object: one direct query returned
        # 12 links (one per platform/variant, no duplicates), a query moments
        # later - through the exact same code path - returned 240 links (16
        # names x ~15 historical uploads each, confirmed via live [DIAG]
        # logging during an actual _Achievement_Enabler.bat run). This is not
        # something the caller can predict or rely on being clean, so always
        # defensively dedupe by name here regardless of what the array looks
        # like on any given call. Asset ids increase monotonically with
        # upload time, so the highest id per name is that name's newest
        # upload - safe to pick even when the array happens to already be
        # deduplicated (a group of one just returns that one entry).
        $links = @()
        if ($Release.assets -and $Release.assets.links) { $links = @($Release.assets.links) }

        return @($links |
            Group-Object -Property name |
            ForEach-Object { $_.Group | Sort-Object -Property id -Descending | Select-Object -First 1 })
    }

    function Get-TagList($Release) {
        # This GitLab project publishes ONE release object whose tag_name is
        # an array of every tag ever released, newest first - not one release
        # object per tag like the GitLab API normally works. Normalize to a
        # flat array of individual tag strings regardless of which shape we
        # get, so a single string still works if the API ever changes.
        $raw = $Release.tag_name
        if ($raw -is [array]) { return @($raw) }
        return @([string]$raw -split '\s+' | Where-Object { $_ })
    }

    function Get-ReleaseDir([string]$Tag) {
        $safeTag = ($Tag.Split([IO.Path]::GetInvalidFileNameChars()) -join '_')
        return (Join-Path $repoDir $safeTag)
    }

    function Get-VariantFolderName([string]$AssetName) {
        # Strip platform/arch tokens so e.g. Win64 and Win32 builds of the
        # same flavor (plain / _no_network / _nucleuscoop) share one folder.
        # Deliberately does NOT strip the trailing extension/suffix - doing
        # so previously collapsed "EOSSDK-Win64-Shipping.dll",
        # "...dll_no_network" and "...dll_nucleuscoop" into the SAME folder
        # name ("EOSSDK-Shipping"), because .NET's GetFileNameWithoutExtension
        # treats everything after the last '.' as one extension, including
        # "_no_network"/"_nucleuscoop". That caused the three variants to
        # silently overwrite each other on disk. Matches
        # download_gitlab_helper.bat's original (working) logic exactly.
        $normalized = $AssetName -replace '(?i)-(Win64|Win32|Mac|LinuxArm64|Linux)-', '-'
        $normalized = $normalized -replace '(?i)^lib', ''
        $normalized = $normalized -replace '(?i)\.(so-arm64|so\.linux-x64)', '.so'
        return ($normalized.Split([IO.Path]::GetInvalidFileNameChars()) -join '_')
    }

    function Test-CachedRelease([string]$Tag, [int]$ExpectedCount = 0) {
        $releaseDir = Get-ReleaseDir $Tag
        if (-not (Test-Path -LiteralPath $releaseDir)) { return $false }
        $onDiskCount = (Get-ChildItem -LiteralPath $releaseDir -Recurse -File -ErrorAction SilentlyContinue).Count
        if ($ExpectedCount -gt 0) { return $onDiskCount -ge $ExpectedCount }
        return $onDiskCount -gt 0
    }

    function Find-WantedInReleaseDir([string]$ReleaseDir, [string]$Pattern) {
        # A wildcard pattern (the default - fetch every asset) has no single
        # "wanted" variant folder; the caller wants the whole release
        # directory, and deploy_nemir_epic_emu.ps1 already searches it
        # recursively for whichever specific file it needs.
        if ($Pattern -match '[*?]') { return $ReleaseDir }

        # Otherwise the wanted variant folder is whichever subfolder's name
        # matches -AssetPattern once platform tokens are stripped the same way.
        $wantedFolder = Get-VariantFolderName $Pattern
        $exact = Join-Path $ReleaseDir $wantedFolder
        if (Test-Path -LiteralPath $exact) {
            $hit = Get-ChildItem -LiteralPath $exact -File -Filter $Pattern -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { return $hit.DirectoryName }
        }
        # Fallback: scan every variant subfolder for a file matching the pattern.
        $hit = Get-ChildItem -LiteralPath $ReleaseDir -Recurse -File -Filter $Pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.DirectoryName }
        return $null
    }

    function Try-Asset($Release, [string]$Tag, [string]$Label) {
        $links = Get-LatestLinksByName $Release

        $picked = @($links | Where-Object { $_.name -like $AssetPattern -or ($_.name -replace '^.*[\\/]', '') -like $AssetPattern })
        if ($picked.Count -eq 0) {
            Write-Host ("[WARN] No asset matching {0} in {1} release {2}." -f $AssetPattern, $Label, $Tag)
            return $null
        }

        $releaseDir = Get-ReleaseDir $Tag
        $anySucceeded = $false

        foreach ($match in $picked) {
            $realFileName = $match.name -replace '^.*[\\/]', ''
            $safeDisplayName = Get-VariantFolderName $match.name

            $variantDir = Join-Path $releaseDir $safeDisplayName
            if (-not (Test-Path -LiteralPath $variantDir)) {
                New-Item -ItemType Directory -Path $variantDir -Force | Out-Null
            }

            $out = Join-Path $variantDir $realFileName
            $tmp = "$out.download"

            Write-Host ("[INFO] Downloading {0} (variant folder: {1}) from {2} release {3}..." -f $realFileName, $safeDisplayName, $Label, $Tag)
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

            try {
                $downloadUrl = if ($match.direct_asset_url) { $match.direct_asset_url } else { $match.url }
                Invoke-WebRequest -Headers $headers -Uri $downloadUrl -OutFile $tmp -UseBasicParsing

                if ((Test-Path -LiteralPath $tmp) -and ((Get-Item -LiteralPath $tmp).Length -gt 0)) {
                    Move-Item -LiteralPath $tmp -Destination $out -Force
                    $anySucceeded = $true
                }
            } catch {
                Write-Host ("[WARN] {0} release download failed for variant {1}: {2}" -f $Label, $safeDisplayName, $_.Exception.Message)
            }
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }

        if ($anySucceeded) {
            # Only now that this release is fully populated, prune every
            # OTHER tag folder under $repoDir - keep just this one.
            Get-ChildItem -LiteralPath $repoDir -Directory |
                Where-Object { $_.FullName -ne $releaseDir } |
                ForEach-Object {
                    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Host ("[INFO] Removed old cached version: {0}" -f $_.Name)
                }

            return Find-WantedInReleaseDir -ReleaseDir $releaseDir -Pattern $AssetPattern
        }

        return $null
    }

    try {
        $releasesUrl = "https://gitlab.com/api/v4/projects/$Project/releases"
        $all = @(Invoke-RestMethod -Headers $headers -Uri $releasesUrl -UseBasicParsing)

        if ($all.Count -eq 0) { throw 'No releases returned.' }

        # This project publishes ONE release object carrying every historical
        # tag in tag_name (newest first), rather than one release object per
        # tag. All tags share the same $release.assets.links list, so "try
        # the latest tag" and "try the previous tag" both pull from the same
        # asset list - only the destination folder name (per tag) differs.
        $release = $all[0]
        $tags = Get-TagList $release
        if ($tags.Count -eq 0) { throw 'Release object has no usable tag_name.' }

        $latestTag = $tags[0]

        $expectedLinks = @(Get-LatestLinksByName $release | Where-Object { $_.name -like $AssetPattern -or ($_.name -replace '^.*[\\/]', '') -like $AssetPattern })
        $expectedCount = $expectedLinks.Count

        if (Test-CachedRelease $latestTag $expectedCount) {
            $releaseDir = Get-ReleaseDir $latestTag
            $wanted = Find-WantedInReleaseDir -ReleaseDir $releaseDir -Pattern $AssetPattern
            if ($wanted) {
                Write-Host ("[INFO] Latest release {0} already cached - skipping download." -f $latestTag)
                return $wanted
            }
            Write-Host ("[INFO] Latest release {0} cached but missing {1} - re-downloading." -f $latestTag, $AssetPattern)
        }

        Write-Host ("[INFO] Latest release {0} not (fully) cached - downloading..." -f $latestTag)
        $result = Try-Asset $release $latestTag 'latest'
        if ($result) { return $result }

        # NOTE: there is no meaningful "try the previous tag" fallback here.
        # This repo publishes ONE release object with ONE shared
        # assets.links list - after Get-LatestLinksByName's dedup there is
        # exactly one entry per platform/variant, but that single list still
        # isn't scoped to any particular tag. There is nothing that
        # distinguishes "this tag's assets" from "that tag's assets" to
        # retry against. If the latest tag's download fails, fall through to
        # the on-disk cached-backup check below instead of re-downloading
        # the same assets under a different folder name.
    } catch {
        Write-Host ("[WARN] GitLab release lookup failed: {0}" -f $_.Exception.Message)
    }

    if ($AssetPattern -match '[*?]') {
        $cachedReleaseDir = Get-ChildItem -LiteralPath $repoDir -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($cachedReleaseDir) {
            Write-Host ("[WARN] GitLab download failed. Using cached backup release folder: {0}" -f $cachedReleaseDir.FullName)
            return $cachedReleaseDir.FullName
        }
    } else {
        $cached = Get-ChildItem -LiteralPath $repoDir -Filter $AssetPattern -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($cached) {
            Write-Host ("[WARN] GitLab download failed. Using cached backup: {0}" -f $cached.FullName)
            return $cached.DirectoryName
        }
    }

    Write-Host ("[ERROR] Failed to download {0} from GitLab and no cached backup exists." -f $AssetPattern)
    return $null
}
