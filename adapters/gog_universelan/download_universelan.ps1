# download_universelan.ps1
#
# Stage 2 of the pipeline. Checks the latest UniverseLAN release against
# what's cached under $CacheRoot; skips entirely if already up to date,
# otherwise downloads + extracts fresh and prunes old cached versions.
# Also fetches the "Galaxy SDK Backwards Compatibility List" table from the
# UniverseLAN README and caches it to disk as JSON, so deploy_universelan.ps1
# can use it (even offline, from the cached copy) to pick the correct build
# for a given GOG Galaxy SDK version.
#
#   - ONE process/one API call, instead of two separate `powershell.exe`
#     invocations (each with its own cold-start cost) and a duplicate
#     GitHub API request.
#   - Downloads via System.Net.WebClient instead of Invoke-WebRequest -
#     Invoke-WebRequest's response parsing/formatting overhead makes it
#     considerably slower for large binary downloads.
#   - Extracts via [System.IO.Compression.ZipFile] directly instead of
#     Expand-Archive, which processes entries one at a time with extra
#     PowerShell-side overhead.
#
# Defines Get-GalaxySdkCompatTable and Invoke-DownloadUniverseLan.
# Dot-source this file to load them; it does nothing on its own when
# dot-sourced.

function Get-GalaxySdkCompatTable {
    # Fetches the "Galaxy SDK Backwards Compatibility List" markdown table
    # from the UniverseLAN README and caches it as JSON under $CacheRoot
    # (galaxy_sdk_compat.json), so it's usable offline later. Falls back to
    # that cached copy if the fetch fails (no network / GitHub unreachable).
    # Returns an array of @{ Release; SdkVersions } objects (possibly empty).
    param(
        [string]$CacheRoot,
        [string]$SourceUrl = 'https://raw.githubusercontent.com/grasmanek94/UniverseLAN/master/README.MD'
    )

    $jsonPath = Join-Path $CacheRoot 'galaxy_sdk_compat.json'
    $table    = $null

    try {
        Write-Host "[INFO] Fetching Galaxy SDK compatibility list..."
        $readme = Invoke-RestMethod -Uri $SourceUrl -Headers @{ 'User-Agent' = 'AchievementEnablerSetup' }
        $lines  = $readme -split "`r?`n"

        $rows    = New-Object System.Collections.Generic.List[object]
        $inTable = $false

        foreach ($line in $lines) {
            if (-not $inTable) {
                if ($line -match '^\s*\|\s*UniverseLAN Release\s*\|') { $inTable = $true }
                continue
            }
            if ($line -match '^\s*\|\s*:-+:?\s*\|') { continue }   # header separator row
            if ($line -notmatch '^\s*\|') { break }                # table ended

            $cells = $line.Trim().Trim('|') -split '\|'
            if ($cells.Count -lt 2) { continue }

            $release     = $cells[0].Trim()
            $sdkVersions = @($cells[1] -split '<br>' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })

            $rows.Add([PSCustomObject]@{
                Release     = $release
                SdkVersions = $sdkVersions
            })
        }

        if ($rows.Count -gt 0) {
            $table = $rows
            $table | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $jsonPath -Encoding UTF8
            Write-Host "[INFO] Galaxy SDK compatibility list cached for offline use: $jsonPath ($($table.Count) rows)"
        } else {
            Write-Host "[WARN] Could not parse a compatibility table out of the README - keeping any existing cached copy."
        }
    } catch {
        Write-Host "[WARN] Could not fetch Galaxy SDK compatibility list (offline?): $_"
    }

    if (-not $table) {
        if (Test-Path -LiteralPath $jsonPath) {
            Write-Host "[INFO] Using previously cached Galaxy SDK compatibility list: $jsonPath"
            try {
                $table = @(Get-Content -LiteralPath $jsonPath -Encoding UTF8 -Raw | ConvertFrom-Json)
            } catch {
                Write-Host "[WARN] Cached compatibility list is unreadable: $_"
                $table = @()
            }
        } else {
            Write-Host "[WARN] No cached Galaxy SDK compatibility list available."
            $table = @()
        }
    }

    return , $table
}

function Invoke-DownloadUniverseLan {
    param([string]$CacheRoot)

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $repoOwner = 'grasmanek94'
    $repoName  = 'UniverseLAN'

    if (-not (Test-Path -LiteralPath $CacheRoot)) {
        New-Item -ItemType Directory -Path $CacheRoot -Force | Out-Null
    }

    Get-GalaxySdkCompatTable -CacheRoot $CacheRoot | Out-Null
    Write-Host ""

    Write-Host "Checking latest UniverseLAN release..."

    $headers = @{ 'User-Agent' = 'AchievementEnablerSetup' }

    try {
        $release = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$repoOwner/$repoName/releases/latest"
    } catch {
        Write-Host "[ERROR] Could not fetch the latest release: $_"
        return
    }

    $tag     = if ($release.tag_name) { $release.tag_name } else { $release.name }
    $safeTag = ($tag.Split([IO.Path]::GetInvalidFileNameChars()) -join '_')
    $tagDir  = Join-Path $CacheRoot $safeTag

    $expectedFiles = @('Galaxy.dll', 'Galaxy64.dll', 'UniverseLANServer.exe', 'UniverseLANServer64.exe')
    $hasExpectedFile = $false
    if (Test-Path -LiteralPath $tagDir) {
        $hasExpectedFile = [bool](Get-ChildItem -LiteralPath $tagDir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $expectedFiles -contains $_.Name } | Select-Object -First 1)
    }

    if ($hasExpectedFile) {
        Write-Host "[INFO] UniverseLAN $safeTag is up to date and already cached - skipping."
        Write-Host "[INFO] UniverseLAN files kept at: $tagDir"
        return
    }
    if ((Test-Path -LiteralPath $tagDir) -and -not $hasExpectedFile) {
        Write-Host "[WARN] Cached UniverseLAN $safeTag folder exists but looks incomplete - re-downloading."
    }

    $zipAssets = @($release.assets | Where-Object { $_.name -like '*.zip' })
    if ($zipAssets.Count -eq 0) {
        Write-Host "[WARN] No .zip assets found on the latest release."
        return
    }

    if (-not (Test-Path -LiteralPath $tagDir)) {
        New-Item -ItemType Directory -Path $tagDir -Force | Out-Null
    }

    Write-Host "[INFO] Downloading UniverseLAN $safeTag ($($zipAssets.Count) file(s))..."

    $webClient = New-Object System.Net.WebClient
    $webClient.Headers.Add('User-Agent', 'AchievementEnablerSetup')

    foreach ($asset in $zipAssets) {
        $zipPath     = Join-Path $tagDir $asset.name
        $extractName = [System.IO.Path]::GetFileNameWithoutExtension($asset.name)
        $extractPath = Join-Path $tagDir $extractName

        Write-Host "[INFO] Downloading $($asset.name)..."
        try {
            $webClient.DownloadFile($asset.browser_download_url, $zipPath)
        } catch {
            Write-Host "[ERROR] Download failed for $($asset.name): $_"
            continue
        }

        Write-Host "[INFO] Extracting to $extractName..."
        try {
            if (Test-Path -LiteralPath $extractPath) {
                Remove-Item -LiteralPath $extractPath -Recurse -Force
            }
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractPath)
        } catch {
            Write-Host "[ERROR] Extraction failed for $($asset.name): $_"
            continue
        }

        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    }

    $webClient.Dispose()

    Get-ChildItem -LiteralPath $CacheRoot -Directory |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 1 |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "[INFO] Removed old cached version: $($_.Name)"
        }

    Write-Host ""
    Write-Host "[INFO] UniverseLAN files kept at: $tagDir"
}