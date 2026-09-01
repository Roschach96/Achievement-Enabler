# select_adapter.ps1
#
# Emulator-agnostic adapter picker. Scans every adapters\*\adapter.json and
# figures out which one applies to THIS game folder by searching for
# adapter-specific loader DLLs. Adding a new emulator later never requires
# touching this file - just drop a new adapters\<id>\adapter.json with its
# own detect.loader_dll_names.
#
# Detection rule per adapter (from adapter.json's "detect" object):
#   loader_dll_names: []          + is_default: true   -> fallback adapter,
#                                                          used when nothing
#                                                          else matches
#   loader_dll_names: [...]       + is_default: false   -> selected
#                                                          automatically when
#                                                          any of those file
#                                                          names is found
#                                                          anywhere in the
#                                                          game folder
#
# The DLL search always excludes the script's own folders (core\, adapters\) -
# adapter template assets (e.g. adapters\uplay_r2\GoldbergUplayR2-*) live
# inside adapters\, so excluding that root wholesale also keeps the template
# DLLs from causing a false-positive match on their own account.
#
# Reads:  -AdaptersRoot, -CoreRoot, -GameFolder
# Writes: _ae_adapter.cmd (set AE_ADAPTER_ID / AE_ADAPTER_NAME / AE_ADAPTER_DIR / AE_ASSETS_DIR)

param(
    [Parameter(Mandatory)]
    [string]$AdaptersRoot,

    [Parameter(Mandatory)]
    [string]$CoreRoot,

    [Parameter(Mandatory)]
    [string]$GameFolder
)

function Write-Selection([string]$id, [string]$name, [string]$dir, [string]$assetsDir) {
    $lines = @(
        "set `"AE_ADAPTER_ID=$id`"",
        "set `"AE_ADAPTER_NAME=$name`"",
        "set `"AE_ADAPTER_DIR=$dir`"",
        "set `"AE_ASSETS_DIR=$assetsDir`""
    )
    [System.IO.File]::WriteAllLines((Join-Path $GameFolder "_ae_adapter.cmd"), $lines, [System.Text.Encoding]::ASCII)
}

function Resolve-AssetsDir([string]$adapterDir, [string]$glob) {
    if (-not $glob) { return "" }
    $found = Get-ChildItem -LiteralPath $adapterDir -Directory -Filter $glob -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }
    return ""
}

# ── Load every adapter.json ────────────────────────────────────────────────
$adapterDirs = Get-ChildItem -LiteralPath $AdaptersRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name

$adapters = @()
foreach ($dir in $adapterDirs) {
    $metaPath = Join-Path $dir.FullName "adapter.json"
    if (-not (Test-Path -LiteralPath $metaPath)) { continue }
    try {
        $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
    } catch {
        Write-Host "[WARN] Skipping adapter with invalid adapter.json: $metaPath"
        continue
    }
    $loaderNames = @()
    if ($meta.detect -and $meta.detect.loader_dll_names) { $loaderNames = @($meta.detect.loader_dll_names) }
    $isDefault = $meta.detect -and $meta.detect.is_default -eq $true

    $adapters += [PSCustomObject]@{
        Id            = $meta.id
        Name          = $meta.name
        Priority      = if ($meta.priority) { [int]$meta.priority } else { 999 }
        LoaderNames   = $loaderNames
        IsDefault     = $isDefault
        AssetsGlob    = $meta.assets_folder_glob
        Dir           = $dir.FullName
    }
}

if ($adapters.Count -eq 0) {
    Write-Host "[ERROR] No adapters found under: $AdaptersRoot"
    exit 1
}

# ── Build the exclusion list: just the script's own folders. Adapter assets
# (e.g. GoldbergUplayR2-*) now live inside adapters\<id>\, which is already
# covered by excluding $AdaptersRoot wholesale - no per-adapter exclusion needed.
$excludeRoots = @(
    (Resolve-Path -LiteralPath $CoreRoot -ErrorAction SilentlyContinue).Path,
    (Resolve-Path -LiteralPath $AdaptersRoot -ErrorAction SilentlyContinue).Path
) | Where-Object { $_ }

function Test-Excluded([string]$fullPath) {
    foreach ($root in $excludeRoots) {
        if ($fullPath.Equals($root, [System.StringComparison]::OrdinalIgnoreCase) -or
            $fullPath.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

# ── Search the game folder for each adapter's loader DLL names ────────────
$matches = @()
foreach ($a in $adapters) {
    if ($a.LoaderNames.Count -eq 0) { continue }

    $hit = $null
    foreach ($dllName in $a.LoaderNames) {
        $found = Get-ChildItem -LiteralPath $GameFolder -Recurse -File -Filter $dllName -Force -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-Excluded $_.FullName) } |
            Select-Object -First 1
        if ($found) { $hit = $found; break }
    }
    if ($hit) {
        Write-Host "[INFO] Found $($hit.Name) at: $($hit.FullName)"
        $matches += [PSCustomObject]@{ Adapter = $a; AssetsDir = (Resolve-AssetsDir $a.Dir $a.AssetsGlob) }
    }
}

if ($matches.Count -eq 1) {
    $m = $matches[0]
    Write-Host "[INFO] Auto-detected adapter '$($m.Adapter.Name)' from a loader DLL found in the game folder."
    Write-Selection $m.Adapter.Id $m.Adapter.Name $m.Adapter.Dir $m.AssetsDir
    exit 0
}

if ($matches.Count -eq 0) {
    # @(...) forces an array even when Where-Object matches exactly one item -
    # otherwise PowerShell "unwraps" a single match to a bare object with no
    # .Count property, and the -eq 1 check below silently never fires.
    $defaults = @($adapters | Where-Object { $_.IsDefault })
    if ($defaults.Count -eq 1) {
        $d = $defaults[0]
        Write-Host "[INFO] No emulator-specific loader DLL found in the game folder - using default adapter '$($d.Name)'."
        Write-Selection $d.Id $d.Name $d.Dir (Resolve-AssetsDir $d.Dir $d.AssetsGlob)
        exit 0
    }
}

# ── Ambiguous (0 or >1 default candidates, or multiple DLL matches) - ask ──
Write-Host ""
Write-Host "Could not unambiguously auto-detect which emulator adapter applies. Select one:"
Write-Host ""
$ordered = @($adapters | Sort-Object Priority)
for ($i = 0; $i -lt $ordered.Count; $i++) {
    Write-Host "  $($i+1)) $($ordered[$i].Name)"
}
Write-Host ""
do { [string]$c = Read-Host "Select adapter (1-$($ordered.Count))" }
while ($c -notmatch '^\d+$' -or [int]$c -lt 1 -or [int]$c -gt $ordered.Count)
$chosen = $ordered[[int]$c - 1]

$chosenAssets = ""
$m = $matches | Where-Object { $_.Adapter.Id -eq $chosen.Id } | Select-Object -First 1
if ($m) { $chosenAssets = $m.AssetsDir } else { $chosenAssets = Resolve-AssetsDir $chosen.Dir $chosen.AssetsGlob }

Write-Selection $chosen.Id $chosen.Name $chosen.Dir $chosenAssets
exit 0
