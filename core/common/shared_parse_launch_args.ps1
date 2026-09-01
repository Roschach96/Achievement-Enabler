# shared_parse_launch_args.ps1
#
# Reads a SteamCMD app_info_print manifest and extracts the launch arguments
# for the primary Windows launch entry. Emulator-agnostic - every adapter
# uses this same parser instead of forking its own copy.
#
# OUTPUT (written into the game folder):
#   _ae_launch_args.cmd          - set "LAUNCH_ARGS=<args>"  (empty if none)
#   <AppID>_launch_args_debug.log - full step-by-step trace for troubleshooting

param(
    [Parameter(Mandatory=$true)]
    [string]$AppID
)

$gameRoot     = (Get-Location).Path
$manifestFile = Join-Path $gameRoot "${AppID}_manifest.txt"
$outFile      = Join-Path $gameRoot "_ae_launch_args.cmd"
$debugFile    = Join-Path $gameRoot "${AppID}_launch_args_debug.log"

$debugLines = [System.Collections.Generic.List[string]]::new()
function Log([string]$msg) {
    $debugLines.Add($msg)
    Write-Host $msg
}

function Save-Debug {
    [System.IO.File]::WriteAllLines($debugFile, $debugLines, [System.Text.Encoding]::UTF8)
}

function Write-Result([string]$result) {
    [System.IO.File]::WriteAllLines(
        $outFile,
        @("set `"LAUNCH_ARGS=$result`""),
        [System.Text.Encoding]::ASCII
    )
}

Log "[debug] AppID        : $AppID"
Log "[debug] Game root    : $gameRoot"
Log "[debug] Manifest     : $manifestFile"

if (-not (Test-Path $manifestFile)) {
    $alt = Join-Path $gameRoot "steamcmd\${AppID}_manifest.txt"
    Log "[debug] Primary manifest not found, trying: $alt"
    if (Test-Path $alt) { $manifestFile = $alt }
}

if (-not (Test-Path $manifestFile)) {
    Log "[launch-args] No manifest file found for AppID $AppID - skipping."
    Write-Result ""
    Save-Debug
    exit 0
}

Log "[debug] Reading manifest..."

$raw = [System.IO.File]::ReadAllBytes($manifestFile)
Log "[debug] File size    : $($raw.Length) bytes"
Log "[debug] BOM bytes    : $($raw[0].ToString('X2')) $($raw[1].ToString('X2')) $($raw[2].ToString('X2'))"

if ($raw.Length -ge 2 -and $raw[0] -eq 0xFF -and $raw[1] -eq 0xFE) {
    $text = [System.Text.Encoding]::Unicode.GetString($raw, 2, $raw.Length - 2)
    Log "[debug] Encoding     : UTF-16 LE"
} elseif ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF) {
    $text = [System.Text.Encoding]::UTF8.GetString($raw, 3, $raw.Length - 3)
    Log "[debug] Encoding     : UTF-8 BOM"
} else {
    $text = [System.Text.Encoding]::UTF8.GetString($raw)
    Log "[debug] Encoding     : UTF-8 (no BOM)"
}

Log "[debug] Text length  : $($text.Length) chars"
Log "[debug] Line endings : $(if ($text -match '\r\n') { 'CRLF' } else { 'LF' })"

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

$launchMatch = [regex]::Match($text, '(?m)^[ \t]*"launch"[ \t]*\r?$')
Log "[debug] 'launch' found: $($launchMatch.Success) $(if ($launchMatch.Success) { "at index $($launchMatch.Index)" })"

if (-not $launchMatch.Success) {
    Log "[launch-args] No 'launch' section found in manifest."
    Write-Result ""
    Save-Debug
    exit 0
}

$launchBlock = Get-Block $text ($launchMatch.Index + $launchMatch.Length)
Log "[debug] Launch block length: $(if ($launchBlock) { $launchBlock.Length } else { 'NULL' })"

if (-not $launchBlock) {
    Log "[launch-args] Could not parse launch block."
    Write-Result ""
    Save-Debug
    exit 0
}

$bestArgs   = $null
$entryRegex = [regex]'(?m)^[ \t]*"(\d+)"[ \t]*\r?$'
$entries    = $entryRegex.Matches($launchBlock)
Log "[debug] Launch entries found: $($entries.Count)"

foreach ($em in ($entries | Sort-Object { [int]$_.Groups[1].Value })) {
    $idx        = $em.Groups[1].Value
    $entryBlock = Get-Block $launchBlock ($em.Index + $em.Length)
    if (-not $entryBlock) { Log "[debug] Entry $idx : block parse failed"; continue }

    $configMatch = [regex]::Match($entryBlock, '(?m)^[ \t]*"config"[ \t]*\r?$')
    $oslist = $null
    if ($configMatch.Success) {
        $cfgBlock = Get-Block $entryBlock ($configMatch.Index + $configMatch.Length)
        if ($cfgBlock) { $oslist = Get-KVString $cfgBlock "oslist" }
    }
    if (-not $oslist) { $oslist = Get-KVString $entryBlock "oslist" }

    $type       = Get-KVString $entryBlock "type"
    $launchArgs = Get-KVString $entryBlock "arguments"

    Log "[debug] Entry $idx : oslist='$oslist'  type='$type'  arguments='$launchArgs'"

    if ($oslist -and $oslist -notmatch 'windows') {
        Log "[debug] Entry $idx : skipped (non-Windows oslist)"
        continue
    }
    if ($type -and $type -ne "default") {
        Log "[debug] Entry $idx : skipped (type is '$type')"
        continue
    }

    if ($launchArgs -and $launchArgs.Trim() -ne "") {
        $bestArgs = $launchArgs.Trim()
        Log "[debug] Entry $idx : SELECTED with args: $bestArgs"
        break
    }

    if ($null -eq $bestArgs) {
        $bestArgs = ""
        Log "[debug] Entry $idx : matched (no args needed)"
    }
}

if ($null -eq $bestArgs) { $bestArgs = "" }

if ($bestArgs -ne "") {
    Log "[launch-args] Found launch arguments: $bestArgs"
} else {
    Log "[launch-args] No launch arguments needed for this AppID."
}

Write-Result $bestArgs
Save-Debug
