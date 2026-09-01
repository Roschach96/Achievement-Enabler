param()

$iniPath      = $env:AE_INI_PATH
$achSavePath  = $env:AE_ACH_SAVE_PATH
$achKeyPrefix = $env:AE_ACH_KEY_PREFIX

$missing = @()
if (-not $iniPath) { $missing += "AE_INI_PATH" }
if (-not $achSavePath) { $missing += "AE_ACH_SAVE_PATH" }
if ($null -eq $achKeyPrefix) { $missing += "AE_ACH_KEY_PREFIX" }

if ($missing.Count -gt 0) {
    Write-Host "[ERROR] patch_ini.ps1: missing env var(s): $($missing -join ', ')"
    exit 1
}

if (-not (Test-Path -LiteralPath $iniPath)) {
    Write-Host "[ERROR] INI not found: $iniPath"
    exit 1
}

$bakPath = "$iniPath.BAK"
if (Test-Path -LiteralPath $bakPath) {
    try {
        $bak = Get-Content -Raw -LiteralPath $bakPath
        $dst = Get-Content -Raw -LiteralPath $iniPath

        $match = [regex]::Match($bak, '(?s)\[DLC\].*$')
        if ($match.Success) {
            $merged = [regex]::Replace($dst, '(?s)\[DLC\].*$', $match.Value.TrimEnd())
            Set-Content -LiteralPath $iniPath -Value $merged -NoNewline -Encoding UTF8
            Write-Host "[INFO] Merged [DLC]/[Items]/[Chunks] from $bakPath into $iniPath"
        } else {
            Write-Host "[WARN] No [DLC] section found in $bakPath - skipping merge."
        }
    } catch {
        Write-Host "[ERROR] Failed to merge DLC/Items/Chunks: $_"
        exit 1
    }
} else {
    Write-Host "[INFO] No BAK file found ($bakPath) - skipping DLC/Items/Chunks merge."
}

try {
    $content = Get-Content -LiteralPath $iniPath
    $content = $content `
        -replace '(?m)^Achievements\s*=\s*\d+', 'Achievements = 1' `
        -replace '(?m)^SaveType\s*=\s*\d+', 'SaveType = 2' `
        -replace '(?m)^AchSaveType\s*=\s*\d+', 'AchSaveType = 1' `
        -replace '(?m)^SavePath\s*=.*', "SavePath = $achSavePath" `
        -replace '(?m)^AchSavePath\s*=.*', "AchSavePath = $achSavePath" `
        -replace '(?m)^AchKeyPrefix\s*=.*', "AchKeyPrefix = $achKeyPrefix"

    Set-Content -LiteralPath $iniPath -Value $content
    Write-Host "[INFO] Patched INI: $iniPath"
} catch {
    Write-Host "[ERROR] Failed to patch INI: $_"
    exit 1
}
