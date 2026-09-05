# find_galaxy_dll.ps1
#
# Stage 1 of the pipeline. Searches a folder (recursively) for Galaxy.dll /
# Galaxy64.dll (GOG Galaxy SDK loader DLLs), and for each one found, logs its
# file properties (version info + basic file metadata) to
# GalaxyDllProperties.txt in that same folder.
#
# Defines Invoke-FindGalaxyDll. Dot-source this file to load the function;
# it does nothing on its own when dot-sourced.

function Invoke-FindGalaxyDll {
    param([string]$SearchRoot)

    $logPath = Join-Path $SearchRoot "GalaxyDllProperties.txt"

    Write-Host "Searching for Galaxy.dll / Galaxy64.dll under: $SearchRoot"
    Write-Host ""

    $targets = Get-ChildItem -LiteralPath $SearchRoot -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ieq 'Galaxy.dll' -or $_.Name -ieq 'Galaxy64.dll' }

    if (-not $targets -or @($targets).Count -eq 0) {
        Write-Host "[!] No Galaxy.dll or Galaxy64.dll found."
        "No Galaxy.dll or Galaxy64.dll found under: $SearchRoot" |
            Out-File -LiteralPath $logPath -Encoding UTF8
        return
    }

    $logLines = [System.Collections.Generic.List[string]]::new()
    $logLines.Add("Galaxy.dll / Galaxy64.dll properties")
    $logLines.Add("Search root: $SearchRoot")
    $logLines.Add("Generated:   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $logLines.Add("=" * 60)

    foreach ($file in $targets) {
        Write-Host "[+] Found: $($file.FullName)"

        $vi = $file.VersionInfo

        $logLines.Add("")
        $logLines.Add("File            : $($file.Name)")
        $logLines.Add("Full path       : $($file.FullName)")
        $logLines.Add("Size (bytes)    : $($file.Length)")
        $logLines.Add("Last write time : $($file.LastWriteTime)")
        $logLines.Add("Created         : $($file.CreationTime)")
        $logLines.Add("-" * 40)
        $logLines.Add("FileVersion       : $($vi.FileVersion)")
        $logLines.Add("ProductVersion    : $($vi.ProductVersion)")
        $logLines.Add("ProductName       : $($vi.ProductName)")
        $logLines.Add("CompanyName       : $($vi.CompanyName)")
        $logLines.Add("FileDescription   : $($vi.FileDescription)")
        $logLines.Add("InternalName      : $($vi.InternalName)")
        $logLines.Add("OriginalFilename  : $($vi.OriginalFilename)")
        $logLines.Add("LegalCopyright    : $($vi.LegalCopyright)")
        $logLines.Add("Language          : $($vi.Language)")
        $logLines.Add("IsDebug           : $($vi.IsDebug)")
        $logLines.Add("IsPatched         : $($vi.IsPatched)")
        $logLines.Add("IsPreRelease      : $($vi.IsPreRelease)")
        $logLines.Add("IsPrivateBuild    : $($vi.IsPrivateBuild)")
        $logLines.Add("IsSpecialBuild    : $($vi.IsSpecialBuild)")
        $logLines.Add("=" * 60)
    }

    [System.IO.File]::WriteAllLines($logPath, $logLines, [System.Text.UTF8Encoding]::new($false))
    Write-Host ""
    Write-Host "[INFO] Properties logged to: $logPath"
}