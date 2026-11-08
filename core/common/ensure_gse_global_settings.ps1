# ensure_gse_global_settings.ps1
#
# Makes sure the GBE Fork global settings file
#   %AppData%\GSE Saves\settings\configs.main.ini
# exists and contains:
#   disable_lan_only=1
#   offline=0
# If the file is missing, the folder structure is created and the file is
# copied from the cached GBE Fork release's configs.main.EXAMPLE.ini.
#
# Usage: ensure_gse_global_settings.ps1 -CacheDir <GBE cache> -Tag <GBE tag> -Variant <vs22|vs26>

param(
    [string]$CacheDir = '',
    [string]$Tag = '',
    [string]$Variant = '',
    [string]$GameFolder = ''
)

$ErrorActionPreference = 'Stop'

# Delete any local configs.main.ini in the game folder (excluding _ColdClient),
# so it can't override the global settings. The folders it was deleted from
# are listed in _ae_deleted_cfg_dirs.txt so steam_coldclient\write_config.ps1
# can later copy achievements.json + img from _ColdClient\steam_settings there.
if ($GameFolder -and (Test-Path -LiteralPath $GameFolder)) {
    $deletedListFile = Join-Path $GameFolder '_ae_deleted_cfg_dirs.txt'
    if (Test-Path -LiteralPath $deletedListFile) { Remove-Item -LiteralPath $deletedListFile -Force -ErrorAction SilentlyContinue }
    $deletedDirs = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($GameFolder)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop | ForEach-Object {
                if ($_.PSIsContainer) {
                    if ($_.Name -ine '_ColdClient') { $stack.Push($_.FullName) }
                } elseif ($_.Name -ieq 'configs.main.ini') {
                    try {
                        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                        Write-Host ('[INFO] Deleted local configs.main.ini: {0}' -f $_.FullName)
                        if (-not $deletedDirs.Contains($_.DirectoryName)) { $deletedDirs.Add($_.DirectoryName) }
                    } catch {
                        Write-Host ('[WARN] Could not delete {0}: {1}' -f $_.FullName, $_.Exception.Message)
                    }
                }
            }
        } catch { }
    }
    if ($deletedDirs.Count -gt 0) {
        try {
            [System.IO.File]::WriteAllLines($deletedListFile, $deletedDirs.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
        } catch {
            Write-Host ('[WARN] Could not write {0}: {1}' -f $deletedListFile, $_.Exception.Message)
        }
    }
}

$settingsDir = Join-Path $env:APPDATA 'GSE Saves\settings'
$iniPath     = Join-Path $settingsDir 'configs.main.ini'
$required    = [ordered]@{ 'disable_lan_only' = '1'; 'offline' = '0' }
$section     = '[main::connectivity]'
$utf8NoBom   = New-Object System.Text.UTF8Encoding($false)

try {
    if (-not (Test-Path -LiteralPath $iniPath)) {
        if (-not (Test-Path -LiteralPath $settingsDir)) {
            New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
        }

        # Preferred source: the exact GBE build selected this run.
        $example = $null
        if ($CacheDir -and $Tag -and $Variant) {
            $candidate = Join-Path $CacheDir ("gbe_fork\{0}\{1}\release\steam_settings.EXAMPLE\configs.main.EXAMPLE.ini" -f $Tag, $Variant)
            if (Test-Path -LiteralPath $candidate) { $example = $candidate }
        }
        # Fallback: newest example anywhere in the GBE cache.
        if (-not $example -and $CacheDir -and (Test-Path -LiteralPath (Join-Path $CacheDir 'gbe_fork'))) {
            $found = Get-ChildItem -LiteralPath (Join-Path $CacheDir 'gbe_fork') -Filter 'configs.main.EXAMPLE.ini' -Recurse -File -ErrorAction SilentlyContinue |
                     Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($found) { $example = $found.FullName }
        }

        if ($example) {
            Copy-Item -LiteralPath $example -Destination $iniPath -Force
            Write-Host ('[INFO] Created global GSE settings from example: {0}' -f $iniPath)
        } else {
            [System.IO.File]::WriteAllLines($iniPath, [string[]]@($section), $utf8NoBom)
            Write-Host ('[WARN] configs.main.EXAMPLE.ini not found - created minimal global settings: {0}' -f $iniPath)
        }
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.AddRange([string[]][System.IO.File]::ReadAllLines($iniPath))
    $changed = $false

    foreach ($key in $required.Keys) {
        $want = '{0}={1}' -f $key, $required[$key]
        $pattern = '^\s*' + [regex]::Escape($key) + '\s*='
        $idx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match $pattern) { $idx = $i; break }
        }

        if ($idx -ge 0) {
            if ($lines[$idx].Trim() -ne $want) { $lines[$idx] = $want; $changed = $true }
            continue
        }

        # Key missing: insert right under [main::connectivity], creating the section if needed.
        $secIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -ieq $section) { $secIdx = $i; break }
        }
        if ($secIdx -lt 0) {
            if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim() -ne '') { $lines.Add('') }
            $lines.Add($section)
            $secIdx = $lines.Count - 1
        }
        $lines.Insert($secIdx + 1, $want)
        $changed = $true
    }

    if ($changed) {
        [System.IO.File]::WriteAllLines($iniPath, $lines.ToArray(), $utf8NoBom)
        Write-Host '[INFO] Global GSE settings updated: disable_lan_only=1, offline=0'
    } else {
        Write-Host '[INFO] Global GSE settings already correct (disable_lan_only=1, offline=0).'
    }
    exit 0
} catch {
    Write-Host ('[WARN] Could not update global GSE settings ({0}): {1}' -f $iniPath, $_.Exception.Message)
    exit 0
}
